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

/// @notice Compact read facade that maps the current perps system onto the simplified product surface.
contract PerpsPublicLens is IPerpsTraderViews, IPerpsLPViews, IProtocolViews {

    ICfdEngineAccountLens public immutable ACCOUNT_LENS;
    ICfdEngineCore public immutable ENGINE;
    IOrderRouterAccounting public immutable ORDER_ROUTER;
    HousePool public immutable HOUSE_POOL;

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

    function getTraderAccount(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.TraderAccountView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = ACCOUNT_LENS.getAccountLedgerSnapshot(accountId);
        viewData.equityUsdc = snapshot.hasPosition
            ? (snapshot.netEquityUsdc > 0 ? uint256(snapshot.netEquityUsdc) : 0)
            : snapshot.accountEquityUsdc;
        viewData.withdrawableUsdc = ENGINE.getWithdrawableUsdc(accountId);

        IOrderRouterAccounting.AccountEscrowView memory escrow = ORDER_ROUTER.getAccountEscrow(accountId);
        viewData.pendingOrderMarginUsdc = escrow.committedMarginUsdc;
        viewData.pendingExecutionBountyUsdc = escrow.executionBountyUsdc;

        PerpsViewTypes.PositionView memory position = _getPositionView(accountId);
        viewData.hasOpenPosition = position.exists;
        viewData.liquidatable = position.liquidatable;
    }

    function getPosition(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.PositionView memory viewData) {
        return _getPositionView(accountId);
    }

    function getPendingOrders(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.PendingOrderView[] memory pending) {
        IOrderRouterAccounting.PendingOrderView[] memory current = ORDER_ROUTER.getPendingOrdersForAccount(accountId);
        pending = new PerpsViewTypes.PendingOrderView[](current.length);

        for (uint256 i; i < current.length; ++i) {
            pending[i] = PerpsViewTypes.PendingOrderView({
                orderId: current[i].orderId,
                side: current[i].side,
                sizeDelta: current[i].sizeDelta,
                marginDeltaUsdc: int256(current[i].marginDelta),
                acceptablePrice: current[i].targetPrice,
                isReduceOnly: current[i].isClose,
                status: PerpsViewTypes.OrderStatus.Pending,
                retryAfterTimestamp: current[i].retryAfterTimestamp
            });
        }
    }

    function isLiquidatable(
        bytes32 accountId
    ) external view returns (bool) {
        return _getPositionView(accountId).liquidatable;
    }

    function getSeniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData) {
        return _getTrancheView(HOUSE_POOL.seniorVault(), true);
    }

    function getJuniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData) {
        return _getTrancheView(HOUSE_POOL.juniorVault(), false);
    }

    function getLpStatus() external view returns (PerpsViewTypes.LpStatusView memory viewData) {
        viewData.tradingActive = HOUSE_POOL.isTradingActive();
        viewData.withdrawalLive = HOUSE_POOL.isWithdrawalLive();

        PerpsViewTypes.ProtocolStatusView memory status = _getProtocolStatusView();
        viewData.lastMarkTime = status.lastMarkTime;
        viewData.oracleFresh = HOUSE_POOL.getVaultLiquidityView().markFresh;
    }

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
        viewData.maintenanceMarginUsdc = ENGINE.getMaintenanceMarginUsdc(snapshot.size, ENGINE.lastMarkPrice());
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
        viewData.depositEnabled = HOUSE_POOL.canAcceptTrancheDeposits(isSenior);
        viewData.withdrawEnabled = HOUSE_POOL.isWithdrawalLive();
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
