// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderFailurePolicyLib} from "@plether/perps/libraries/OrderFailurePolicyLib.sol";
import {OrderValidationLib} from "@plether/perps/libraries/OrderValidationLib.sol";
import {OrderBountyAccounting} from "@plether/perps/router/OrderBountyAccounting.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";

/// @title OrderValidation
/// @notice Applies protocol-state gates, close projection checks, open preflight, and batch bounds.
abstract contract OrderValidation is OrderBountyAccounting {

    /// @notice Next order id assigned by a successful commit; starts at one.
    uint64 public nextCommitId = 1;

    /// @notice Requires the protocol to permit a new risk-increasing commit.
    /// @dev Checks, in order: router-admin pause, engine degraded mode, oracle close-only policy, and HousePool
    ///      risk availability. A pool that has not completed seed lifecycle gets its dedicated error.
    function _validateOpenCommitAllowed() internal view {
        if (OrderRouterAdmin(admin).paused()) {
            revert Pausable.EnforcedPause();
        }
        if (engine.degradedMode()) {
            revert OrderRouter__DegradedMode();
        }
        if (_isCloseOnlyWindow()) {
            revert OrderRouter__CloseOnlyWindow();
        }
        if (!housePool.canIncreaseRisk()) {
            if (!housePool.isSeedLifecycleComplete()) {
                revert OrderRouter__NotInSeedLifecycle();
            }
            revert OrderRouter__VaultRiskBlocked();
        }
    }

    /// @notice Requires nonzero size and zero margin on a strict close.
    /// @param sizeDelta Requested position-size change (18 decimals).
    /// @param marginDelta Requested open margin (6-decimal USDC).
    /// @param isClose Whether the order is a strict close.
    function _validateBaseCommit(
        uint256 sizeDelta,
        uint256 marginDelta,
        bool isClose
    ) internal pure {
        OrderValidationLib.validateBaseCommit(sizeDelta, marginDelta, isClose);
    }

    /// @notice Validates a close against the account's queue-projected position and returns its fixed bounty.
    /// @dev Side must match and size cannot exceed the projected position. A partial close smaller than both
    ///      the projected position and the engine bounty-floor size is rejected; a full close remains permitted.
    /// @param account Account submitting the close.
    /// @param side Direction of the position to reduce.
    /// @param sizeDelta Requested close size (18 decimals).
    /// @return Configured fixed close bounty (6-decimal USDC).
    function _validatedCloseExecutionBountyUsdc(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta
    ) internal view returns (uint256) {
        QueuedPositionView memory queuedPosition = _getQueuedPositionView(account);
        OrderValidationLib.validateCloseCommit(
            queuedPosition.exists, queuedPosition.size, queuedPosition.side, side, sizeDelta
        );
        uint256 minCloseSizeDelta = _minSizeDeltaForEngineBountyFloor(_commitReferencePrice());
        if (sizeDelta < queuedPosition.size && sizeDelta < minCloseSizeDelta) {
            revert OrderRouter__CommitValidation(11);
        }
        return closeOrderExecutionBountyUsdc;
    }

    /// @notice Enforces minimum open notional, optionally rejects predictable engine failures, and quotes bounty.
    /// @dev The cap-bounded stored mark (or 1e8 fallback) supplies commit notional. Engine preview rejection is
    ///      used only when that mark has a nonzero timestamp and is fresh under the active open policy.
    /// @param account Account submitting the open/increase.
    /// @param side Requested direction.
    /// @param sizeDelta Requested size increase (18 decimals).
    /// @param marginDelta Margin to reserve (6-decimal USDC).
    /// @return Floor/cap-bounded open bounty (6-decimal USDC).
    function _validatedOpenExecutionBountyUsdc(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta
    ) internal view returns (uint256) {
        uint256 commitPrice = _commitReferencePrice();
        uint256 notionalUsdc = (sizeDelta * commitPrice) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        if (notionalUsdc < minOpenNotionalUsdc) {
            revert OrderRouter__CommitValidation(11);
        }
        if (_canUseCommitMarkForOpenPrefilter()) {
            uint64 commitMarkTime = engine.lastMarkTime();
            CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
                account, side, sizeDelta, marginDelta, commitPrice, commitMarkTime
            );
            uint8 revertCode =
                engineLens.previewOpenRevertCode(account, side, sizeDelta, marginDelta, commitPrice, commitMarkTime);
            if (OrderFailurePolicyLib.isPredictablyInvalidOpen(failureCategory)) {
                revert OrderRouter__PredictableOpenInvalid(revertCode);
            }
        }
        return _quoteOpenOrderExecutionBountyUsdc(sizeDelta, commitPrice);
    }

    /// @notice Requires a nonempty queue and a committed inclusive batch bound at or after the head.
    /// @param maxOrderId Inclusive last order id a batch may process.
    function _validateBatchBounds(
        uint64 maxOrderId
    ) internal view {
        OrderValidationLib.validateBatchBounds(maxOrderId, nextExecuteId, nextCommitId);
    }

}
