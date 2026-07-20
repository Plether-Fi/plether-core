// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Trader-facing action surface aligned with the current delayed-order router model.
interface IPerpsTraderActions {

    /// @notice Submits a trade intent to the delayed FIFO order queue.
    /// @dev The caller is the canonical account. Commit immediately reserves the order's keeper bounty and, for an
    ///      open/increase, its committed margin in the clearinghouse. Opens are blocked by pause, degraded, close-only,
    ///      and HousePool risk gates and may fail planner preflight. Closes must match and not exceed the position after
    ///      replaying the account's earlier queued orders; they require zero `marginDelta`.
    /// @param side Direction to open/increase, or direction of the queued position being reduced
    /// @param sizeDelta Nonzero position-size change (18 decimals)
    /// @param marginDelta Margin reserved for an open/increase in USDC; must be zero for a close
    /// @param targetPrice Direction-aware execution limit (8 decimals), or zero for no slippage limit
    /// @param isClose True for a strict position reduction and false for an open/increase
    function commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) external;

}
