// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Two-tranche USDC pool that acts as counterparty to CFD traders.
///         Senior tranche earns a junior-funded target coupon; junior absorbs first-loss and excess profit.
interface IHousePool {

    enum ClaimantInflowKind {
        Revenue,
        Recapitalization
    }

    enum ClaimantInflowCashMode {
        CashArrived,
        AlreadyRetained
    }

    struct PoolLiquidityView {
        uint256 totalAssetsUsdc;
        uint256 freeUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 pendingRecapitalizationUsdc;
        uint256 pendingTradingRevenueUsdc;
        uint256 seniorPrincipalUsdc;
        uint256 juniorPrincipalUsdc;
        uint256 seniorHighWaterMarkUsdc;
        bool markFresh;
        bool oracleFrozen;
        bool degradedMode;
    }

    struct PoolConfig {
        uint256 seniorRateBps;
        uint256 markStalenessLimit;
        uint256 seniorFrozenLpFeeBps;
        uint256 juniorFrozenLpFeeBps;
    }

    error HousePool__NotAVault();
    error HousePool__RouterAlreadySet();
    error HousePool__SeniorVaultAlreadySet();
    error HousePool__JuniorVaultAlreadySet();
    error HousePool__Unauthorized();
    error HousePool__ExceedsMaxSeniorWithdraw();
    error HousePool__ExceedsMaxJuniorWithdraw();
    error HousePool__MarkPriceStale();
    error HousePool__TimelockNotReady();
    error HousePool__NoProposal();
    error HousePool__SeniorImpaired();
    error HousePool__DegradedMode();
    error HousePool__ZeroAddress();
    error HousePool__ZeroStaleness();
    error HousePool__InvalidSeniorRate();
    error HousePool__InvalidFrozenLpFee();
    error HousePool__NoExcessAssets();
    error HousePool__ExcessAmountTooHigh();
    error HousePool__PendingBootstrap();
    error HousePool__NoUnassignedAssets();
    error HousePool__BootstrapSharesZero();
    error HousePool__SeedAlreadyInitialized();
    error HousePool__TradingActivationNotReady();
    error HousePool__UnauthorizedPauser();
    error HousePool__OracleFrozen();
    error HousePool__DepositTooSmall();

    event Reconciled(uint256 seniorPrincipal, uint256 juniorPrincipal, int256 delta);
    event SeniorRateUpdated(uint256 newRateBps);
    event MarkStalenessLimitUpdated(uint256 newLimit);
    event PoolConfigProposed(
        uint256 seniorRateBps,
        uint256 markStalenessLimit,
        uint256 seniorFrozenLpFeeBps,
        uint256 juniorFrozenLpFeeBps,
        uint256 activationTime
    );
    event PoolConfigFinalized();
    event FrozenLpFeesUpdated(uint256 seniorFeeBps, uint256 juniorFeeBps);
    event ExcessAccounted(uint256 amountUsdc, uint256 accountedAssetsUsdc);
    event ExcessSwept(address indexed recipient, uint256 amountUsdc);
    event ProtocolInflowAccounted(address indexed caller, uint256 amountUsdc, uint256 accountedAssetsUsdc);
    event ClaimantInflowAccounted(
        address indexed caller, ClaimantInflowKind kind, ClaimantInflowCashMode cashMode, uint256 amountUsdc
    );
    event UnassignedAssetsAssigned(
        bool indexed toSenior, address indexed receiver, uint256 amountUsdc, uint256 sharesMinted
    );
    event SeedPositionInitialized(
        bool indexed toSenior, address indexed receiver, uint256 amountUsdc, uint256 sharesMinted
    );
    event TradingActivated();
    event PauserUpdated(address indexed previousPauser, address indexed newPauser);

    /// @notice Canonical economic USDC backing recognized by the pool (6 decimals).
    ///         Ignores unsolicited positive token transfers until explicitly accounted, but
    ///         still reflects raw-balance shortfalls if assets leave the pool unexpectedly.
    function totalAssets() external view returns (uint256);

    /// @notice Transfers USDC from the pool to a recipient.
    /// @param recipient Address to receive USDC
    /// @param amount USDC amount to transfer (6 decimals)
    function payOut(
        address recipient,
        uint256 amount
    ) external;

    /// @notice Increases canonical pool assets to recognize a legitimate protocol-owned inflow.
    /// @dev This is the controlled accounting path for endogenous protocol gains that should
    ///      increase economic pool depth. It does not require raw excess to be present and may
    ///      also be used to restore canonical accounting after a raw-balance shortfall has already
    ///      reduced `totalAssets()` via the `min(rawBalance, accountedAssets)` boundary.
    ///      Reverts if the caller is unauthorized.
    function recordProtocolInflow(
        uint256 amount
    ) external;

    /// @notice Records claimant-owned value that should ultimately flow through the tranche waterfall.
    /// @dev `CashArrived` increments canonical accounted assets because raw USDC arrived in this flow.
    ///      `AlreadyRetained` only routes ownership for value already retained physically by the pool.
    function recordClaimantInflow(
        uint256 amount,
        ClaimantInflowKind kind,
        ClaimantInflowCashMode cashMode
    ) external;

    /// @notice Maximum age for mark price freshness checks outside FAD mode (seconds)
    function markStalenessLimit() external view returns (uint256);

    /// @notice Returns true once both tranche seed positions exist.
    function isSeedLifecycleComplete() external view returns (bool);

    /// @notice Total USDC attributed to the senior tranche (6 decimals)
    function seniorPrincipal() external view returns (uint256);
    /// @notice Total USDC attributed to the junior tranche (6 decimals)
    function juniorPrincipal() external view returns (uint256);
    /// @notice Senior high-water mark used to block dilutive recapitalizing deposits.
    function seniorHighWaterMark() external view returns (uint256);
    /// @notice Accounted LP assets currently quarantined pending explicit bootstrap / assignment (6 decimals)
    function unassignedAssets() external view returns (uint256);

    function depositSenior(
        uint256 amount
    ) external;
    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external;
    function depositJunior(
        uint256 amount
    ) external;
    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external;

    /// @notice Explicitly bootstraps quarantined LP assets into a tranche and mints matching shares.
    function assignUnassignedAssets(
        bool toSenior,
        address receiver
    ) external;

    /// @notice Seeds a tranche with permanent share-backed minimum ownership using real USDC.
    /// @dev Canonical deployment should initialize both tranche seeds before enabling ordinary LP lifecycle.
    function initializeSeedPosition(
        bool toSenior,
        uint256 amount,
        address receiver
    ) external;

    /// @notice Max withdrawable by senior, capped by free USDC
    function getMaxSeniorWithdraw() external view returns (uint256);
    /// @notice Max withdrawable by junior, subordinated behind senior
    function getMaxJuniorWithdraw() external view returns (uint256);

    /// @notice Read-only tranche state as if `reconcile()` ran immediately with current inputs.
    /// @return seniorPrincipalUsdc Simulated senior principal after reconcile (6 decimals)
    /// @return juniorPrincipalUsdc Simulated junior principal after reconcile (6 decimals)
    /// @return maxSeniorWithdrawUsdc Simulated senior withdrawal cap after reconcile (6 decimals)
    /// @return maxJuniorWithdrawUsdc Simulated junior withdrawal cap after reconcile (6 decimals)
    function getPendingTrancheState()
        external
        view
        returns (
            uint256 seniorPrincipalUsdc,
            uint256 juniorPrincipalUsdc,
            uint256 maxSeniorWithdrawUsdc,
            uint256 maxJuniorWithdrawUsdc
        );

    /// @notice Read-only tranche principals for deposit pricing.
    /// @dev Immediate vault deposits are disabled while trader positions are open. Pending deposit epochs
    ///      may still use this view when finalized after their activation delay.
    /// @return seniorPrincipalUsdc Simulated senior principal after reconcile (6 decimals)
    /// @return juniorPrincipalUsdc Simulated junior principal after reconcile (6 decimals)
    function getPendingDepositTrancheState()
        external
        view
        returns (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc);

    /// @notice Whether pending deposit finalization would hit the senior impairment gate after reconcile.
    function isSeniorImpairedAfterPendingDepositReconcile() external view returns (bool);

    /// @notice Settles revenue/loss waterfall between tranches
    function reconcile() external;

    /// @notice Whether withdrawals are currently possible (not degraded, mark is fresh)
    function isWithdrawalLive() external view returns (bool);

    function hasSeedLifecycleStarted() external view returns (bool);

    function canAcceptOrdinaryDeposits() external view returns (bool);

    function canAcceptTrancheDeposits(
        bool isSenior
    ) external view returns (bool);

    function canAcceptInstantTrancheDeposits(
        bool isSenior
    ) external view returns (bool);

    function canIncreaseRisk() external view returns (bool);

    function isTradingActive() external view returns (bool);

    function isOracleFrozen() external view returns (bool);

    function frozenLpFeeBps(
        bool isSenior
    ) external view returns (uint256);

    /// @notice Minimum assets accepted by ordinary ERC4626 tranche deposit/mint flows (6 decimals).
    function minTrancheDepositUsdc() external view returns (uint256);

}
