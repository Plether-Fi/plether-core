// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {CfdEngineSettlementTypes} from "./CfdEngineSettlementTypes.sol";

interface ICfdEngineSettlementHost {

    function clearinghouse() external view returns (address);
    function vault() external view returns (address);
    function orderRouter() external view returns (address);

    function settlementApplyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) external;
    function settlementSyncTotalSideMargin(
        CfdTypes.Side side,
        uint256 marginBefore,
        uint256 marginAfter
    ) external;
    function settlementApplySideDelta(
        CfdTypes.Side side,
        int256 maxProfitDelta,
        int256 openInterestDelta,
        int256 entryNotionalDelta
    ) external;
    function settlementConsumeDeferredTraderPayout(
        address account,
        uint256 amountUsdc
    ) external;
    function settlementRecordDeferredTraderPayout(
        address account,
        uint256 amountUsdc
    ) external;
    function settlementAccumulateFees(
        uint256 amountUsdc
    ) external;
    function settlementAccumulateBadDebt(
        uint256 amountUsdc
    ) external;
    function settlementWritePosition(
        address account,
        CfdEngineSettlementTypes.PositionState calldata position
    ) external;
    function settlementDeletePosition(
        address account
    ) external;

}
