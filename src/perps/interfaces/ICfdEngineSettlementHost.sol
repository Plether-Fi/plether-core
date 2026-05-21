// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "../CfdTypes.sol";
import {CfdEngineSettlementTypes} from "./CfdEngineSettlementTypes.sol";

/// @notice Narrow engine hook surface callable by the settlement sidecar.
interface ICfdEngineSettlementHost {

    /// @notice Margin clearinghouse used for balances, locked margin, and settlement.
    function clearinghouse() external view returns (address);

    /// @notice HousePool backing trader positions.
    function pool() external view returns (address);

    /// @notice Order router maintaining pending-order queues and reservations.
    function orderRouter() external view returns (address);

    /// @notice Clearinghouse account that receives protocol fee credits.
    function protocolTreasury() external view returns (address);

    /// @notice Trader claim balance still owed to beneficiaries.
    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    /// @notice Applies a newer mark price and advances carry.
    /// @param newMarkPrice New mark price (8 decimals)
    /// @param newMarkTime Oracle publish timestamp for the mark
    function settlementApplyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) external;

    /// @notice Synchronizes aggregate side margin after settlement changes a position margin bucket.
    /// @param side Side whose aggregate margin should be updated
    /// @param marginBefore Account position margin before settlement
    /// @param marginAfter Account position margin after settlement
    function settlementSyncTotalSideMargin(
        CfdTypes.Side side,
        uint256 marginBefore,
        uint256 marginAfter
    ) external;

    /// @notice Applies aggregate side-accounting deltas produced by the settlement sidecar.
    /// @param side Side whose totals are mutated
    /// @param maxProfitDelta Signed max-profit envelope delta
    /// @param openInterestDelta Signed open-interest delta
    /// @param entryNotionalDelta Signed entry-notional delta
    function settlementApplySideDelta(
        CfdTypes.Side side,
        int256 maxProfitDelta,
        int256 openInterestDelta,
        int256 entryNotionalDelta
    ) external;

    /// @notice Consumes previously recorded trader-claim balance during settlement.
    /// @param account Claim account to debit
    /// @param amountUsdc Claim amount to consume
    function settlementConsumeTraderClaim(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Pays or records trader-claim value during settlement.
    /// @param account Claim beneficiary
    /// @param amountUsdc Claim amount to pay from fresh cash or record as liability
    function settlementRecordTraderClaim(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Increases accumulated bad debt during settlement.
    /// @param amountUsdc Bad-debt amount to add
    function settlementAccumulateBadDebt(
        uint256 amountUsdc
    ) external;

    /// @notice Writes the post-settlement position state.
    /// @param account Position account to write
    /// @param position New stored position state from the settlement sidecar
    function settlementWritePosition(
        address account,
        CfdEngineSettlementTypes.PositionState calldata position
    ) external;

    /// @notice Deletes an account position.
    /// @param account Position account to delete
    function settlementDeletePosition(
        address account
    ) external;

}
