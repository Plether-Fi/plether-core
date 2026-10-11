// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Shared input-driven waterfall reference for persistent accounting campaigns.
/// @dev Extracted from the existing waterfall campaign. Callers independently derive distributable assets from
///      their action ledger (cash-only or terminal NAV); production balances, previews, and math are not inputs.
library WaterfallReferenceMath {

    struct State {
        uint256 senior;
        uint256 junior;
        uint256 highWaterMark;
        uint256 checkpoint;
    }

    struct Result {
        State state;
        bool couponRatchet;
        bool seniorLoss;
        bool seniorRestoration;
        bool juniorLoss;
    }

    /// @notice Transfer the elapsed coupon, then distribute assets by the existing Senior/Junior priority rules.
    /// @dev Allocation diagnostics compare against balances AFTER coupon payment, preserving the original campaign's
    ///      distinction between a coupon ratchet and a restoration funded by trading revenue.
    function reconcile(
        State memory prior,
        uint256 distributable,
        uint256 annualBps,
        uint256 timestamp
    ) internal pure returns (Result memory result) {
        uint256 coupon = prior.senior * annualBps * (timestamp - prior.checkpoint) / (10_000 * 365 days);
        uint256 paid = coupon < prior.junior ? coupon : prior.junior;
        prior.senior += paid;
        prior.junior -= paid;
        if (prior.senior > prior.highWaterMark) {
            prior.highWaterMark = prior.senior;
            result.couponRatchet = true;
        }
        prior.checkpoint = timestamp;

        // A loss preserves Senior's most recently recognized principal. Revenue first restores its unimpaired
        // entitlement; only the residual belongs to Junior. This is an allocation, not a production delta formula.
        uint256 target = distributable >= prior.senior + prior.junior ? prior.highWaterMark : prior.senior;
        uint256 senior = distributable < target ? distributable : target;
        uint256 junior = distributable - senior;
        result.seniorLoss = senior < prior.senior;
        result.seniorRestoration = senior > prior.senior;
        result.juniorLoss = junior < prior.junior;
        result.state = State(senior, junior, prior.highWaterMark, prior.checkpoint);
    }

}
