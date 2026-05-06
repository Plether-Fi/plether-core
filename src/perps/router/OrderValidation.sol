// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {OrderRouterAdmin} from "../OrderRouterAdmin.sol";
import {OrderFailurePolicyLib} from "../libraries/OrderFailurePolicyLib.sol";
import {OrderValidationLib} from "../libraries/OrderValidationLib.sol";
import {OrderBountyAccounting} from "./OrderBountyAccounting.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Validation and preflight checks for delayed-order commits and execution bounds.
abstract contract OrderValidation is OrderBountyAccounting {

    uint64 public nextCommitId = 1;

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

    function _validateBaseCommit(
        uint256 sizeDelta,
        uint256 marginDelta,
        bool isClose
    ) internal pure {
        OrderValidationLib.validateBaseCommit(sizeDelta, marginDelta, isClose);
    }

    function _validatedCloseExecutionBountyUsdc(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta
    ) internal view returns (uint256) {
        QueuedPositionView memory queuedPosition = _getQueuedPositionView(account);
        OrderValidationLib.validateCloseCommit(
            queuedPosition.exists, queuedPosition.size, queuedPosition.side, side, sizeDelta
        );
        return closeOrderExecutionBountyUsdc;
    }

    function _validatedOpenExecutionBountyUsdc(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta
    ) internal view returns (uint256) {
        uint256 commitPrice = _commitReferencePrice();
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

    function _validateBatchBounds(
        uint64 maxOrderId
    ) internal view {
        OrderValidationLib.validateBatchBounds(maxOrderId, nextExecuteId, nextCommitId);
    }

}
