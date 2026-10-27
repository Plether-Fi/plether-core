// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {CloseCommitmentLib} from "@plether/perps/libraries/CloseCommitmentLib.sol";
import {MarketCalendarLib} from "@plether/perps/libraries/MarketCalendarLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @title CfdEnginePlanner
/// @notice Stateless external wrapper around the deterministic CFD engine planning library.
/// @dev The planner performs no storage reads, authorization, oracle verification, or input authentication. Callers
///      must supply canonical, internally consistent snapshots and orders. Unless stated otherwise, settlement token amounts use
///      6 decimals, prices use 8 decimals, sizes use 18 decimals, and timestamps are Unix seconds.
contract CfdEnginePlanner is ICfdEnginePlanner {

    function planCloseCommit(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        uint256 size
    ) external pure returns (CfdEnginePlanTypes.CloseCommitment memory effects) {
        effects = CloseCommitmentLib.project(snapshot, size);
    }

    /// @notice Classifies the recurring and governance-override market-calendar regimes.
    /// @dev Keeps the New York daylight-saving calculation in this stateless sidecar so the canonical engine remains
    ///      below the EIP-170 runtime bytecode limit. All inputs are supplied by the engine from canonical state.
    function marketCalendarStatus(
        uint256 timestamp,
        bool todayOverride,
        bool tomorrowOverride,
        uint256 fadRunwaySeconds
    ) external pure returns (bool fadWindow, bool oracleFrozen) {
        return MarketCalendarLib.marketStatus(timestamp, todayOverride, tomorrowOverride, fadRunwaySeconds);
    }

    /// @inheritdoc ICfdEnginePlanner
    function computeCurrentCarryIndex(
        uint256 storedIndex,
        uint64 previousTimestamp,
        uint256 currentTimestamp,
        uint256 borrowBaseAssets,
        uint256 poolAssets,
        uint256 baseCarryBps
    ) external pure returns (uint256 index) {
        return PositionRiskAccountingLib.computeCurrentCarryIndex(
            storedIndex, previousTimestamp, currentTimestamp, borrowBaseAssets, poolAssets, baseCarryBps
        );
    }

    /// @inheritdoc ICfdEnginePlanner
    function computeIndexedCarryAssets(
        uint256 borrowBaseAssets,
        uint256 carryIndexDelta
    ) external pure returns (uint256 carryAssets) {
        return PositionRiskAccountingLib.computeIndexedCarryAssets(borrowBaseAssets, carryIndexDelta);
    }

    /// @inheritdoc ICfdEnginePlanner
    function isExactPriceRiskLiquidatable(
        CfdTypes.Position memory pos,
        uint256 entryCostAssetAtoms,
        uint256 price,
        uint256 capPrice,
        uint256 priceCollateralAssets,
        uint256 requiredBps
    ) external pure returns (bool liquidatable) {
        return PositionRiskAccountingLib.buildExactPriceRiskState(
            pos, entryCostAssetAtoms, price, capPrice, priceCollateralAssets, requiredBps
        )
        .liquidatable;
    }

    /// @notice Plans an open or same-side increase without reading or mutating protocol state.
    /// @dev The execution price is capped at `snap.capPrice`. Expected business-rule failures are encoded in `delta.revertCode`
    ///      rather than reverted; arithmetic violations or inconsistent inputs can still revert.
    /// @param snap Trusted account, side, pool, collateral, claim, carry, and risk snapshot.
    /// @param order Open/increase order. Size must be nonzero and quantum-aligned. The planner does not require
    ///        `order.account == snap.account`, a nonzero price,
    ///        `isClose == false`, valid timestamps/target price, or router authorization; it copies `order.account` to
    ///        the result while using collateral and position state from `snap`.
    /// @param executionPrice Candidate execution price, with 8 decimals.
    /// @return delta Complete open settlement plan or a partially populated typed failure result.
    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        return CfdEnginePlanLib.planOpen(snap, order, executionPrice);
    }

    /// @notice Plans a close or same-side decrease without reading or mutating protocol state.
    /// @dev The execution price is capped at `snap.capPrice`. Zero or non-quantized close sizes return
    ///      `INVALID_SIZE_QUANTUM`; a close larger than the snapshot position returns `CLOSE_SIZE_EXCEEDS`. Inconsistent
    ///      snapshots or arithmetic violations can still revert.
    /// @param snap Trusted account, side, pool, collateral, claim, carry, and risk snapshot.
    /// @param order Close/decrease order. A side mismatch with a nonzero snapshot position returns `SIDE_MISMATCH`
    ///        before carry projection. The planner does not require `order.account == snap.account`, `isClose == true`,
    ///        valid timestamps/target price, or router authorization; it uses `order.account` and size while using
    ///        position and collateral state from `snap`.
    /// @param executionPrice Candidate execution price, with 8 decimals.
    /// @return delta Complete close settlement plan or a partially populated typed failure result.
    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) external pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        return CfdEnginePlanLib.planClose(snap, order, executionPrice);
    }

    /// @notice Plans a full liquidation without reading or mutating protocol state.
    /// @dev The execution price is capped at `snap.capPrice`. A snapshot with no position returns a nonliquidatable
    ///      zero/partial delta. An underfunded negative-VPI reserve reverts before liquidation eligibility is tested.
    /// @param snap Trusted account, position, pool, collateral, claim, carry, and risk snapshot.
    /// @param executionPrice Candidate liquidation price, with 8 decimals.
    /// @return delta Liquidation test and, when liquidatable, the complete settlement plan.
    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        return CfdEnginePlanLib.planLiquidation(snap, executionPrice);
    }

    /// @notice Classifies an open planning code for commit-time router policy.
    /// @param code Open planning result to classify.
    /// @return `CommitTimeRejectable`, an execution-only category, or `None` for `OK`/unmapped values.
    function getOpenFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.OpenFailurePolicyCategory) {
        return CfdEnginePlanLib.getOpenFailurePolicyCategory(code);
    }

    /// @notice Classifies an open planning code for execution-time router policy.
    /// @param code Open planning result to classify.
    /// @return `None` for `OK`, protocol-state invalidation for degraded/skew/solvency failures, and user invalidation
    ///         for every other open failure.
    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        return CfdEnginePlanLib.getExecutionFailurePolicyCategory(code);
    }

    /// @notice Classifies a close planning code for execution-time router policy.
    /// @param code Close planning result to classify.
    /// @return `None` for `OK`; every close failure is classified as user invalid.
    function getCloseExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) external pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        return CfdEnginePlanLib.getExecutionFailurePolicyCategory(code);
    }

}
