// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {HousePool} from "./HousePool.sol";
import {AccountLensViewTypes} from "./interfaces/AccountLensViewTypes.sol";
import {EngineStatusViewTypes} from "./interfaces/EngineStatusViewTypes.sol";
import {ICfdEngineAccountLens} from "./interfaces/ICfdEngineAccountLens.sol";
import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {IPerpsLPViews} from "./interfaces/IPerpsLPViews.sol";
import {IPerpsTraderViews} from "./interfaces/IPerpsTraderViews.sol";
import {IProtocolViews} from "./interfaces/IProtocolViews.sol";
import {PerpsViewTypes} from "./interfaces/PerpsViewTypes.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PerpsPublicLens
/// @notice Compact read facade for the simplified product-facing perps surface.
/// @dev This intentionally presents a narrower, easier-to-consume view than the rich engine and
///      accounting lenses used by tests, audits, and operator tooling.
contract PerpsPublicLens is IPerpsTraderViews, IPerpsLPViews, IProtocolViews {

    ICfdEngineAccountLens public immutable ACCOUNT_LENS;
    ICfdEngineCore public immutable ENGINE;
    IOrderRouterAccounting public immutable ORDER_ROUTER;
    HousePool public immutable HOUSE_POOL;

    /// @param accountLens_ Rich account lens used to derive compact trader views.
    /// @param engine_ Core engine used for runtime status and risk params.
    /// @param orderRouter_ Router accounting surface used for pending-order summaries.
    /// @param housePool_ HousePool used for tranche and protocol status views.
    constructor(
        address accountLens_,
        address engine_,
        address orderRouter_,
        address housePool_
    ) {
        ACCOUNT_LENS = ICfdEngineAccountLens(accountLens_);
        ENGINE = ICfdEngineCore(engine_);
        ORDER_ROUTER = IOrderRouterAccounting(orderRouter_);
        HOUSE_POOL = HousePool(housePool_);
    }

    /// @notice Returns the compact trader account summary for a canonical perps account.
    function getTraderAccount(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.TraderAccountView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = ACCOUNT_LENS.getAccountLedgerSnapshot(accountId);
        viewData.equityUsdc = snapshot.hasPosition
            ? (snapshot.netEquityUsdc > 0 ? uint256(snapshot.netEquityUsdc) : 0)
            : snapshot.accountEquityUsdc;
        viewData.withdrawableUsdc = ACCOUNT_LENS.getWithdrawableUsdc(accountId);

        IOrderRouterAccounting.AccountEscrowView memory escrow = ORDER_ROUTER.getAccountEscrow(accountId);
        viewData.pendingOrderMarginUsdc = escrow.committedMarginUsdc;
        viewData.pendingExecutionBountyUsdc = escrow.executionBountyUsdc;

        PerpsViewTypes.PositionView memory position = _getPositionView(accountId);
        viewData.hasOpenPosition = position.exists;
        viewData.liquidatable = position.liquidatable;
    }

    /// @notice Returns the compact current-position view for an account.
    function getPosition(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.PositionView memory viewData) {
        return _getPositionView(accountId);
    }

    /// @notice Returns all currently pending orders for an account.
    /// @dev The public surface only returns pending orders because executed and failed orders are not
    ///      part of the compact product-facing queue summary.
    function getPendingOrders(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.PendingOrderView[] memory pending) {
        uint64 orderId = ORDER_ROUTER.accountHeadOrderId(accountId);
        uint256 pendingCount = ORDER_ROUTER.pendingOrderCounts(accountId);
        pending = new PerpsViewTypes.PendingOrderView[](pendingCount);

        for (uint256 i; i < pendingCount; ++i) {
            (IOrderRouterAccounting.PendingOrderView memory current, uint64 nextAccountOrderId) =
                ORDER_ROUTER.getPendingOrderView(orderId);
            pending[i] = PerpsViewTypes.PendingOrderView({
                orderId: current.orderId,
                side: current.side,
                sizeDelta: current.sizeDelta,
                marginDeltaUsdc: int256(current.marginDelta),
                acceptablePrice: current.targetPrice,
                isReduceOnly: current.isClose,
                status: PerpsViewTypes.OrderStatus.Pending
            });
            orderId = nextAccountOrderId;
        }
    }

    /// @notice Returns whether the account's current live position is liquidatable.
    function isLiquidatable(
        bytes32 accountId
    ) external view returns (bool) {
        return _getPositionView(accountId).liquidatable;
    }

    /// @notice Returns the compact senior tranche view.
    function getSeniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData) {
        return _getTrancheView(HOUSE_POOL.seniorVault(), true);
    }

    /// @notice Returns the compact junior tranche view.
    function getJuniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData) {
        return _getTrancheView(HOUSE_POOL.juniorVault(), false);
    }

    /// @notice Returns high-level LP status flags.
    function getLpStatus() external view returns (PerpsViewTypes.LpStatusView memory viewData) {
        viewData.tradingActive = HOUSE_POOL.isTradingActive();
        viewData.withdrawalLive = HOUSE_POOL.isWithdrawalLive();
        viewData.oracleFrozen = HOUSE_POOL.isOracleFrozen();

        PerpsViewTypes.ProtocolStatusView memory status = _getProtocolStatusView();
        viewData.lastMarkTime = status.lastMarkTime;
        viewData.oracleFresh = HOUSE_POOL.getVaultLiquidityView().markFresh;
    }

    /// @notice Returns high-level protocol runtime status flags.
    function getProtocolStatus() external view returns (PerpsViewTypes.ProtocolStatusView memory viewData) {
        return _getProtocolStatusView();
    }

    function _getPositionView(
        bytes32 accountId
    ) internal view returns (PerpsViewTypes.PositionView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = ACCOUNT_LENS.getAccountLedgerSnapshot(accountId);
        viewData.exists = snapshot.hasPosition;
        if (!viewData.exists) {
            return viewData;
        }

        viewData.side = snapshot.side;
        viewData.size = snapshot.size;
        viewData.entryPrice = snapshot.entryPrice;
        viewData.marginUsdc = snapshot.margin;
        viewData.unrealizedPnlUsdc = snapshot.unrealizedPnlUsdc;
        viewData.liquidatable = snapshot.liquidatable;
        (
            uint256 vpiFactor,
            uint256 maxSkewRatio,
            uint256 maintMarginBps,
            uint256 initMarginBps,
            uint256 fadMarginBps,,,
        ) = ENGINE.riskParams();
        vpiFactor;
        maxSkewRatio;
        initMarginBps;
        uint256 requiredBps = ENGINE.isFadWindow() ? fadMarginBps : maintMarginBps;
        uint256 notionalUsdc = (snapshot.size * ENGINE.lastMarkPrice()) / 1e20;
        viewData.maintenanceMarginUsdc = (notionalUsdc * requiredBps) / 10_000;
    }

    function _getTrancheView(
        address vault,
        bool isSenior
    ) internal view returns (PerpsViewTypes.TrancheView memory viewData) {
        if (vault == address(0)) {
            return viewData;
        }

        uint256 totalAssetsUsdc = IERC4626(vault).totalAssets();
        uint256 totalShares = IERC20(vault).totalSupply();
        viewData.totalAssetsUsdc = totalAssetsUsdc;
        viewData.totalShares = totalShares;
        viewData.sharePrice = totalShares == 0 ? 1e18 : (totalAssetsUsdc * 1e18) / totalShares;
        viewData.maxWithdrawUsdc = isSenior ? HOUSE_POOL.getMaxSeniorWithdraw() : HOUSE_POOL.getMaxJuniorWithdraw();
        viewData.frozenLpFeeBps = HOUSE_POOL.frozenLpFeeBps(isSenior);
        viewData.depositEnabled = HOUSE_POOL.canAcceptTrancheDeposits(isSenior);
        viewData.withdrawEnabled = HOUSE_POOL.isWithdrawalLive();
        viewData.oracleFrozen = HOUSE_POOL.isOracleFrozen();
    }

    function _getProtocolStatusView() internal view returns (PerpsViewTypes.ProtocolStatusView memory viewData) {
        EngineStatusViewTypes.ProtocolStatus memory status = ENGINE.getProtocolStatus();
        viewData.phase = status.phase;
        viewData.lastMarkPrice = status.lastMarkPrice;
        viewData.lastMarkTime = status.lastMarkTime;
        viewData.oracleFrozen = status.oracleFrozen;
        viewData.fadWindow = status.fadWindow;
        viewData.tradingActive = HOUSE_POOL.isTradingActive();
        viewData.withdrawalLive = HOUSE_POOL.isWithdrawalLive();
    }

}
