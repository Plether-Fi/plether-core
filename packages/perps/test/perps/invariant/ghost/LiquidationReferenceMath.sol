// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Independent liquidation arithmetic for the mixed campaign's fixed risk configuration.
/// @dev Inputs are the action ledger after direct margin-first/free-second carry collection. No production
/// libraries, previews, observed balances, or event values enter this calculation. The fixture charges 10 bps,
/// a $1 floor, and gives half to the keeper and the remainder to LPs. Positive lifetime VPI is already paid.
library LiquidationReferenceMath {

    struct Input {
        bool isLong;
        uint256 lots;
        uint256 basis;
        uint256 price;
        uint256 pledge;
        uint256 free;
        uint256 cash;
        uint256 claim;
        uint256 allClaims;
        uint256 poolCash;
        uint256 liquidationReserve;
        uint256 vpiClawback;
        uint256 actionReserve;
        uint256 committedMargin;
        uint256 unpaidCarry;
        uint256 maintenanceBps;
    }

    struct Values {
        bool eligible;
        int256 pnl;
        int256 equity;
        uint256 maintenance;
        uint256 claimConsumed;
        uint256 pledgeConsumed;
        uint256 writtenOff;
        uint256 charge;
        uint256 keeper;
        uint256 lpFee;
        uint256 gain;
        uint256 vpiWithheld;
        uint256 vpiConsumed;
        uint256 vpiReleased;
        uint256 carryWithheld;
        uint256 carryCash;
        uint256 carryWaived;
        uint256 actionReserveConsumed;
        uint256 freeConsumed;
        uint256 committedConsumed;
        uint256 fresh;
        uint256 immediate;
        uint256 deferred;
        uint256 retainedCash;
        uint256 remainingClaim;
        uint256 poolCashAfter;
        uint256 allClaimsAfter;
    }

    function calculate(
        Input memory x
    ) internal pure returns (Values memory v) {
        v.pnl = int256(x.basis) - int256(x.lots * x.price);
        if (!x.isLong) {
            v.pnl = -v.pnl;
        }
        v.equity = int256(x.pledge + x.claim) + v.pnl;
        v.maintenance = x.lots * x.price * x.maintenanceBps / 10_000;
        v.eligible = x.lots != 0 && (v.equity <= int256(v.maintenance) || x.unpaidCarry != 0);
        if (!v.eligible) {
            return v;
        }

        if (v.pnl < 0) {
            uint256 loss = uint256(-v.pnl);
            v.claimConsumed = _min(loss, x.claim);
            v.pledgeConsumed = _min(loss - v.claimConsumed, x.pledge);
            v.writtenOff = loss - v.claimConsumed - v.pledgeConsumed;
        } else {
            v.gain = uint256(v.pnl);
        }
        uint256 requested = x.lots * x.price / 1000;
        if (requested < 1e6) {
            requested = 1e6;
        }
        v.charge = _min(requested, x.liquidationReserve);
        v.keeper = v.charge / 2;
        v.lpFee = v.charge - v.keeper;

        // Treat VPI and carry as separate obligations. Withheld gains replace VPI backing first;
        // that released backing can then pay carry. Neither old claims nor the keeper reserve pay carry.
        v.vpiWithheld = _min(v.gain, x.vpiClawback);
        v.vpiConsumed = x.vpiClawback - v.vpiWithheld;
        v.vpiReleased = v.vpiWithheld;
        v.carryWithheld = _min(v.gain - v.vpiWithheld, x.unpaidCarry);
        uint256 due = x.unpaidCarry - v.carryWithheld;
        v.actionReserveConsumed = _min(due, x.actionReserve);
        due -= v.actionReserveConsumed;
        v.freeConsumed = _min(due, x.free + v.vpiReleased);
        due -= v.freeConsumed;
        v.committedConsumed = _min(due, x.committedMargin);
        v.carryWaived = due - v.committedConsumed;
        v.carryCash = x.unpaidCarry - v.carryWithheld - v.carryWaived;
        v.fresh = v.gain - v.vpiWithheld - v.carryWithheld;
        v.allClaimsAfter = x.allClaims - v.claimConsumed;
        v.poolCashAfter = x.poolCash + v.pledgeConsumed + v.lpFee + v.vpiConsumed + v.carryCash;
        uint256 available = v.poolCashAfter > v.allClaimsAfter ? v.poolCashAfter - v.allClaimsAfter : 0;
        if (v.fresh <= available) {
            v.immediate = v.fresh;
            v.poolCashAfter -= v.fresh;
        } else {
            v.deferred = v.fresh;
            v.allClaimsAfter += v.fresh;
        }
        v.retainedCash = x.cash - v.pledgeConsumed - v.charge - v.vpiConsumed - v.carryCash + v.immediate;
        v.remainingClaim = x.claim - v.claimConsumed + v.deferred;
    }

    function _min(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a < b ? a : b;
    }

}
