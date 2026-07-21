// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {ICfdEngineAccountLens} from "@plether/perps/interfaces/ICfdEngineAccountLens.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IPerpsLPViews} from "@plether/perps/interfaces/IPerpsLPViews.sol";
import {IPerpsTraderViews} from "@plether/perps/interfaces/IPerpsTraderViews.sol";
import {IProtocolViews} from "@plether/perps/interfaces/IProtocolViews.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

/// @title PerpsPublicLens
/// @notice Compact read facade for the simplified product-facing perps surface.
/// @dev This intentionally presents a narrower, easier-to-consume view than the rich engine and
///      accounting lenses used by tests, audits, and operator tooling.
contract PerpsPublicLens is IPerpsTraderViews, IPerpsLPViews, IProtocolViews {

    /// @notice Rich account lens used to derive trader equity, position, and withdrawal views.
    ICfdEngineAccountLens public immutable ACCOUNT_LENS;
    /// @notice Core engine used for mark, risk, lifecycle, and position status.
    ICfdEngineCore public immutable ENGINE;
    /// @notice Delayed-order router accounting surface used for pending reservations and orders.
    IOrderRouterAccounting public immutable ORDER_ROUTER;
    /// @notice House pool used for tranche and LP lifecycle views.
    HousePool public immutable HOUSE_POOL;

    /// @notice Configures the backing read surfaces used by this facade.
    /// @dev Addresses are stored without validation. Trader/order reads do not dereference `HOUSE_POOL`, and
    ///      protocol-status reads explicitly guard a zero `housePool_`; tranche and LP-status functions require
    ///      a deployed HousePool.
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

    /// @notice Returns equity, withdrawal capacity, pending reservations, and position risk for an account.
    /// @dev For an open position, negative net equity is floored at zero; without a position, clearinghouse
    ///      account equity is returned. Monetary fields use 6-decimal USDC units.
    /// @param account Canonical perps account to inspect.
    /// @return viewData Trader account summary derived from the account lens and router.
    function getTraderAccount(
        address account
    ) external view returns (PerpsViewTypes.TraderAccountView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = ACCOUNT_LENS.getAccountLedgerSnapshot(account);
        viewData.equityUsdc = snapshot.hasPosition
            ? (snapshot.netEquityUsdc > 0 ? uint256(snapshot.netEquityUsdc) : 0)
            : snapshot.accountEquityUsdc;
        viewData.withdrawableUsdc = ACCOUNT_LENS.getWithdrawableUsdc(account);

        IOrderRouterAccounting.AccountReservationView memory reservation = ORDER_ROUTER.getAccountReservations(account);
        viewData.pendingOrderMarginUsdc = reservation.committedMarginUsdc;
        viewData.pendingExecutionBountyUsdc = reservation.executionBountyUsdc;

        PerpsViewTypes.PositionView memory position = _getPositionView(account);
        viewData.hasOpenPosition = position.exists;
        viewData.liquidatable = position.liquidatable;
    }

    /// @notice Returns the live position and its current maintenance requirement for an account.
    /// @dev Returns a zeroed view when no position exists. Position size uses 18 decimals, prices use
    ///      8 decimals, and margin, PnL, and maintenance requirement use 6-decimal USDC.
    /// @param account Canonical perps account to inspect.
    /// @return viewData Position summary at the engine's current stored mark and calendar state.
    function getPosition(
        address account
    ) external view returns (PerpsViewTypes.PositionView memory viewData) {
        return _getPositionView(account);
    }

    /// @notice Returns all currently pending orders for an account.
    /// @dev The public surface only returns pending orders because executed and failed orders are not
    ///      part of the compact product-facing queue summary. Size uses 18 decimals; margin uses signed
    ///      6-decimal USDC and acceptable price uses 8 decimals. The traversal relies on the router's
    ///      pending count and account-linked FIFO queue being consistent.
    /// @param account Canonical perps account to inspect.
    /// @return pending Pending orders in account FIFO order.
    function getPendingOrders(
        address account
    ) external view returns (PerpsViewTypes.PendingOrderView[] memory pending) {
        uint64 orderId = ORDER_ROUTER.accountHeadOrderId(account);
        uint256 pendingCount = ORDER_ROUTER.pendingOrderCounts(account);
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

    /// @notice Returns whether the account's current live position is liquidatable at the stored mark.
    /// @param account Canonical perps account to inspect.
    /// @return True only when the account lens reports an existing liquidatable position.
    function isLiquidatable(
        address account
    ) external view returns (bool) {
        return _getPositionView(account).liquidatable;
    }

    /// @notice Returns the compact senior tranche view.
    /// @dev Asset and withdrawal amounts use 6-decimal USDC. For nonzero supply, `sharePrice` is the raw
    ///      `(totalAssets * 1e18) / totalSupply` quotient and does not normalize differing asset/share decimals.
    /// @return viewData Senior tranche balances, shares, fee, and current deposit/withdrawal availability.
    function getSeniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData) {
        return _getTrancheView(HOUSE_POOL.seniorVault(), true);
    }

    /// @notice Returns the compact junior tranche view.
    /// @dev Asset and withdrawal amounts use 6-decimal USDC. For nonzero supply, `sharePrice` is the raw
    ///      `(totalAssets * 1e18) / totalSupply` quotient and does not normalize differing asset/share decimals.
    /// @return viewData Junior tranche balances, shares, fee, and current deposit/withdrawal availability.
    function getJuniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData) {
        return _getTrancheView(HOUSE_POOL.juniorVault(), false);
    }

    /// @notice Returns high-level LP status flags.
    /// @dev `lastMarkTime` is a Unix timestamp. Oracle freshness is the pool liquidity view's `markFresh` flag.
    /// @return viewData Trading, withdrawal, mark freshness, and oracle-frozen status.
    function getLpStatus() external view returns (PerpsViewTypes.LpStatusView memory viewData) {
        viewData.tradingActive = HOUSE_POOL.isTradingActive();
        viewData.withdrawalLive = HOUSE_POOL.isWithdrawalLive();
        viewData.oracleFrozen = HOUSE_POOL.isOracleFrozen();

        PerpsViewTypes.ProtocolStatusView memory status = _getProtocolStatusView();
        viewData.lastMarkTime = status.lastMarkTime;
        viewData.oracleFresh = HOUSE_POOL.getPoolLiquidityView().markFresh;
    }

    /// @notice Returns high-level protocol runtime status flags.
    /// @dev Prices use 8 decimals and `lastMarkTime` is a Unix timestamp. When `HOUSE_POOL` is zero,
    ///      `tradingActive` and `withdrawalLive` remain false.
    /// @return viewData Protocol phase, stored mark, oracle, FAD, trading, and withdrawal status.
    function getProtocolStatus() external view returns (PerpsViewTypes.ProtocolStatusView memory viewData) {
        return _getProtocolStatusView();
    }

    /// @notice Builds the position view and applies the FAD maintenance ratio when the FAD window is active.
    /// @dev Maintenance notional is marked at `ENGINE.lastMarkPrice()` and integer division rounds down.
    /// @param account Canonical perps account to inspect.
    /// @return viewData Zeroed for no position; otherwise the current compact position view.
    function _getPositionView(
        address account
    ) internal view returns (PerpsViewTypes.PositionView memory viewData) {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = ACCOUNT_LENS.getAccountLedgerSnapshot(account);
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

    /// @notice Builds a tranche view from its ERC-4626 vault and pool-level withdrawal constraints.
    /// @dev Returns a zeroed view for a zero vault address. An empty vault reports a nominal `1e18`; otherwise the
    ///      raw `(totalAssets * 1e18) / totalSupply` quotient is returned without decimal normalization.
    /// @param vault ERC-4626 tranche vault to inspect.
    /// @param isSenior True for the senior tranche and false for the junior tranche.
    /// @return viewData Compact tranche view.
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

    /// @notice Builds the compact protocol lifecycle and oracle-status view.
    /// @return viewData Protocol status, with pool flags left false when no pool was configured.
    function _getProtocolStatusView() internal view returns (PerpsViewTypes.ProtocolStatusView memory viewData) {
        viewData.phase = _getProtocolPhase();
        viewData.lastMarkPrice = ENGINE.lastMarkPrice();
        viewData.lastMarkTime = ENGINE.lastMarkTime();
        viewData.oracleFrozen = ENGINE.isOracleFrozen();
        viewData.fadWindow = ENGINE.isFadWindow();
        if (address(HOUSE_POOL) != address(0)) {
            viewData.tradingActive = HOUSE_POOL.isTradingActive();
            viewData.withdrawalLive = HOUSE_POOL.isWithdrawalLive();
        }
    }

    /// @notice Derives the public protocol phase from engine wiring, degraded mode, and pool risk availability.
    /// @dev An unwired engine or a pool that cannot increase risk is reported as `Configuring`; degraded mode
    ///      takes precedence once the engine has both a pool and router.
    /// @return Numeric value of `ICfdEngine.ProtocolPhase`.
    function _getProtocolPhase() internal view returns (uint8) {
        address enginePool = ENGINE.pool();
        if (enginePool == address(0) || ENGINE.orderRouter() == address(0)) {
            return uint8(ICfdEngine.ProtocolPhase.Configuring);
        }
        if (ENGINE.degradedMode()) {
            return uint8(ICfdEngine.ProtocolPhase.Degraded);
        }
        if (!HousePool(enginePool).canIncreaseRisk()) {
            return uint8(ICfdEngine.ProtocolPhase.Configuring);
        }
        return uint8(ICfdEngine.ProtocolPhase.Active);
    }

}
