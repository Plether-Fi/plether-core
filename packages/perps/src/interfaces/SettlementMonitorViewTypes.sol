// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Read-only operator and security-monitoring types for synchronized LP epoch settlement.
/// @dev Masks use `1 << uint256(enumValue)`. An observed epoch is diagnostic only: HousePool always processes its
///      bounded FIFO heads and does not accept an epoch selected by this lens.
library SettlementMonitorViewTypes {

    /// @notice Oracle/authorization path currently required to attempt LP settlement.
    enum ExecutionPath {
        /// @notice Required route could not be established because a dependency read failed.
        Unknown,
        /// @notice No matured queue head is currently visible. This does not imply that the observed epoch is empty.
        NoMaturedWork,
        /// @notice HousePool may consume its cached Engine mark without a Router-only live-market refresh.
        CachedMark,
        /// @notice The canonical attempt is `OrderRouter.settleLpEpoch(bytes[])` with a PoolReconcile update.
        AtomicOracleRefresh
    }

    /// @notice Tri-state result for bounded structural and custody checks.
    enum HealthState {
        Unknown,
        Healthy,
        Critical
    }

    /// @notice Indexes for `SettlementStatus.operationalBlockerMask`.
    enum OperationalBlocker {
        WithdrawalsNotLive,
        CachedMarkStale,
        EngineDegraded,
        RequiredOracleInvalid,
        OracleBeforeEpochBoundary,
        RequiredDependencyUnknown
    }

    /// @notice Indexes for `SettlementStatus.warningMask`.
    enum Warning {
        NoMaturedWork,
        AdditionsStillOpen,
        PoolPaused,
        RouterAdminPaused,
        OracleFrozen,
        TerminalDeficit,
        NoFreeCash,
        MaturedSeniorPrecedence,
        ObservationCanStillShrink
    }

    /// @notice Indexes for each tranche's deposit-deferral mask.
    enum DepositDeferral {
        LifecycleInactive,
        PoolPaused,
        OracleFrozen,
        EngineDegraded,
        TerminalDeficit,
        MarkStale,
        UnassignedAssets,
        SeniorImpaired,
        ZeroPrincipalWithSupply,
        SeniorCapacityUnavailable,
        ActivationNotConfirmed,
        DependencyUnknown
    }

    /// @notice Indexes for `SettlementHealth.criticalFaultMask`.
    enum CriticalFault {
        BindingMismatch,
        RequestWindowMismatch,
        RequestWindowFormula,
        QueueEndpoint,
        ObservedEpochState,
        NavCapMismatch,
        NavLotsMismatch,
        NavEntryBasisMismatch,
        NavActiveEmptyMismatch,
        NavMarkDomain,
        NavSnapshotMismatch,
        PoolCustodyDeficit,
        PoolAssetBoundaryMismatch,
        SeniorAssetEscrowDeficit,
        SeniorShareEscrowDeficit,
        JuniorAssetEscrowDeficit,
        JuniorShareEscrowDeficit,
        SeniorSeedFloor,
        JuniorSeedFloor,
        SeniorReservationExceedsEscrow,
        FutureCachedMark,
        ArithmeticDomain
    }

    /// @notice Indexes for dependency/read failures. A set bit means the relevant section is unknown, not healthy.
    enum Dependency {
        Router,
        Engine,
        Pool,
        Clearinghouse,
        TerminalNavBook,
        EngineProtocolLens,
        SeniorVault,
        JuniorVault,
        Oracle,
        Pyth,
        PoolAccountingPreview
    }

    /// @notice Shared epoch clock and explicit observed-epoch timing.
    struct EpochClock {
        uint256 observedAt;
        uint256 observedBlock;
        uint256 epochDuration;
        uint256 requestCutoffDuration;
        uint256 currentEpoch;
        uint256 settlementCutoffEpoch;
        uint256 observedEpoch;
        uint256 observedEpochStart;
        uint256 observedEpochRequestCutoff;
        uint256 secondsUntilAdditionsClose;
        uint256 secondsUntilMaturity;
        uint256 minimumAtomicPublishTime;
        bool additionsClosed;
        bool isCurrentRequestTarget;
        bool additionsOpenByClock;
        bool matured;
    }

    /// @notice One tranche's bounded queue and observed-epoch state.
    struct TrancheQueueStatus {
        address vault;
        uint256 nextRequestEpoch;
        uint256 nextRequestCutoffTime;
        uint256 depositQueueHead;
        uint256 depositQueueTail;
        uint256 redeemQueueHead;
        uint256 redeemQueueTail;
        uint256 maturedDepositHeadEpoch;
        uint256 maturedDepositHeadAssets;
        uint256 maturedRedeemHeadEpoch;
        uint256 maturedRedeemHeadShares;
        uint256 observedDepositAssets;
        uint256 observedDepositPendingAssets;
        uint256 observedDepositClaimableAssets;
        uint256 observedDepositClaimableShares;
        uint256 observedDepositRefundableAssets;
        uint256 observedRedeemShares;
        uint256 observedRedeemFundedShares;
        uint256 observedRedeemFundedAssets;
        uint256 observedRedeemFundableShares;
        uint256 observedRedeemClaimableShares;
        uint256 observedRedeemClaimableAssets;
        uint256 observedRedeemRefundableShares;
        uint256 totalSupply;
        uint256 pendingDepositEscrowAssets;
        uint256 withdrawalEscrowAssets;
        uint256 pendingRedeemEscrowShares;
        uint256 depositClaimEscrowShares;
        bool observedDepositQueued;
        bool observedDepositFinalized;
        bool observedDepositRejected;
        bool observedRedeemQueued;
        bool observedRedeemRefundEnabled;
        uint256 faultMask;
        uint256 dependencyFailureMask;
    }

    /// @notice Current operational state used to choose an attempt path, not predict exact settlement progress.
    struct SettlementStatus {
        EpochClock clock;
        TrancheQueueStatus senior;
        TrancheQueueStatus junior;
        ExecutionPath requiredExecutionPath;
        uint256 cachedMarkPrice;
        uint256 cachedMarkTime;
        uint256 cachedMarkAge;
        uint256 applicableMaxMarkAge;
        uint256 freeUsdc;
        uint256 cachedPreviewTerminalDeficitUsdc;
        uint256 operationalBlockerMask;
        uint256 warningMask;
        uint256 seniorDepositDeferralMask;
        uint256 juniorDepositDeferralMask;
        /// @notice Subset of dependency failures that prevents selecting the cached-vs-atomic execution route.
        uint256 executionPathDependencyMask;
        uint256 dependencyFailureMask;
        bool hasMaturedWork;
        bool hasOpenPositions;
        bool oracleFrozen;
        bool fadWindow;
        bool engineDegraded;
        bool markFresh;
        bool withdrawalsLive;
        bool poolPaused;
        bool routerAdminPaused;
    }

    /// @notice Cached-state and reconcile-preview accounting observed without mutating settlement state.
    struct SettlementAccounting {
        uint256 poolRawAssetsUsdc;
        uint256 poolAccountedAssetsUsdc;
        uint256 poolTotalAssetsUsdc;
        uint256 poolExcessAssetsUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeUsdc;
        uint256 storedSeniorPrincipalUsdc;
        uint256 storedJuniorPrincipalUsdc;
        uint256 storedSeniorHighWaterMarkUsdc;
        uint256 cachedPreviewSeniorPrincipalUsdc;
        uint256 cachedPreviewJuniorPrincipalUsdc;
        uint256 cachedPreviewMaxSeniorWithdrawUsdc;
        uint256 cachedPreviewMaxJuniorWithdrawUsdc;
        uint256 pendingRecapitalizationUsdc;
        uint256 pendingTradingRevenueUsdc;
        uint256 unassignedAssetsUsdc;
        uint256 reservedSeniorDepositAssetsUsdc;
        uint256 storedTerminalDeficitUsdc;
        uint256 cachedPreviewTerminalDeficitUsdc;
        uint256 lastReconcileTime;
        uint256 lastSeniorCouponCheckpointTime;
        uint32 terminalMarkPrice;
        uint64 terminalMarkTime;
        int256 terminalLpPriceDeltaUsdc;
        uint256 totalTraderClaimsUsdc;
        uint256 maxDirectionalLiabilityUsdc;
        uint64 terminalBookVersion;
        bool terminalHasOpenPositions;
        bool terminalDegradedMode;
        bool cachedPreviewAvailable;
        bool terminalSnapshotAvailable;
        uint256 dependencyFailureMask;
    }

    /// @notice Current-feed PoolReconcile observation. It does not validate a future Hermes payload or fee quote.
    struct OracleStatus {
        address oracle;
        address pyth;
        uint256 price;
        uint256 markPrice;
        uint256 confidence;
        uint64 publishTime;
        uint256 maxStaleness;
        uint256 maximumConfidenceRatioBps;
        bytes4 failureSelector;
        bytes32 failureHash;
        bool readSucceeded;
        bool policyValid;
        bool publishTimeMeetsEpochFloor;
        bool oracleFrozen;
        bool fadWindow;
        bool closeOnly;
        uint256 dependencyFailureMask;
    }

    /// @notice Bounded NAV, queue, wiring, and custody evidence.
    struct SettlementHealth {
        HealthState state;
        uint256 criticalFaultMask;
        uint256 dependencyFailureMask;
        uint256 bookCapPrice;
        uint256 engineCapPrice;
        uint256 bookActiveCurveCount;
        uint256 bookTotalLots;
        uint256 bookTotalEntryCostUsdcAtoms;
        uint256 bookTotalEffectiveCapUsdcAtoms;
        uint256 engineBullOpenInterest;
        uint256 engineBearOpenInterest;
        uint256 engineBullEntryNotional;
        uint256 engineBearEntryNotional;
        uint256 sizeQuantum;
        uint256 poolRawAssetsUsdc;
        uint256 poolAccountedAssetsUsdc;
        uint256 poolCustodyDeficitUsdc;
        uint256 poolCustodySurplusUsdc;
        uint256 seniorRequiredAssetEscrowUsdc;
        uint256 seniorActualAssetEscrowUsdc;
        uint256 seniorRequiredShareEscrow;
        uint256 seniorActualShareEscrow;
        uint256 juniorRequiredAssetEscrowUsdc;
        uint256 juniorActualAssetEscrowUsdc;
        uint256 juniorRequiredShareEscrow;
        uint256 juniorActualShareEscrow;
        uint256 seniorPrincipalUsdc;
        uint256 seniorHighWaterMarkUsdc;
        uint256 seniorImpairmentUsdc;
        uint256 seniorPrincipalAboveHighWaterMarkUsdc;
        uint256 protectedSeniorExposureUsdc;
    }

    /// @notice Full single-block observation plus explicitly unauthenticated content digests.
    struct SettlementObservation {
        uint256 schemaVersion;
        SettlementStatus status;
        SettlementAccounting accounting;
        OracleStatus oracle;
        SettlementHealth health;
        bytes32 observableConfigDigest;
        bytes32 observationDigest;
        bytes32 completeObservationDigest;
        bool observationComplete;
    }

}
