// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Financial observations are sealed against the implementation before the accounting cleanup.
/// @dev Expected inflow classifications use the previous equations independently of the settlement implementation.
contract VpiCleanupCashEquivalenceTest is BasePerpTest {

    using stdStorage for StdStorage;

    address private constant ACCOUNT = address(0xA11CE);
    address private constant OTHER = address(0xB0B);
    address private constant KEEPER_ACCOUNT = address(0xCAFE);
    uint256 private constant PRICE = 1e8;
    bytes32 private constant INFLOW = keccak256("ClaimantInflowAccounted(address,uint8,uint8,uint256)");

    // Captured before production cleanup: complete close deltas, cash/claim vectors and inflow classifications.
    bytes32 private constant BASELINE_POSITIVE_PARTIAL_FULL =
        0x7c079058f106ab37847f3dc8baf2ff35f5ca08830ced4ad0694993f33c4a2e85;
    bytes32 private constant BASELINE_NEGATIVE_NO_GAIN =
        0x1b6101d3218dabf031ae79dfad33826c8bba5c349c0b9e7ebfb1b834650ad4af;
    bytes32 private constant BASELINE_NEGATIVE_PARTIAL_GAIN =
        0xf2944e698c03313f4648325270a8283f0a142c6983ffa9822888611d716c6edc;
    bytes32 private constant BASELINE_NEGATIVE_FULL_GAIN =
        0x2161b78fd74afe0f395092f61390fa8440cd0c2b1d337bf28fbc4860ea8154d2;
    bytes32 private constant BASELINE_ZERO_PRINCIPAL =
        0x3262a2bd57996b791b3acf3e0eeb0167e6a9b168fa12f8db76606579bea13444;
    bytes32 private constant BASELINE_PRICE_CLAIM = 0xf247ff1952e63e7987122baf90eb13a3049156d44d3a54dc917e777319c90594;

    struct CashVector {
        uint256 poolCash;
        uint256 traderSettlement;
        uint256 traderWallet;
        uint256 treasurySettlement;
        uint256 keeperSettlement;
        uint256 traderClaim;
        uint256 totalClaims;
        uint256 vpiReserve;
        uint256 positiveVpi;
        uint256 negativeVpi;
        uint256 size;
        uint256 positionMargin;
        uint256 liquidationReserve;
        uint256 actionReserve;
        uint256 pendingRevenue;
        uint256 pendingRecapitalization;
        uint256 unassignedAssets;
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        int256 accruedVpi;
        int256 terminalPriceDelta;
    }

    struct InflowVector {
        uint256 balanceOnlyCash;
        uint256 revenueCash;
        uint256 retainedRevenue;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 0;
        params.vpiFactor = 0.01e18;
    }

    function test_CashBaseline_PositivePartialAndFullClose() public {
        _preparePositive();
        bytes32 first = _checkClose(CfdTypes.Side.LONG, 50_000e18, PRICE);
        bytes32 second = _checkClose(CfdTypes.Side.LONG, 150_000e18, PRICE);
        _seal("BASELINE_POSITIVE_PARTIAL_FULL", keccak256(abi.encode(first, second)), BASELINE_POSITIVE_PARTIAL_FULL);
    }

    function test_CashBaseline_NegativeOverfundedWithoutGain() public {
        _prepareNegative();
        _seal(
            "BASELINE_NEGATIVE_NO_GAIN", _checkClose(CfdTypes.Side.SHORT, 100_000e18, PRICE), BASELINE_NEGATIVE_NO_GAIN
        );
    }

    function test_CashBaseline_NegativeOverfundedPartiallyWithheld() public {
        _prepareNegative();
        _seal(
            "BASELINE_NEGATIVE_PARTIAL_GAIN",
            _checkClose(CfdTypes.Side.SHORT, 100_000e18, 100_050_000),
            BASELINE_NEGATIVE_PARTIAL_GAIN
        );
    }

    function test_CashBaseline_NegativeOverfundedFullyWithheld() public {
        _prepareNegative();
        _seal(
            "BASELINE_NEGATIVE_FULL_GAIN",
            _checkClose(CfdTypes.Side.SHORT, 100_000e18, 100_500_000),
            BASELINE_NEGATIVE_FULL_GAIN
        );
    }

    function test_CashBaseline_ZeroPrincipalDoesNotQueueClawbackOrFundWithheldFee() public {
        _prepareNegative();
        // Isolate the live zero-stored-principal policy without changing trader custody, VPI or token backing.
        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(uint256(0));
        stdstore.target(address(pool)).sig("juniorPrincipal()").checked_write(uint256(0));
        assertGt(pool.getFreeAssets(), 0, "fixture retains physical cash above the ordinary reservations");
        assertEq(pool.getSettlementFreeAssets(), 0, "zero principal blocks pool-funded fee eligibility");
        uint256 snapshotId = vm.snapshotState();
        bytes32 collected = _checkClose(CfdTypes.Side.SHORT, 100_000e18, PRICE);
        assertTrue(vm.revertToState(snapshotId));
        CfdEnginePlanTypes.CloseDelta memory delta = _closePlan(CfdTypes.Side.SHORT, 100_000e18, 100_500_000);
        assertGt(delta.executionFeeAssets, 0);
        assertEq(delta.actionProtocolFeeCreditedAssets, 0, "the full fee is withheld from gain");
        assertEq(delta.protocolFeeTopUpAssets, 0, "no fee debt or top-up is created at zero principal");
        bytes32 withheld = _checkClose(CfdTypes.Side.SHORT, 100_000e18, 100_500_000);
        _seal("BASELINE_ZERO_PRINCIPAL", keccak256(abi.encode(collected, withheld)), BASELINE_ZERO_PRINCIPAL);
    }

    function test_CashBaseline_IlliquidPricePayoutCreatesClaim() public {
        _preparePositive();
        uint256 drainAssets = pool.totalAssets() - 1e6;
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), drainAssets);
        CfdEnginePlanTypes.CloseDelta memory delta = _closePlan(CfdTypes.Side.LONG, 200_000e18, 80_000_000);
        assertTrue(delta.valid);
        assertGt(delta.pricePayoutAssets, 0);
        assertFalse(delta.pricePayoutIsImmediate);
        assertTrue(delta.pricePayoutCreatesClaim, "cash and a deferred claim must not be interchanged");
        _seal("BASELINE_PRICE_CLAIM", _checkClose(CfdTypes.Side.LONG, 200_000e18, 80_000_000), BASELINE_PRICE_CLAIM);
    }

    function _preparePositive() private {
        _fundTrader(ACCOUNT, 100_000e6);
        _open(ACCOUNT, CfdTypes.Side.LONG, 200_000e18, 20_000e6, PRICE);
        (,,,,,, int256 accrual) = engine.positions(ACCOUNT);
        assertGt(accrual, 0);
    }

    function _prepareNegative() private {
        _fundTrader(OTHER, 100_000e6);
        _fundTrader(ACCOUNT, 100_000e6);
        _open(OTHER, CfdTypes.Side.LONG, 200_000e18, 20_000e6, PRICE);
        _open(ACCOUNT, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, PRICE);
        (,,,,,, int256 accrual) = engine.positions(ACCOUNT);
        assertLt(accrual, 0);
        vm.prank(address(engine));
        clearinghouse.lockVpiRebateReserve(ACCOUNT, 7e6);
        assertEq(clearinghouse.vpiRebateReserveAssets(ACCOUNT), uint256(-accrual) + 7e6);
    }

    function _closePlan(
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) private returns (CfdEnginePlanTypes.CloseDelta memory) {
        uint256 depth = pool.totalAssets();
        ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
        vm.prank(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap = sidecar.buildRawSnapshot(ACCOUNT, depth);
        CfdTypes.Order memory order;
        order.account = ACCOUNT;
        order.isClose = true;
        order.side = side;
        order.sizeDelta = size;
        return engine.planner().planClose(snap, order, price);
    }

    function _checkClose(
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) private returns (bytes32) {
        CashVector memory beforeState = _cashVector();
        CfdEnginePlanTypes.CloseDelta memory delta = _closePlan(side, size, price);
        assertTrue(delta.valid);
        assertEq(delta.pendingCarryAssets, 0, "cash classification fixture excludes unrelated carry");
        assertEq(delta.realizedCarryAssets, 0);
        InflowVector memory expected = _oldInflows(beforeState.accruedVpi, delta);
        vm.recordLogs();
        _close(ACCOUNT, side, size, price);
        InflowVector memory observed = _inflows(vm.getRecordedLogs());
        assertEq(abi.encode(observed), abi.encode(expected), "cash and retained revenue preserve prior classification");
        CashVector memory afterState = _cashVector();
        _assertCashVector(beforeState, afterState, delta, expected);
        return keccak256(abi.encode(delta, beforeState, afterState, observed));
    }

    function _assertCashVector(
        CashVector memory beforeState,
        CashVector memory afterState,
        CfdEnginePlanTypes.CloseDelta memory delta,
        InflowVector memory inflows
    ) private pure {
        uint256 pricePaid = delta.pricePayoutIsImmediate ? delta.pricePayoutAssets : 0;
        uint256 traderPaid = pricePaid + delta.actionRebatePaidAssets;
        uint256 cashCollected = delta.pricePnlPledgeConsumedAssets + delta.actionChargeCollectedAssets;
        assertEq(afterState.traderSettlement, beforeState.traderSettlement + traderPaid - cashCollected);
        assertEq(
            afterState.poolCash,
            beforeState.poolCash + cashCollected - delta.actionProtocolFeeCreditedAssets - traderPaid
                - delta.protocolFeeTopUpAssets
        );
        assertEq(
            afterState.treasurySettlement,
            beforeState.treasurySettlement + delta.actionProtocolFeeCreditedAssets + delta.protocolFeeTopUpAssets
        );
        uint256 createdClaim = delta.pricePayoutCreatesClaim ? delta.pricePayoutAssets : 0;
        assertEq(afterState.traderClaim, beforeState.traderClaim - delta.pricePnlClaimConsumedAssets + createdClaim);
        assertEq(afterState.totalClaims, beforeState.totalClaims - delta.pricePnlClaimConsumedAssets + createdClaim);
        assertEq(afterState.traderWallet, beforeState.traderWallet);
        assertEq(afterState.keeperSettlement, beforeState.keeperSettlement);
        assertEq(afterState.size, beforeState.size - delta.sizeDelta);
        assertEq(afterState.positionMargin, delta.posMarginAfter);
        assertEq(afterState.vpiReserve, delta.vpiRebateReserveAfterAssets);
        assertEq(afterState.accruedVpi, beforeState.accruedVpi - delta.posVpiAccruedReduction);
        assertEq(
            afterState.positiveVpi,
            beforeState.positiveVpi - _positive(beforeState.accruedVpi) + _positive(afterState.accruedVpi)
        );
        assertEq(
            afterState.negativeVpi,
            beforeState.negativeVpi - _negative(beforeState.accruedVpi) + _negative(afterState.accruedVpi)
        );
        uint256 queuedRevenue = beforeState.seniorPrincipal + beforeState.juniorPrincipal == 0
            ? inflows.revenueCash + inflows.retainedRevenue
            : 0;
        assertEq(afterState.pendingRevenue, beforeState.pendingRevenue + queuedRevenue);
        assertEq(afterState.pendingRecapitalization, beforeState.pendingRecapitalization);
        assertEq(afterState.unassignedAssets, beforeState.unassignedAssets);
    }

    /// @dev Freeze the previous two-target close clawback and actual-credit revenue equations.
    function _oldInflows(
        int256 priorAccrued,
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (InflowVector memory expected) {
        uint256 oldClawback = _negative(priorAccrued) - _negative(priorAccrued - delta.posVpiAccruedReduction);
        uint256 clawbackWithheld = oldClawback - delta.vpiRebateReserveConsumedAssets;
        uint256 withheldFee = delta.executionFeeAssets - delta.actionProtocolFeeCreditedAssets;
        expected.balanceOnlyCash = delta.vpiRebateReserveConsumedAssets;
        expected.revenueCash = delta.pricePnlPledgeConsumedAssets + delta.actionChargeCollectedAssets
            - delta.actionProtocolFeeCreditedAssets - expected.balanceOnlyCash;
        expected.retainedRevenue = delta.actionChargeWithheldAssets - withheldFee - clawbackWithheld;
    }

    function _cashVector() private view returns (CashVector memory state) {
        state.poolCash = pool.totalAssets();
        state.traderSettlement = clearinghouse.balanceAssets(ACCOUNT);
        state.traderWallet = settlementToken.balanceOf(ACCOUNT);
        state.treasurySettlement = clearinghouse.balanceAssets(engine.protocolTreasury());
        state.keeperSettlement = clearinghouse.balanceAssets(KEEPER_ACCOUNT);
        state.traderClaim = engine.traderClaimBalanceAssets(ACCOUNT);
        state.totalClaims = engine.totalTraderClaimBalanceAssets();
        state.vpiReserve = clearinghouse.vpiRebateReserveAssets(ACCOUNT);
        state.positiveVpi = engine.totalPositiveVpiAccruedAssets();
        state.negativeVpi = engine.totalNegativeVpiAccruedAssets();
        (state.size, state.positionMargin,,,,, state.accruedVpi) = engine.positions(ACCOUNT);
        state.liquidationReserve = clearinghouse.liquidationReserveAssets(ACCOUNT);
        state.actionReserve = clearinghouse.actionReserveAssets(ACCOUNT);
        state.pendingRevenue = pool.pendingTradingRevenueAssets();
        state.pendingRecapitalization = pool.pendingRecapitalizationAssets();
        state.unassignedAssets = pool.unassignedAssets();
        state.seniorPrincipal = pool.seniorPrincipal();
        state.juniorPrincipal = pool.juniorPrincipal();
        state.terminalPriceDelta = engine.terminalNavSnapshot().terminalLpPriceDeltaAssets;
    }

    function _inflows(
        Vm.Log[] memory logs
    ) private view returns (InflowVector memory observed) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool) || logs[i].topics.length != 2 || logs[i].topics[0] != INFLOW) {
                continue;
            }
            (IHousePool.ClaimantInflowKind kind, IHousePool.ClaimantInflowCashMode mode, uint256 amount) =
                abi.decode(logs[i].data, (IHousePool.ClaimantInflowKind, IHousePool.ClaimantInflowCashMode, uint256));
            if (kind == IHousePool.ClaimantInflowKind.BalanceOnly) {
                assertEq(uint8(mode), uint8(IHousePool.ClaimantInflowCashMode.CashArrived));
                observed.balanceOnlyCash += amount;
            } else if (kind == IHousePool.ClaimantInflowKind.Revenue) {
                if (mode == IHousePool.ClaimantInflowCashMode.CashArrived) {
                    observed.revenueCash += amount;
                } else {
                    observed.retainedRevenue += amount;
                }
            } else {
                assertTrue(false, "close must not introduce recapitalization");
            }
        }
    }

    function _positive(
        int256 value
    ) private pure returns (uint256) {
        return value > 0 ? uint256(value) : 0;
    }

    function _negative(
        int256 value
    ) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : 0;
    }

    function _seal(
        string memory label,
        bytes32 observed,
        bytes32 baseline
    ) private {
        emit log_named_bytes32(label, observed);
        assertEq(observed, baseline, "cash and claim outcomes must match the pre-cleanup baseline");
    }

}
