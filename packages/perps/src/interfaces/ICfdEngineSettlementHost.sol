// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {CfdEngineSettlementTypes} from "@plether/perps/interfaces/CfdEngineSettlementTypes.sol";

/// @notice Narrow engine hook surface callable by the settlement sidecar.
/// @dev Mutation hooks are callable only by the engine's configured settlement sidecar. USDC amounts use 6 decimals,
///      prices use 8 decimals, position sizes use 18 decimals, and timestamps are Unix seconds.
interface ICfdEngineSettlementHost {

    /// @notice Margin clearinghouse used for balances, locked margin, and settlement.
    /// @return Clearinghouse contract address
    function clearinghouse() external view returns (address);

    /// @notice HousePool backing trader positions.
    /// @return Configured HousePool address
    function pool() external view returns (address);

    /// @notice Order router maintaining pending-order queues and reservations.
    /// @return Configured order-router address
    function orderRouter() external view returns (address);

    /// @notice Clearinghouse account that receives protocol fee credits.
    /// @return Current protocol treasury account
    function protocolTreasury() external view returns (address);

    /// @notice Trader claim balance still owed to beneficiaries.
    /// @return Aggregate senior HousePool payout liability in USDC
    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    /// @notice Applies a newer mark price and advances carry.
    /// @dev A mark whose publish time is not strictly newer than the cached time is a no-op. A strictly newer mark
    ///      advances both side carry indexes to the current block timestamp and replaces the cached price and time.
    /// @param newMarkPrice New mark price (8 decimals); the sidecar supplies an already capped value
    /// @param newMarkTime Oracle publish timestamp for the mark
    function settlementApplyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) external;

    /// @notice Synchronizes aggregate side margin after settlement changes a position margin bucket.
    /// @dev Adds or subtracts the exact difference; inconsistent inputs can underflow and revert.
    /// @param side Side whose aggregate margin should be updated
    /// @param marginBefore Account position margin before settlement, in USDC
    /// @param marginAfter Account position margin after settlement, in USDC
    function settlementSyncTotalSideMargin(
        CfdTypes.Side side,
        uint256 marginBefore,
        uint256 marginAfter
    ) external;

    /// @notice Applies aggregate side-accounting deltas produced by the settlement sidecar.
    /// @dev Positive deltas add and negative deltas subtract. The sidecar must provide consistent bounded deltas;
    ///      subtraction underflow or signed-to-unsigned overflow reverts.
    /// @param side Side whose totals are mutated
    /// @param maxProfitDelta Signed maximum-profit envelope delta in USDC
    /// @param openInterestDelta Signed open-interest delta with 18 decimals
    /// @param entryNotionalDelta Signed raw `size * entryPrice` numerator delta with 26 decimals
    function settlementApplySideDelta(
        CfdTypes.Side side,
        int256 maxProfitDelta,
        int256 openInterestDelta,
        int256 entryNotionalDelta
    ) external;

    /// @notice Consumes previously recorded trader-claim balance during settlement.
    /// @dev Decreases both the account claim and aggregate claim liability by the exact amount.
    /// @param account Claim account to debit
    /// @param amountUsdc Claim amount to consume in USDC
    function settlementConsumeTraderClaim(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Pays or records trader-claim value during settlement.
    /// @dev Pays immediately only when cash remains after reserving all existing trader claims; otherwise records a new
    ///      senior claim liability. Zero is a no-op.
    /// @param account Claim beneficiary
    /// @param amountUsdc Fresh payout amount to pay or record in USDC
    function settlementRecordTraderClaim(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Increases accumulated bad debt during settlement.
    /// @param amountUsdc Bad-debt amount to add in USDC
    function settlementAccumulateBadDebt(
        uint256 amountUsdc
    ) external;

    /// @notice Writes the post-settlement position state.
    /// @dev Replaces all stored fields and refreshes the position and aggregate side carry borrow-base accounting.
    /// @param account Position account to write
    /// @param position New stored position state from the settlement sidecar
    function settlementWritePosition(
        address account,
        CfdEngineSettlementTypes.PositionState calldata position
    ) external;

    /// @notice Deletes an account position.
    /// @dev Removes the position's contribution from aggregate side carry borrow base before deleting storage.
    /// @param account Position account to delete
    function settlementDeletePosition(
        address account
    ) external;

}
