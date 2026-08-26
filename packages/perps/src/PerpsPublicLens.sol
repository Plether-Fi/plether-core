// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {ICfdEngineAccountLens} from "@plether/perps/interfaces/ICfdEngineAccountLens.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IPerpsLPViews} from "@plether/perps/interfaces/IPerpsLPViews.sol";
import {IPerpsTraderViews} from "@plether/perps/interfaces/IPerpsTraderViews.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {IProtocolViews} from "@plether/perps/interfaces/IProtocolViews.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

/// @dev Lightweight asynchronous-vault read surface used only by this lens.
interface IAsyncTrancheVaultLensView {

    function accruedTotalSupply() external view returns (uint256 effectiveTotalShares);

    function pendingMaintenanceFeeShares() external view returns (uint256 feeShares);

    function maintenanceFeeAprBps() external view returns (uint256 feeAprBps);

    function maintenanceFeeRecipient() external view returns (address recipient);

    function getRequestEpochWindow() external view returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime);

    function getMaturedDepositHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 assets);

    function getMaturedRedeemHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 remainingShares);

    function pendingDepositRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 assets);

    function claimableDepositRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 assets);

    function estimateDepositShares(
        uint256 assets
    ) external view returns (uint256 shares);

    function claimableDepositShares(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares);

    function refundableDepositRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 assets);

    function pendingRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares);

    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares);

    function estimateRedeemAssets(
        uint256 shares
    ) external view returns (uint256 assets);

    function claimableRedeemAssets(
        uint256 requestId,
        address controller
    ) external view returns (uint256 assets);

    function refundableRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares);

    function redeemRefundPending(
        uint256 requestId,
        address controller
    ) external view returns (bool pending);

}

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
    IOrderRouter public immutable ORDER_ROUTER;
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
        ORDER_ROUTER = IOrderRouter(orderRouter_);
        HOUSE_POOL = HousePool(housePool_);
    }

    /// @notice Returns equity, withdrawal capacity, pending reservations, and position risk for an account.
    /// @dev For an open position, exact price-risk equity is PnL pledge plus same-account claim plus exact price PnL.
    ///      Carry is projected from eligible free settlement first; an uncovered remainder independently marks the
    ///      account liquidatable rather than debiting price equity. Negative VPI is independently required to have full
    ///      dedicated-reserve backing; an underfunded floor also marks the account liquidatable, while excess reserve
    ///      never adds price collateral. Negative net equity is floored at zero. Without a position, clearinghouse
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

    /// @notice Returns the account's pending-open, armed, or triggered position protection.
    /// @dev Returns a zero-valued `None` record when the account has no active protection. Terminal records are
    ///      available by id through `getPositionProtection`.
    /// @param account Canonical perps account to inspect.
    /// @return protection Active protection record, or a zero-valued record when none exists.
    function getActivePositionProtection(
        address account
    ) external view returns (PositionProtectionTypes.PositionProtectionView memory protection) {
        IPositionProtectionViews protectionViews = _positionProtectionViews();
        uint64 protectionId = protectionViews.activePositionProtectionId(account);
        if (protectionId == 0) {
            return protection;
        }
        return protectionViews.getPositionProtection(protectionId);
    }

    /// @notice Returns a retained position-protection record by id, including terminal history.
    /// @param protectionId Protection identifier to inspect.
    /// @return protection Retained protection record; an unknown id returns a zero-valued `None` record.
    function getPositionProtection(
        uint64 protectionId
    ) external view returns (PositionProtectionTypes.PositionProtectionView memory protection) {
        return _positionProtectionViews().getPositionProtection(protectionId);
    }

    function _positionProtectionViews() private view returns (IPositionProtectionViews protectionViews) {
        return IPositionProtectionViews(ORDER_ROUTER.positionProtectionBook());
    }

    /// @notice Returns whether exact price risk breaches maintenance or projected carry remains uncovered at the stored mark.
    /// @param account Canonical perps account to inspect.
    /// @return True only when the account lens reports an existing liquidatable position.
    function isLiquidatable(
        address account
    ) external view returns (bool) {
        return _getPositionView(account).liquidatable;
    }

    /// @notice Returns the compact senior tranche view.
    /// @dev Asset amounts use 6-decimal USDC. `maxWithdrawUsdc` is the pool's current capacity for a synchronized
    ///      Senior redemption-funding phase, not an amount that a holder can withdraw synchronously.
    ///      For nonzero supply, `sharePrice` is the raw `(totalAssets * 1e18) / effectiveTotalSupply` quotient and does
    ///      not normalize differing asset/share decimals. Senior effective supply equals raw supply and its
    ///      maintenance-fee fields are zero.
    /// @return viewData Senior tranche balances, raw/effective shares, fees, and availability.
    function getSeniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData) {
        return _getTrancheView(HOUSE_POOL.seniorVault(), true);
    }

    /// @notice Returns the compact junior tranche view.
    /// @dev Asset amounts use 6-decimal USDC. `maxWithdrawUsdc` is the pool's current synchronized Junior-funding
    ///      capacity after the matured-Senior-priority gate, not an amount that a holder can withdraw synchronously.
    ///      For nonzero supply, `sharePrice` is the raw `(totalAssets * 1e18) / effectiveTotalSupply` quotient and does
    ///      not normalize differing asset/share decimals. Effective supply includes uncheckpointed maintenance-fee
    ///      shares.
    /// @return viewData Junior tranche balances, raw/effective shares, fees, and availability.
    function getJuniorTranche() external view returns (PerpsViewTypes.TrancheView memory viewData) {
        return _getTrancheView(HOUSE_POOL.juniorVault(), false);
    }

    /// @notice Returns high-level LP status flags.
    /// @dev `lastMarkTime` is a Unix timestamp. Oracle freshness is the pool liquidity view's `markFresh` flag.
    ///      The retained `withdrawalLive` field means new queued-redemption funding is live; escrowed claims do not
    ///      depend on it. `lpEpochSettlementPaused` explicitly identifies a governance settlement hold.
    /// @return viewData Trading, redemption-funding, settlement-hold, mark freshness, and oracle-frozen status.
    function getLpStatus() external view returns (PerpsViewTypes.LpStatusView memory viewData) {
        viewData.tradingActive = HOUSE_POOL.isTradingActive();
        viewData.withdrawalLive = HOUSE_POOL.isWithdrawalLive();
        viewData.oracleFrozen = HOUSE_POOL.isOracleFrozen();
        viewData.lpEpochSettlementPaused = HOUSE_POOL.lpEpochSettlementPaused();

        PerpsViewTypes.ProtocolStatusView memory status = _getProtocolStatusView();
        viewData.lastMarkTime = status.lastMarkTime;
        viewData.oracleFresh = HOUSE_POOL.getPoolLiquidityView().markFresh;
    }

    /// @notice Returns the request window and matured deposit and redemption heads for the next settlement.
    /// @dev `cutoffEpoch` currently equals `currentEpoch` and remains the latest epoch eligible for settlement now.
    ///      The selected vault supplies the coherent future `nextRequestEpoch` and `nextRequestCutoffTime` pair.
    ///      `settlementLive` concerns new redemption funding. Pool pause does not disable that funding, but it defers
    ///      deposit activation. A settlement hold defers both deposit activation and new redemption funding without
    ///      disabling request admission; already-funded claims depend on neither flag.
    /// @param isSenior True for the Senior queue and false for the Junior queue.
    /// @return viewData Request window, queue heads, backlog flags, shared epoch, and pool runtime gates.
    function getTrancheQueues(
        bool isSenior
    ) external view returns (PerpsViewTypes.TrancheQueueView memory viewData) {
        if (address(HOUSE_POOL) == address(0)) {
            return viewData;
        }

        viewData.vault = isSenior ? HOUSE_POOL.seniorVault() : HOUSE_POOL.juniorVault();
        viewData.currentEpoch = HOUSE_POOL.currentLpEpoch();
        viewData.cutoffEpoch = viewData.currentEpoch;
        viewData.settlementLive = HOUSE_POOL.isWithdrawalLive();
        viewData.poolPaused = HOUSE_POOL.paused();
        viewData.lpEpochSettlementPaused = HOUSE_POOL.lpEpochSettlementPaused();
        if (viewData.vault == address(0)) {
            return viewData;
        }

        IAsyncTrancheVaultLensView vault = IAsyncTrancheVaultLensView(viewData.vault);
        (viewData.nextRequestEpoch, viewData.nextRequestCutoffTime) = vault.getRequestEpochWindow();
        (viewData.depositHeadEpoch, viewData.depositHeadAssets) = vault.getMaturedDepositHead(viewData.cutoffEpoch);
        (viewData.redeemHeadEpoch, viewData.redeemHeadShares) = vault.getMaturedRedeemHead(viewData.cutoffEpoch);
        viewData.depositBacklog = viewData.depositHeadAssets != 0;
        viewData.redeemBacklog = viewData.redeemHeadShares != 0;
    }

    /// @notice Returns one controller's pending and claimable deposit/redemption state for a shared request epoch.
    /// @dev Pending share/asset fields are current estimates because their settlement rate is not fixed. Claimable and
    ///      refundable fields are exact request accounting. A rejected deposit leaves Pending and becomes refundable
    ///      until the controller or its operator cancels it and pulls the escrowed assets.
    /// @param isSenior True for the Senior vault and false for the Junior vault.
    /// @param requestId Shared LP epoch used as the asynchronous request id.
    /// @param controller Account that controls the request and may authorize operators.
    /// @return viewData Pending estimates and exact claimable balances for both async directions.
    function getLpRequestState(
        bool isSenior,
        uint256 requestId,
        address controller
    ) external view returns (PerpsViewTypes.LpRequestStateView memory viewData) {
        viewData.requestId = requestId;
        viewData.controller = controller;
        if (address(HOUSE_POOL) == address(0)) {
            return viewData;
        }

        viewData.vault = isSenior ? HOUSE_POOL.seniorVault() : HOUSE_POOL.juniorVault();
        if (viewData.vault == address(0)) {
            return viewData;
        }

        IAsyncTrancheVaultLensView vault = IAsyncTrancheVaultLensView(viewData.vault);
        viewData.pendingDepositAssets = vault.pendingDepositRequest(requestId, controller);
        if (viewData.pendingDepositAssets != 0) {
            viewData.pendingDepositSharesEstimate = vault.estimateDepositShares(viewData.pendingDepositAssets);
        }
        viewData.claimableDepositAssets = vault.claimableDepositRequest(requestId, controller);
        viewData.claimableDepositShares = vault.claimableDepositShares(requestId, controller);
        viewData.refundableDepositAssets = vault.refundableDepositRequest(requestId, controller);

        viewData.pendingRedeemShares = vault.pendingRedeemRequest(requestId, controller);
        if (viewData.pendingRedeemShares != 0) {
            viewData.pendingRedeemAssetsEstimate = vault.estimateRedeemAssets(viewData.pendingRedeemShares);
        }
        viewData.claimableRedeemShares = vault.claimableRedeemRequest(requestId, controller);
        viewData.claimableRedeemAssets = vault.claimableRedeemAssets(requestId, controller);
        viewData.refundableRedeemShares = vault.refundableRedeemRequest(requestId, controller);
        viewData.redeemRefundPending = vault.redeemRefundPending(requestId, controller);
    }

    /// @notice Returns high-level protocol runtime status flags.
    /// @dev Prices use 8 decimals and `lastMarkTime` is a Unix timestamp. When `HOUSE_POOL` is zero,
    ///      `tradingActive`, `withdrawalLive`, and `lpEpochSettlementPaused` remain false. `withdrawalLive` describes
    ///      new LP claim funding, not claims already held in vault escrow.
    /// @return viewData Protocol phase, stored mark, oracle, FAD, trading, redemption-funding, and settlement-hold status.
    function getProtocolStatus() external view returns (PerpsViewTypes.ProtocolStatusView memory viewData) {
        return _getProtocolStatusView();
    }

    /// @notice Builds the position view and applies the FAD maintenance ratio when the FAD window is active.
    /// @dev Maintenance notional is marked at `ENGINE.lastMarkPrice()` and integer division rounds down. Carry is first
    ///      projected against eligible free settlement; any uncovered remainder independently sets `liquidatable`.
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
            uint256 fadMarginBps,,,,,
        ) = ENGINE.riskParams();
        vpiFactor;
        maxSkewRatio;
        initMarginBps;
        uint256 requiredBps = ENGINE.isFadWindow() ? fadMarginBps : maintMarginBps;
        uint256 notionalUsdc = (snapshot.size * ENGINE.lastMarkPrice()) / 1e20;
        viewData.maintenanceMarginUsdc = (notionalUsdc * requiredBps) / 10_000;
    }

    /// @notice Builds a tranche view from its ERC-4626 vault and pool-level asynchronous-entry/exit constraints.
    /// @dev Returns a zeroed view for a zero vault address. An empty vault reports a nominal `1e18`; otherwise the
    ///      raw `(totalAssets * 1e18) / accruedTotalSupply` quotient is returned without decimal normalization.
    /// @param vault ERC-4626 tranche vault to inspect.
    /// @param isSenior True for the senior tranche and false for the junior tranche.
    /// @return viewData Compact tranche view. The legacy `maxWithdrawUsdc` field remains available as the current
    ///         queue-funding capacity; `withdrawEnabled` reports whether new funding can settle and does not gate
    ///         claims already backed by vault escrow.
    function _getTrancheView(
        address vault,
        bool isSenior
    ) internal view returns (PerpsViewTypes.TrancheView memory viewData) {
        if (vault == address(0)) {
            return viewData;
        }

        IAsyncTrancheVaultLensView vaultView = IAsyncTrancheVaultLensView(vault);
        uint256 totalAssetsUsdc = IERC4626(vault).totalAssets();
        uint256 totalShares = IERC20(vault).totalSupply();
        uint256 effectiveTotalShares = vaultView.accruedTotalSupply();
        viewData.totalAssetsUsdc = totalAssetsUsdc;
        viewData.totalShares = totalShares;
        viewData.effectiveTotalShares = effectiveTotalShares;
        viewData.pendingMaintenanceFeeShares = vaultView.pendingMaintenanceFeeShares();
        viewData.maintenanceFeeAprBps = vaultView.maintenanceFeeAprBps();
        viewData.maintenanceFeeRecipient = vaultView.maintenanceFeeRecipient();
        viewData.sharePrice = effectiveTotalShares == 0 ? 1e18 : (totalAssetsUsdc * 1e18) / effectiveTotalShares;
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
            viewData.lpEpochSettlementPaused = HOUSE_POOL.lpEpochSettlementPaused();
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
