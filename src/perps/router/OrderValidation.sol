// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {OrderRouterAdmin} from "../OrderRouterAdmin.sol";
import {IOrderRouterErrors} from "../interfaces/IOrderRouterErrors.sol";
import {OrderFailurePolicyLib} from "../libraries/OrderFailurePolicyLib.sol";
import {OrderValidationLib} from "../libraries/OrderValidationLib.sol";
import {OrderUtils} from "./OrderUtils.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Validation and preflight checks for delayed-order commits and execution bounds.
abstract contract OrderValidation is OrderUtils {

    function _validateOpenCommitAllowed() internal view {
        if (OrderRouterAdmin(admin).paused()) {
            revert Pausable.EnforcedPause();
        }
        if (engine.degradedMode()) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(9);
        }
        if (_isCloseOnlyWindow()) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(10);
        }
        if (!housePool.canIncreaseRisk()) {
            if (!housePool.isSeedLifecycleComplete()) {
                revert IOrderRouterErrors.OrderRouter__CommitValidation(0);
            }
            revert IOrderRouterErrors.OrderRouter__CommitValidation(1);
        }
    }

    function _validateBaseCommit(
        uint256 sizeDelta,
        uint256 marginDelta,
        bool isClose
    ) internal pure {
        (bool zeroSize, uint8 validationCode) = OrderValidationLib.validateBaseCommit(sizeDelta, marginDelta, isClose);
        if (zeroSize) {
            revert IOrderRouterErrors.OrderRouter__ZeroSize();
        }
        if (validationCode != 0) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(validationCode);
        }
    }

    function _validatedCloseExecutionBountyUsdc(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta
    ) internal view returns (uint256) {
        QueuedPositionView memory queuedPosition = _getQueuedPositionView(account);
        uint8 validationCode = OrderValidationLib.validateCloseCommit(
            queuedPosition.exists, queuedPosition.size, queuedPosition.side, side, sizeDelta
        );
        if (validationCode != 0) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(validationCode);
        }
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
                revert IOrderRouterErrors.OrderRouter__PredictableOpenInvalid(revertCode);
            }
        }
        return _quoteOpenOrderExecutionBountyUsdc(sizeDelta, commitPrice);
    }

    function _validateBatchBounds(
        uint64 maxOrderId
    ) internal view {
        if (nextExecuteId == 0) {
            revert IOrderRouterErrors.OrderRouter__QueueState(0);
        }
        uint8 validationCode = OrderValidationLib.validateBatchBounds(maxOrderId, nextExecuteId, nextCommitId);
        if (validationCode != 0) {
            revert IOrderRouterErrors.OrderRouter__QueueState(validationCode);
        }
    }

}
