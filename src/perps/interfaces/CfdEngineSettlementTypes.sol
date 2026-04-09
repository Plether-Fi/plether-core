// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";

library CfdEngineSettlementTypes {

    struct PositionState {
        bool deletePosition;
        uint256 size;
        uint256 entryPrice;
        uint256 maxProfitUsdc;
        uint64 lastUpdateTime;
        uint64 lastCarryTimestamp;
        int256 vpiAccrued;
        CfdTypes.Side side;
    }

    struct SideDelta {
        CfdTypes.Side side;
        int256 maxProfitDelta;
        int256 openInterestDelta;
        int256 entryNotionalDelta;
    }

    struct DeferredDelta {
        bytes32 accountId;
        uint256 existingDeferredConsumedUsdc;
        uint256 freshDeferredPayoutUsdc;
    }

    struct VaultInflow {
        uint256 physicalCashReceivedUsdc;
        uint256 protocolOwnedUsdc;
        uint256 lpOwnedUsdc;
    }

    struct MinimalApplyPlan {
        PositionState position;
        SideDelta sideDelta;
        DeferredDelta deferred;
        VaultInflow vaultInflow;
        uint256 accumulatedFeesDeltaUsdc;
        uint256 badDebtDeltaUsdc;
        uint256 syncMarginQueueAmountUsdc;
        uint256 keeperBountyUsdc;
        uint256 pendingVaultPayoutUsdc;
    }

    struct OpenApplyInputs {
        CfdEnginePlanTypes.OpenDelta delta;
        CfdTypes.Position currentPosition;
        uint256 timestampNow;
    }

    struct CloseApplyInputs {
        CfdEnginePlanTypes.CloseDelta delta;
        CfdTypes.Position currentPosition;
        uint256 timestampNow;
    }

    struct LiquidationApplyInputs {
        CfdEnginePlanTypes.LiquidationDelta delta;
        uint256 timestampNow;
    }
}
