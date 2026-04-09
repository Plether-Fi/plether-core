// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngineSettlementTypes} from "./CfdEngineSettlementTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";

interface ICfdEngineSettlementHost {
    function clearinghouse() external view returns (address);
    function vault() external view returns (address);
    function orderRouter() external view returns (address);

    function settlementApplyFundingAndMark(uint256 newMarkPrice, uint64 newMarkTime) external;
    function settlementSyncTotalSideMargin(CfdTypes.Side side, uint256 marginBefore, uint256 marginAfter) external;
    function settlementApplySideDelta(CfdTypes.Side side, int256 maxProfitDelta, int256 openInterestDelta, int256 entryNotionalDelta) external;
    function settlementConsumeDeferredTraderPayout(bytes32 accountId, uint256 amountUsdc) external;
    function settlementRecordDeferredTraderPayout(bytes32 accountId, uint256 amountUsdc) external;
    function settlementAccumulateFees(uint256 amountUsdc) external;
    function settlementAccumulateBadDebt(uint256 amountUsdc) external;
    function settlementWritePosition(bytes32 accountId, CfdEngineSettlementTypes.PositionState calldata position) external;
    function settlementDeletePosition(bytes32 accountId) external;
}
