// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Input-only close ledger for the mixed campaign's fixed risk configuration.
/// @dev Inputs describe custody AFTER the ordinary margin/free carry checkpoint and BEFORE the executing order's
/// bounty is transferred. No production imports, observations, previews or event values enter this calculation.
/// Lots are whole 100-token lots: lots * eight-decimal price is already six-decimal settlement token atoms. The bounded fixture
/// uses cap 2e8, execution fee 4 bps, frozen spread 50 bps and liquidation reserve 10 bps with a one-settlement token floor.
/// The caller supplies the independently selected live/FAD maintenance rate. Price settlement solves conservation
/// and strict-health constraints; it does not assume that a partial close always releases its pro-rata pledge.
/// This helper classifies Engine close settlement, not Router commitment admission or protected-bounty routing.
library CloseReferenceMath {

    uint256 internal constant CAP = 2e8;

    struct Input {
        bool isLong;
        uint256 lots;
        uint256 basis;
        uint256 margin;
        uint256 cash;
        uint256 claim;
        uint256 liquidationReserve;
        int256 lifetimeVpi;
        uint256 closeLots;
        uint256 price;
        int256 vpiDelta;
        bool frozen;
        uint256 unpaidCarry;
        uint256 committedMargin;
        uint256 protectedBounty;
        uint256 otherActionReserve;
        uint256 vpiReserve;
        uint256 poolCash;
        uint256 poolAccounted;
        uint256 allClaims;
        uint256 maintenanceBps;
    }

    struct Values {
        bool valid;
        uint8 revertCode; // 1 size exceeds, 3 zero lots, 4 partial charge shortfall, 5 VPI backing, 6 residual health
        bool terminal;
        uint256 closedBasis;
        uint256 remainingLots;
        uint256 remainingBasis;
        uint256 remainingMargin;
        uint256 remainingCash;
        uint256 remainingClaim;
        int256 remainingVpi;
        uint256 remainingLiquidationReserve;
        uint256 remainingVpiReserve;
        uint256 remainingFree;
        int256 pnl;
        int256 remainingPnl;
        int256 preTerminalLpDelta;
        int256 requiredResidualLpDelta;
        uint256 claimConsumed;
        uint256 pledgeConsumed;
        uint256 writtenOff;
        uint256 safeMarginRelease;
        uint256 priceGain;
        uint256 pricePayout;
        uint256 immediatePayout;
        uint256 deferredPayout;
        int256 proportionalVpi;
        int256 vpi;
        int256 actionNet;
        uint256 assessedFee;
        uint256 assessedSpread;
        uint256 actionAssessed;
        uint256 actionWithheld;
        uint256 actionCash;
        uint256 actionWaived;
        uint256 carryCash;
        uint256 carryWithheld;
        uint256 carryVpiOffset;
        uint256 carryWaived;
        uint256 vpiConsumed;
        uint256 vpiReleased;
        uint256 spendableActionConsumed;
        uint256 freeConsumed;
        uint256 releasedMarginConsumed;
        uint256 committedMarginConsumed;
        uint256 liquidationReserveReleased;
        uint256 feeFromCash;
        uint256 feeTopUp;
        uint256 treasuryCredit;
        uint256 rebateAssessed;
        uint256 rebatePaid;
        uint256 rebateWaived;
        uint256 poolCashAfter;
        uint256 poolAccountedAfter;
        uint256 allClaimsAfter;
        uint256 maintenance;
        int256 remainingEquity;
    }

    struct PriceBounds {
        uint256 proRataPledge;
        uint256 pledgeAfterLoss;
        uint256 claimAfterLoss;
        uint256 lowerRecovery;
        uint256 upperPledgeLoss;
        uint256 maximumRelease;
        uint256 netGain;
        int256 prePnl;
        int256 rawResidualLp;
    }

    error InvalidReferenceInput();

    function calculate(
        Input memory x
    ) internal pure returns (Values memory v) {
        if (x.closeLots == 0) {
            v.revertCode = 3;
            return v;
        }
        if (x.closeLots > x.lots) {
            v.revertCode = 1;
            return v;
        }
        if (x.vpiReserve < _negative(x.lifetimeVpi)) {
            v.revertCode = 5;
            return v;
        }
        if (x.claim > x.allClaims || x.basis > x.lots * CAP) {
            revert InvalidReferenceInput();
        }
        if (x.price > CAP) {
            x.price = CAP;
        }
        v.terminal = x.closeLots == x.lots;
        v.remainingLots = x.lots - x.closeLots;
        v.closedBasis = x.basis * x.closeLots / x.lots;
        v.remainingBasis = x.basis - v.closedBasis;
        v.pnl = _pnl(x.isLong, x.closeLots, v.closedBasis, x.price);
        v.remainingPnl = _pnl(x.isLong, v.remainingLots, v.remainingBasis, x.price);
        v.priceGain = _positive(v.pnl);
        v.proportionalVpi = x.lifetimeVpi * int256(x.closeLots) / int256(x.lots);
        v.remainingVpi = x.lifetimeVpi - v.proportionalVpi;
        v.remainingVpiReserve = _negative(v.remainingVpi);
        v.vpi = x.vpiDelta > -v.proportionalVpi ? x.vpiDelta : -v.proportionalVpi;
        v.assessedFee = x.closeLots * x.price / 2500;
        v.assessedSpread = x.frozen ? x.closeLots * x.price / 200 : 0;
        v.actionNet = v.vpi + int256(v.assessedFee + v.assessedSpread + x.unpaidCarry);
        v.actionAssessed = _positive(v.actionNet);
        v.actionWithheld = _min(v.priceGain, v.actionAssessed);
        v.rebateAssessed = _negative(v.actionNet);
        v.pricePayout = v.priceGain - v.actionWithheld;
        v.maintenance = v.remainingLots * x.price * x.maintenanceBps / 10_000;

        if (!_priceConstraints(x, v)) {
            v.revertCode = 6;
            return v;
        }
        _cashSources(x, v);
        _attributeCarry(x, v);
        if (!v.terminal && v.actionWaived != 0) {
            v.revertCode = 4;
            return v;
        }
        _payoutAndFees(x, v);
        v.remainingEquity = int256(v.remainingMargin + v.remainingClaim) + v.remainingPnl;
        if (!v.terminal && v.remainingEquity <= int256(v.maintenance)) {
            v.revertCode = 6;
            return v;
        }
        uint256 stillLocked = v.remainingMargin + v.remainingLiquidationReserve + v.remainingVpiReserve
            + x.protectedBounty + x.committedMargin - v.committedMarginConsumed + x.otherActionReserve
            - v.spendableActionConsumed;
        if (stillLocked > v.remainingCash) {
            revert InvalidReferenceInput();
        }
        v.remainingFree = v.remainingCash - stillLocked;
        v.valid = true;
    }

    /// @dev Select the smallest permitted price recovery, then the greatest permitted release. The constraints are:
    ///      (1) claims net first; (2) pro-rata pledge pays its allocated loss; (3) recovered loss plus the residual
    ///      terminal curve equals the original curve; (4) release cannot exceed unused pro-rata pledge; and
    ///      (5) residual price equity is strictly above the active requirement, including any fresh net gain once.
    function _priceConstraints(
        Input memory x,
        Values memory v
    ) private pure returns (bool) {
        PriceBounds memory b;
        b.proRataPledge = x.margin * x.closeLots / x.lots;
        b.prePnl = v.pnl + v.remainingPnl;
        v.preTerminalLpDelta = -b.prePnl;
        if (v.preTerminalLpDelta > int256(x.margin + x.claim)) {
            v.preTerminalLpDelta = int256(x.margin + x.claim);
        }
        b.rawResidualLp = -v.remainingPnl;
        if (v.pnl < 0) {
            uint256 loss = uint256(-v.pnl);
            v.claimConsumed = _min(loss, x.claim);
            b.upperPledgeLoss = _min(x.margin, loss - v.claimConsumed);
            // The remaining raw loss is an upper bound on future recovery. Anything it cannot recover must be
            // collected now, including the exact basis remainder that a simple pro-rata margin model misses.
            b.lowerRecovery = _positive(v.preTerminalLpDelta - int256(_positive(b.rawResidualLp)));
            uint256 allocatedRecovery = _min(b.proRataPledge, loss - v.claimConsumed);
            uint256 necessaryPledge = _positive(int256(b.lowerRecovery) - int256(v.claimConsumed));
            v.pledgeConsumed = _min(_max(allocatedRecovery, necessaryPledge), b.upperPledgeLoss);
            v.writtenOff = loss - v.claimConsumed - v.pledgeConsumed;
        }
        b.pledgeAfterLoss = x.margin - v.pledgeConsumed;
        b.claimAfterLoss = x.claim - v.claimConsumed;
        int256 realizedLp = v.pnl < 0 ? int256(v.claimConsumed + v.pledgeConsumed) : -int256(v.priceGain);
        v.requiredResidualLpDelta = v.preTerminalLpDelta - realizedLp;
        b.maximumRelease = b.proRataPledge > v.pledgeConsumed ? b.proRataPledge - v.pledgeConsumed : 0;
        if (!v.terminal) {
            if (b.rawResidualLp > 0) {
                uint256 availableBacking = b.pledgeAfterLoss + b.claimAfterLoss;
                uint256 needed = _positive(v.requiredResidualLpDelta);
                b.maximumRelease = _min(b.maximumRelease, availableBacking > needed ? availableBacking - needed : 0);
            }
            b.netGain = v.pricePayout;
            int256 equityBeforeRelease = int256(b.pledgeAfterLoss + b.claimAfterLoss + b.netGain) + v.remainingPnl;
            if (equityBeforeRelease <= int256(v.maintenance)) {
                return false;
            }
            b.maximumRelease = _min(b.maximumRelease, uint256(equityBeforeRelease) - v.maintenance - 1);
            if (b.rawResidualLp > 0) {
                uint256 residualBacking = b.pledgeAfterLoss + b.claimAfterLoss - b.maximumRelease;
                if (int256(_min(uint256(b.rawResidualLp), residualBacking)) != v.requiredResidualLpDelta) {
                    return false;
                }
            }
        }
        v.safeMarginRelease = b.maximumRelease;
        v.remainingMargin = b.pledgeAfterLoss - b.maximumRelease;
        v.remainingClaim = b.claimAfterLoss;
        return true;
    }

    /// @dev The four generic sources form an ordered cash budget. Only full closes may use released liquidation
    ///      reserve and pending-order margin. Every bounty and the surviving negative-VPI reserve stay protected.
    function _cashSources(
        Input memory x,
        Values memory v
    ) private pure {
        uint256 lockedBefore = x.margin + x.liquidationReserve + x.vpiReserve + x.protectedBounty + x.otherActionReserve
            + x.committedMargin;
        if (lockedBefore > x.cash) {
            revert InvalidReferenceInput();
        }
        uint256 reserveTarget = v.terminal ? 0 : _max(v.remainingLots * x.price / 1000, 1e6);
        v.remainingLiquidationReserve = _min(reserveTarget, x.liquidationReserve);
        v.liquidationReserveReleased = x.liquidationReserve - v.remainingLiquidationReserve;
        uint256 clawback = _negative(x.lifetimeVpi) - v.remainingVpiReserve;
        v.vpiConsumed = clawback > v.actionWithheld ? clawback - v.actionWithheld : 0;
        v.vpiReleased = x.vpiReserve - v.remainingVpiReserve - v.vpiConsumed;
        uint256 due = v.actionAssessed - v.actionWithheld - v.vpiConsumed;
        uint256[4] memory capacity = [
            x.otherActionReserve,
            x.cash - lockedBefore + v.vpiReleased + (v.terminal ? v.liquidationReserveReleased : 0),
            v.safeMarginRelease,
            v.terminal ? x.committedMargin : 0
        ];
        uint256[4] memory spent;
        for (uint256 i; i < 4; ++i) {
            spent[i] = _min(due, capacity[i]);
            due -= spent[i];
        }
        v.spendableActionConsumed = spent[0];
        v.freeConsumed = spent[1];
        v.releasedMarginConsumed = spent[2];
        v.committedMarginConsumed = spent[3];
        v.actionWaived = due;
        v.actionCash = v.actionAssessed - v.actionWithheld - due;
    }

    /// @dev Attribute the net action obligation using the model's economic priority: fee and positive VPI before
    ///      carry, then frozen spread. A negative VPI adjustment cancels the lowest-priority assessment first;
    ///      after spread it offsets carry. This is a noncash resolution of carry, distinct from retained price gain
    ///      or forgiveness of a cash shortfall. Gain withholding pays the surviving priority budget before custody.
    ///      Production exposes the combined action settlement, not a separate per-charge attribution event.
    function _attributeCarry(
        Input memory x,
        Values memory v
    ) private pure {
        uint256 negativeVpi = _negative(v.vpi);
        v.carryVpiOffset = _min(x.unpaidCarry, negativeVpi > v.assessedSpread ? negativeVpi - v.assessedSpread : 0);
        uint256 carryDue = x.unpaidCarry - v.carryVpiOffset;
        uint256 priorCharges = v.assessedFee + _positive(v.vpi);
        uint256 recovered = v.actionWithheld + v.actionCash;
        uint256 recoveredCarry = _min(carryDue, recovered > priorCharges ? recovered - priorCharges : 0);
        v.carryWithheld = _min(carryDue, v.actionWithheld > priorCharges ? v.actionWithheld - priorCharges : 0);
        v.carryCash = recoveredCarry - v.carryWithheld;
        v.carryWaived = carryDue - recoveredCarry;
    }

    function _payoutAndFees(
        Input memory x,
        Values memory v
    ) private pure {
        uint256 clawback = _negative(x.lifetimeVpi) - v.remainingVpiReserve;
        uint256 nonClawbackRecovery = v.actionWithheld + v.actionCash - clawback;
        uint256 collectibleFee = _min(v.assessedFee, nonClawbackRecovery);
        uint256 feeWithheld = _min(collectibleFee, v.actionWithheld > clawback ? v.actionWithheld - clawback : 0);
        v.feeFromCash = collectibleFee - feeWithheld;
        v.poolCashAfter = x.poolCash + v.pledgeConsumed + v.actionCash - v.feeFromCash;
        v.allClaimsAfter = x.allClaims - v.claimConsumed;
        if (v.pricePayout <= _unreserved(v.poolCashAfter, v.allClaimsAfter)) {
            v.immediatePayout = v.pricePayout;
            v.poolCashAfter -= v.pricePayout;
            if (!v.terminal) {
                v.remainingMargin += v.pricePayout;
            }
        } else {
            v.deferredPayout = v.pricePayout;
            v.remainingClaim += v.pricePayout;
            v.allClaimsAfter += v.pricePayout;
        }
        v.rebatePaid = _min(v.rebateAssessed, _unreserved(v.poolCashAfter, v.allClaimsAfter));
        v.rebateWaived = v.rebateAssessed - v.rebatePaid;
        v.poolCashAfter -= v.rebatePaid;
        v.feeTopUp = _min(feeWithheld, _unreserved(v.poolCashAfter, v.allClaimsAfter));
        v.poolCashAfter -= v.feeTopUp;
        v.treasuryCredit = v.feeFromCash + v.feeTopUp;
        v.remainingCash = x.cash - v.pledgeConsumed - v.actionCash + v.immediatePayout + v.rebatePaid;
        int256 accounted = int256(x.poolAccounted) + int256(v.poolCashAfter) - int256(x.poolCash);
        if (accounted < 0) {
            revert InvalidReferenceInput();
        }
        v.poolAccountedAfter = uint256(accounted);
    }

    function _pnl(
        bool isLong,
        uint256 lots,
        uint256 basis,
        uint256 price
    ) private pure returns (int256) {
        int256 delta = int256(basis) - int256(lots * price);
        return isLong ? delta : -delta;
    }

    function _unreserved(
        uint256 cash,
        uint256 claims
    ) private pure returns (uint256) {
        return cash > claims ? cash - claims : 0;
    }

    function _negative(
        int256 value
    ) private pure returns (uint256) {
        return value < 0 ? uint256(-value) : 0;
    }

    function _positive(
        int256 value
    ) private pure returns (uint256) {
        return value > 0 ? uint256(value) : 0;
    }

    function _min(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a > b ? a : b;
    }

}
