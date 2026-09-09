// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

/// @title CfdEngineOpenQuoter
/// @notice Stateless interval search for the largest canonical planner-valid open.
/// @dev Deployed by CfdEngineLens to keep the lens runtime within EIP-170. Like the planner, this helper trusts its
///      supplied snapshot; applications should call the lens. Only optimistic interval bounds can discard a range.
///      Exact candidates always go through the supplied planner with the original, unmodified snapshot.
contract CfdEngineOpenQuoter {

    /// @notice Maximum interval evaluations before an explicit failure instead of an unproven quote.
    uint256 public constant MAX_SEARCH_NODES = 512;

    struct Interval {
        uint256 low;
        uint256 high;
    }

    struct Context {
        CfdEnginePlanTypes.RawSnapshot snap;
        uint256 price;
        uint256 marginDelta;
        uint256 currentLots;
        uint256 selectedLots;
        uint256 opposingLots;
        uint256 selectedLiability;
        uint256 opposingLiability;
        uint256 profitPerLot;
        int256 pricePnl;
        int256 preSkewCost;
    }

    /// @notice Quotes a global maximum, with a canonical plan and a diagnostic rejection at the next quantum.
    /// @dev A zero result includes the failed plan at the minimum notional-admissible size (one lot at zero price).
    ///      Numeric/dependency failures propagate as in previewOpen. This does not check router or terminal-book gates.
    /// @param planner Canonical planner bound to the caller's engine.
    /// @param raw Original snapshot, retained unchanged for every probe.
    /// @param order Account, side and margin budget; its size is replaced for each candidate.
    /// @param executionPrice Hypothetical execution price before capping.
    /// @param publishTime Hypothetical publish time, passed through to the planner.
    /// @return maxSizeDelta Largest valid size, or zero when the entire feasible domain is empty.
    /// @return delta Canonical plan for the maximum, or the minimum candidate on a zero quote.
    /// @return limitingReason Next-quantum rejection, or the diagnostic plan's rejection on a zero quote.
    function quote(
        ICfdEnginePlanner planner,
        CfdEnginePlanTypes.RawSnapshot calldata raw,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    )
        external
        pure
        returns (
            uint256 maxSizeDelta,
            CfdEnginePlanTypes.OpenDelta memory delta,
            CfdEnginePlanTypes.OpenRevertCode limitingReason
        )
    {
        uint256 price = Math.min(executionPrice, raw.capPrice);
        uint256 currentLots = raw.position.size / CfdTypes.SIZE_QUANTUM;
        uint256 minimumLots = price == 0
            ? currentLots + 1
            : Math.mulDiv(raw.riskParams.minBountyUsdc, 10_000, price * raw.riskParams.bountyBps, Math.Rounding.Ceil);
        uint256 low = minimumLots > currentLots ? minimumLots - currentLots : 1;

        // Calldata-to-memory copies isolate the bound projection from every canonical planner probe.
        CfdEnginePlanTypes.RawSnapshot memory projected = raw;
        bool carryCollectible = CfdEnginePlanLib.projectOpenCarry(projected);
        if (
            price == 0 || !carryCollectible || projected.degradedMode
                || (projected.position.size > 0 && projected.position.side != order.side)
                || projected.vpiRebateReserveUsdc < _negativeReserve(projected.position.vpiAccrued)
        ) {
            delta = _probe(planner, raw, order, low, executionPrice, publishTime);
            return (0, delta, delta.revertCode);
        }

        Context memory ctx = _context(projected, order, price);
        uint256 high = _upperBound(ctx);
        if (high >= low) {
            // An ABI size has at most 190 lot bits (uint256 / 1e20). Right-first bisection therefore needs at most
            // 191 pending intervals, regardless of the number of nodes visited or the shape of planner validity.
            Interval[192] memory pending;
            uint256 count = 1;
            uint256 visited;
            pending[0] = Interval(low, high);
            while (count > 0) {
                if (++visited > MAX_SEARCH_NODES) {
                    revert ICfdEngineLens.CfdEngineLens__QuoteSearchLimitExceeded();
                }
                Interval memory range = pending[--count];
                if (!_mayContainValid(ctx, range.low, range.high)) {
                    continue;
                }
                delta = _probe(planner, raw, order, range.high, executionPrice, publishTime);
                if (delta.valid) {
                    maxSizeDelta = range.high * CfdTypes.SIZE_QUANTUM;
                    CfdEnginePlanTypes.OpenDelta memory next =
                        _probe(planner, raw, order, range.high + 1, executionPrice, publishTime);
                    return (maxSizeDelta, delta, next.revertCode);
                }
                // Only this single tested endpoint is known to fail. Both remaining halves stay in the search.
                if (range.low < range.high) {
                    uint256 last = range.high - 1;
                    uint256 mid = range.low + (last - range.low) / 2;
                    pending[count++] = Interval(range.low, mid);
                    if (mid < last) {
                        pending[count++] = Interval(mid + 1, last);
                    }
                }
            }
        }
        delta = _probe(planner, raw, order, low, executionPrice, publishTime);
        return (0, delta, delta.revertCode);
    }

    function _probe(
        ICfdEnginePlanner planner,
        CfdEnginePlanTypes.RawSnapshot calldata raw,
        CfdTypes.Order memory order,
        uint256 lots,
        uint256 executionPrice,
        uint64 publishTime
    ) private pure returns (CfdEnginePlanTypes.OpenDelta memory) {
        order.sizeDelta = lots * CfdTypes.SIZE_QUANTUM;
        return planner.planOpen(raw, order, executionPrice, publishTime);
    }

    function _context(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 price
    ) private pure returns (Context memory ctx) {
        ctx.snap = snap;
        ctx.price = price;
        ctx.marginDelta = order.marginDelta;
        ctx.currentLots = snap.position.size / CfdTypes.SIZE_QUANTUM;
        bool isLong = order.side == CfdTypes.Side.LONG;
        CfdEnginePlanTypes.SideSnapshot memory selected = isLong ? snap.longSide : snap.shortSide;
        CfdEnginePlanTypes.SideSnapshot memory opposing = isLong ? snap.shortSide : snap.longSide;
        ctx.selectedLots = selected.openInterest / CfdTypes.SIZE_QUANTUM;
        ctx.opposingLots = opposing.openInterest / CfdTypes.SIZE_QUANTUM;
        ctx.selectedLiability = selected.maxProfitUsdc;
        ctx.opposingLiability = opposing.maxProfitUsdc;
        ctx.profitPerLot = isLong ? price : snap.capPrice - price;
        (bool profit, uint256 pnl) = CfdMath.calculateExactPnl(
            ctx.currentLots, snap.positionEntryCostUsdcAtoms, order.side, price, snap.capPrice
        );
        ctx.pricePnl = profit ? SafeCast.toInt256(pnl) : -SafeCast.toInt256(pnl);
        ctx.preSkewCost = SafeCast.toInt256(_skewCost(ctx, _skew(ctx, 0)));
    }

    /// @dev Pledge cannot grow by more than marginDelta, and exact price PnL is unchanged by an open at this price.
    ///      Invert FLOOR(notional * IM / BPS) <= equity using CEIL((equity + 1) * BPS / denominator) - 1.
    ///      Skew uses the carry-projected depth. Healing exceptions still cannot finish above opposing OI + the cap.
    function _upperBound(
        Context memory ctx
    ) private pure returns (uint256 high) {
        int256 equity = SafeCast.toInt256(
            ctx.snap.position.margin + ctx.marginDelta + ctx.snap.traderClaimBalanceForAccount
        ) + ctx.pricePnl;
        if (equity < 0) {
            return 0;
        }
        uint256 maxTotalLots = Math.mulDiv(
            uint256(equity) + 1, 10_000, ctx.price * ctx.snap.riskParams.initMarginBps, Math.Rounding.Ceil
        ) - 1;
        if (maxTotalLots <= ctx.currentLots) {
            return 0;
        }
        high = Math.min(maxTotalLots - ctx.currentLots, type(uint256).max / CfdTypes.SIZE_QUANTUM - ctx.currentLots);
        if (ctx.snap.poolAssetsUsdc > 0) {
            uint256 maxSkew = Math.mulDiv(ctx.snap.poolAssetsUsdc, ctx.snap.riskParams.maxSkewRatio, 1e18);
            uint256 maxSelectedLots = ctx.opposingLots + maxSkew / ctx.price;
            if (maxSelectedLots <= ctx.selectedLots) {
                return 0;
            }
            high = Math.min(high, maxSelectedLots - ctx.selectedLots);
        }
    }

    /// @dev Conservative interval arithmetic, NOT a monotonicity assumption about planOpen.valid:
    ///      - the VPI extrema come from the min/max absolute skew, including zero when the interval crosses balance;
    ///      - fees, liquidation reserves, margin requirements and added liability are minimized at low;
    ///      - minimum action cost and maximum reserve release overestimate affordable pledge and free cash;
    ///      - maximum VPI overestimates pool assets. Combining incompatible optimistic extrema is safe: it can only
    ///        retain extra intervals, never discard a valid size. At a singleton these bounds become exact.
    function _mayContainValid(
        Context memory ctx,
        uint256 low,
        uint256 high
    ) private pure returns (bool) {
        (int256 minVpi, int256 maxVpi) = _vpiBounds(ctx, low, high);
        uint256 feeFloor = Math.mulDiv(low * ctx.price, ctx.snap.executionFeeBps, 10_000);
        int256 minCost = minVpi + SafeCast.toInt256(feeFloor);
        uint256 minVpiReserve = _negativeReserve(ctx.snap.position.vpiAccrued + maxVpi);
        uint256 maxRelease =
            ctx.snap.vpiRebateReserveUsdc > minVpiReserve ? ctx.snap.vpiRebateReserveUsdc - minVpiReserve : 0;

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = ctx.snap.accountBuckets;
        // Copy this nested struct before changing it: memory assignment alone aliases the search context.
        buckets = abi.decode(abi.encode(buckets), (IMarginClearinghouse.AccountUsdcBuckets));
        buckets.otherLockedMarginUsdc -= maxRelease;
        buckets.totalLockedMarginUsdc -= maxRelease;
        buckets.freeSettlementUsdc = buckets.settlementBalanceUsdc > buckets.totalLockedMarginUsdc
            ? buckets.settlementBalanceUsdc - buckets.totalLockedMarginUsdc
            : 0;
        MarginClearinghouseAccountingLib.OpenCostPlan memory cost =
            MarginClearinghouseAccountingLib.planOpenCostApplication(buckets, ctx.marginDelta, minCost);
        if (cost.insufficientFreeEquity || cost.insufficientPositionMargin) {
            return false;
        }

        uint256 minVpiIncrease =
            minVpiReserve > ctx.snap.vpiRebateReserveUsdc ? minVpiReserve - ctx.snap.vpiRebateReserveUsdc : 0;
        uint256 minVpiFromPledge =
            minVpiIncrease > cost.resultingFreeSettlementUsdc ? minVpiIncrease - cost.resultingFreeSettlementUsdc : 0;
        uint256 totalNotionalFloor = (ctx.currentLots + low) * ctx.price;
        uint256 minLiquidationReserve = Math.max(
            Math.mulDiv(totalNotionalFloor, ctx.snap.riskParams.bountyBps, 10_000), ctx.snap.riskParams.minBountyUsdc
        );
        uint256 minReserveIncrease = minLiquidationReserve > ctx.snap.liquidationReserveUsdc
            ? minLiquidationReserve - ctx.snap.liquidationReserveUsdc
            : 0;
        uint256 maxNewPledge = cost.resultingPositionMarginUsdc - ctx.snap.position.margin;
        if (minVpiFromPledge > maxNewPledge || minReserveIncrease > maxNewPledge - minVpiFromPledge) {
            return false;
        }
        uint256 maxMargin = cost.resultingPositionMarginUsdc - minVpiFromPledge - minReserveIncrease;
        int256 maxEquity = SafeCast.toInt256(maxMargin + ctx.snap.traderClaimBalanceForAccount) + ctx.pricePnl;
        uint256 minInitial = Math.max(
            Math.mulDiv(totalNotionalFloor, ctx.snap.riskParams.initMarginBps, 10_000),
            ctx.snap.riskParams.minBountyUsdc
        );
        uint256 activeMarginBps =
            ctx.snap.isFadWindow ? ctx.snap.riskParams.fadMarginBps : ctx.snap.riskParams.maintMarginBps;
        uint256 minMaintenance = Math.mulDiv(totalNotionalFloor, activeMarginBps, 10_000);
        if (maxEquity < SafeCast.toInt256(minInitial) || maxEquity <= SafeCast.toInt256(minMaintenance)) {
            return false;
        }

        uint256 maxCash = ctx.snap.poolCashUsdc;
        if (maxVpi >= 0) {
            maxCash += uint256(maxVpi);
        } else {
            uint256 debit = uint256(-maxVpi);
            maxCash = maxCash > debit ? maxCash - debit : 0;
        }
        uint256 maxEffective =
            maxCash > ctx.snap.totalTraderClaimBalanceUsdc ? maxCash - ctx.snap.totalTraderClaimBalanceUsdc : 0;
        uint256 minLiability = Math.max(ctx.selectedLiability + low * ctx.profitPerLot, ctx.opposingLiability);
        return
            SolvencyAccountingLib.hasRequiredSettlementBuffer(maxEffective, minLiability, ctx.snap.settlementBufferBps);
    }

    function _vpiBounds(
        Context memory ctx,
        uint256 low,
        uint256 high
    ) private pure returns (int256 minVpi, int256 maxVpi) {
        uint256 lowSkew = _skew(ctx, low);
        uint256 highSkew = _skew(ctx, high);
        uint256 minSkew = Math.min(lowSkew, highSkew);
        if (ctx.selectedLots + low <= ctx.opposingLots && ctx.selectedLots + high >= ctx.opposingLots) {
            minSkew = 0;
        }
        minVpi = SafeCast.toInt256(_skewCost(ctx, minSkew)) - ctx.preSkewCost;
        maxVpi = SafeCast.toInt256(_skewCost(ctx, Math.max(lowSkew, highSkew))) - ctx.preSkewCost;
    }

    function _skew(
        Context memory ctx,
        uint256 lots
    ) private pure returns (uint256) {
        uint256 selected = ctx.selectedLots + lots;
        return (selected > ctx.opposingLots ? selected - ctx.opposingLots : ctx.opposingLots - selected) * ctx.price;
    }

    function _skewCost(
        Context memory ctx,
        uint256 skew
    ) private pure returns (uint256) {
        return CfdMath.getSkewCost(skew, ctx.snap.poolAssetsUsdc, ctx.snap.riskParams.vpiFactor);
    }

    function _negativeReserve(
        int256 vpi
    ) private pure returns (uint256) {
        return vpi < 0 ? uint256(-(vpi + 1)) + 1 : 0;
    }

}
