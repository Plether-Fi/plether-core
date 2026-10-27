// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Pure planning surface that converts engine snapshots into settlement deltas.
/// @dev The planner performs no storage reads, authorization, oracle verification, or input authentication. Callers
///      must supply a canonical, internally consistent snapshot and order. settlement token amounts use 6 decimals, prices use
///      8 decimals, position sizes use 18 decimals, and timestamps are Unix seconds.
interface ICfdEnginePlanner {

    /// @notice Validates close commitment and projects margin-first carry with a zero execution bounty.
    /// @param snapshot Canonical account and cached-mark snapshot
    /// @param size Intended close size in canonical size quanta
    /// @return effects Carry and post-commitment custody projection; bounty fields are zero
    function planCloseCommit(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        uint256 size
    ) external pure returns (CfdEnginePlanTypes.CloseCommitment memory effects);

    /// @notice Classifies the recurring and governance-override market-calendar regimes.
    /// @dev The recurring schedule follows the 17:00 New York FX boundary and its US daylight-saving transitions.
    /// @param timestamp Unix timestamp to classify
    /// @param todayOverride Whether the current UTC day is an all-day FAD and frozen-oracle override
    /// @param tomorrowOverride Whether the following UTC day is an all-day override
    /// @param fadRunwaySeconds FAD look-ahead interval before an overridden following day
    /// @return fadWindow Whether FAD controls are active
    /// @return oracleFrozen Whether frozen-oracle policy is active
    function marketCalendarStatus(
        uint256 timestamp,
        bool todayOverride,
        bool tomorrowOverride,
        uint256 fadRunwaySeconds
    ) external pure returns (bool fadWindow, bool oracleFrozen);

    /// @notice Projects a side carry index from utilization and elapsed time.
    /// @dev `poolAssets` is economic depth after subtracting outstanding trader claims, floored at zero.
    function computeCurrentCarryIndex(
        uint256 storedIndex,
        uint64 previousTimestamp,
        uint256 currentTimestamp,
        uint256 borrowBaseAssets,
        uint256 poolAssets,
        uint256 baseCarryBps
    ) external pure returns (uint256 index);

    /// @notice Converts a carry-index delta into 6-decimal settlement token carry.
    function computeIndexedCarryAssets(
        uint256 borrowBaseAssets,
        uint256 carryIndexDelta
    ) external pure returns (uint256 carryAssets);

    /// @notice Returns the exact lot-based price-risk test used by withdrawal and protection health checks.
    function isExactPriceRiskLiquidatable(
        CfdTypes.Position memory pos,
        uint256 entryCostAssetAtoms,
        uint256 price,
        uint256 capPrice,
        uint256 priceCollateralAssets,
        uint256 requiredBps
    ) external pure returns (bool liquidatable);

    /// @notice Plans an open or increase order from a raw engine snapshot.
    /// @dev Caps the execution price at `snap.capPrice`. Expected business failures are encoded in the returned delta;
    ///      arithmetic violations or inconsistent inputs can still revert.
    /// @param snap Trusted account, side, pool, collateral, claim, carry, and risk snapshot
    /// @param order Open/increase order; the planner does not authenticate router-level flags or timing
    /// @param executionPrice Candidate execution price used for notional and PnL math (8 decimals)
    /// @return delta Complete open settlement plan or a partially populated typed failure result
    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta);

    /// @notice Plans a close or decrease order from a raw engine snapshot.
    /// @dev Caps the execution price at `snap.capPrice`. A side mismatch with a live position returns `SIDE_MISMATCH`
    ///      before carry; zero and non-quantized close sizes return `INVALID_SIZE_QUANTUM`. A size exceeding the
    ///      snapshot position returns `CLOSE_SIZE_EXCEEDS`. Inconsistent snapshots or arithmetic can still revert.
    /// @param snap Trusted account, side, pool, collateral, claim, carry, and risk snapshot
    /// @param order Close/decrease order; the planner does not authenticate router-level flags or timing
    /// @param executionPrice Candidate execution price used for realized PnL math (8 decimals)
    /// @return delta Complete close settlement plan or a partially populated typed failure result
    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) external pure returns (CfdEnginePlanTypes.CloseDelta memory delta);

    /// @notice Plans liquidation from a raw engine snapshot.
    /// @dev Caps the execution price at `snap.capPrice`. A snapshot without a position returns a nonliquidatable
    ///      zero/partial delta. An underfunded negative-VPI reserve reverts before eligibility is tested.
    /// @param snap Trusted account, position, pool, collateral, claim, carry, and risk snapshot
    /// @param executionPrice Candidate liquidation execution price (8 decimals)
    /// @return delta Liquidation test and, when liquidatable, the complete settlement plan
    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta);

    /// @notice Maps an open planning revert code to its commit-time or execution-time failure category.
    /// @dev Degraded mode maps to `ExecutionTimeProtocolStateInvalidated`; fee-drained margin maps to
    ///      `ExecutionTimeUserInvalid`. Other recognized failures map to `CommitTimeRejectable`.
    /// @param code Open revert code to classify
    /// @return Open failure policy category, or `None` for `OK` and unmapped values
    function getOpenFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.OpenFailurePolicyCategory);

    /// @notice Maps an open execution revert code to its router failure policy category.
    /// @param code Open revert code to classify
    /// @return Execution-time user/protocol-state category, or `None` for `OK`
    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory);

    /// @notice Maps a close execution revert code to its router failure policy category.
    /// @param code Close revert code to classify
    /// @return `None` for `OK`; every mapped close failure is user-invalid
    function getCloseExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory);

}
