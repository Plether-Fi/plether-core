// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title CfdEngineSettlementTypes
/// @notice Position-state payloads passed from the settlement sidecar to its engine host.
library CfdEngineSettlementTypes {

    /// @notice Engine-owned position fields produced by a planned settlement.
    /// @dev `size` uses 18 decimals, `entryPrice` uses 8 decimals, and `maxProfitUsdc` uses 6 decimals.
    ///      Active position margin is maintained separately in the clearinghouse. The host derives the position's
    ///      borrow base and last carry index rather than accepting them in this payload. The current host ignores
    ///      `deletePosition`; terminal paths call the dedicated position-deletion hook instead.
    /// @param deletePosition Legacy planning flag ignored by the current settlement-write host.
    /// @param size Post-settlement position size.
    /// @param entryPrice Post-settlement average entry price.
    /// @param maxProfitUsdc Post-settlement maximum-profit envelope.
    /// @param lastUpdateTime Timestamp of the position mutation.
    /// @param lastCarryTimestamp Timestamp from which subsequent position carry accrues.
    /// @param vpiAccrued Net VPI accumulated on the remaining position, in USDC with 6 decimals.
    /// @param side Direction of the post-settlement position.
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
