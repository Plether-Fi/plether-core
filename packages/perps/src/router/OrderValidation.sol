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
        uint256 minCloseSizeDelta = _minSizeDeltaForEngineBountyFloor(_commitReferencePrice());
        if (sizeDelta < queuedPosition.size && sizeDelta < minCloseSizeDelta) {
            revert OrderRouter__CommitValidation(11);
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

    function _validateBatchBounds(
        uint64 maxOrderId
    ) internal view {
        OrderValidationLib.validateBatchBounds(maxOrderId, nextExecuteId, nextCommitId);
    }

}
