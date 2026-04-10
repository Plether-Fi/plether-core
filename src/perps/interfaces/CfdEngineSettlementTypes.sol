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

}
