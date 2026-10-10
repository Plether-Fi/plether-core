// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @notice Admission is checked from installed pledge and exact entry cost, without using previewed equity.
contract OpenAdmissionPropertyTest is BasePerpTest {

    address private constant SEED = address(0xAD10);
    address private constant ACCOUNT = address(0xAD11);
    uint256 private constant MARK = 1e8;

    function _seedSkew() private {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.02e18;
        params.baseCarryBps = 0;
        _setRiskParams(params);
        _fundTrader(SEED, 50_000e6);
        _fundTrader(ACCOUNT, 20_000e6);
        _open(SEED, CfdTypes.Side.LONG, 100_000e18, 20_000e6, MARK);
    }

    function testFuzz_SuccessfulOpenOrIncreaseMeetsInstalledInitialMargin(
        bool existing,
        bool healing,
        bool zeroSuppliedMargin,
        uint256 sizeSeed,
        uint256 marginSeed
    ) public {
        _seedSkew();
        CfdTypes.Side side = healing ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        if (existing) {
            _open(ACCOUNT, side, 10_000e18, 2000e6, MARK);
        }
        uint256 size = bound(sizeSeed, 10, 400) * 100e18;
        uint256 margin = zeroSuppliedMargin ? 0 : bound(marginSeed, 1, 3000e6);
        _tryOpenAndCheck(side, size, margin);
    }

    function test_ZeroMarginHealingIncreaseIsReachableAndCollateralized() public {
        _seedSkew();
        _open(ACCOUNT, CfdTypes.Side.SHORT, 10_000e18, 2000e6, MARK);
        // Governance lowers the reserve ratio: the existing reserve now covers the increased notional.
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.02e18;
        params.baseCarryBps = 0;
        params.bountyBps = 5;
        _setRiskParams(params);
        assertTrue(_tryOpenAndCheck(CfdTypes.Side.SHORT, 10_000e18, 0), "Reach zero-supplied-margin increase");
        (,,,,,, int256 lifetimeVpi) = engine.positions(ACCOUNT);
        assertLt(lifetimeVpi, 0, "Scenario must earn and reserve a lifetime rebate");
    }

    function test_HealingRebateCannotSubstituteForInitialMargin_AtomBoundary() public {
        _seedSkew();
        // 40,000 USDC notional needs 600 USDC price-risk pledge and 40 USDC liquidation reserve.
        // A healing rebate is free settlement / VPI reserve, never additional pledge for admission.
        for (uint256 supplied = 640e6 - 1; supplied <= 640e6 + 1; supplied++) {
            uint256 snapshot = vm.snapshotState();
            bool success = _tryOpenAndCheck(CfdTypes.Side.SHORT, 40_000e18, supplied);
            assertEq(success, supplied >= 640e6, "Admission boundary must exclude the rebate from price-risk equity");
            if (success) {
                assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), supplied - 40e6);
                (,,,,,, int256 lifetimeVpi) = engine.positions(ACCOUNT);
                assertLt(lifetimeVpi, 0, "Boundary must execute a healing rebate");
            }
            assertTrue(vm.revertToState(snapshot));
            vm.deleteStateSnapshot(snapshot);
        }
    }

    function _tryOpenAndCheck(
        CfdTypes.Side side,
        uint256 size,
        uint256 margin
    ) private returns (bool success) {
        uint256 settlementBefore = clearinghouse.balanceUsdc(ACCOUNT);
        bytes32 curveBefore = terminalNavBook.curveHashOf(ACCOUNT);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        CfdTypes.Order memory order = CfdTypes.Order({
            account: ACCOUNT,
            sizeDelta: size,
            marginDelta: margin,
            targetPrice: MARK,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: side,
            isClose: false
        });
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        try engine.processOrderTyped(order, MARK, depth, uint64(block.timestamp)) {
            success = true;
            _assertInstalledAdmission(side);
        } catch (bytes memory reason) {
            assertEq(
                _revertSelector(reason),
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                "No unexpected execution revert"
            );
            assertEq(clearinghouse.balanceUsdc(ACCOUNT), settlementBefore, "Rejected admission rolls back custody");
            assertEq(terminalNavBook.curveHashOf(ACCOUNT), curveBefore, "Rejected admission preserves risk curve");
            assertEq(usdc.balanceOf(address(pool)), poolCashBefore);
        }
    }

    function _assertInstalledAdmission(
        CfdTypes.Side side
    ) private view {
        (uint256 size,,,,,, int256 lifetimeVpi) = engine.positions(ACCOUNT);
        uint256 markedNotional = size * MARK / 1e20;
        int256 pnl = int256(engine.positionEntryCostUsdcAtoms(ACCOUNT)) - int256(markedNotional);
        if (side == CfdTypes.Side.SHORT) {
            pnl = -pnl;
        }
        int256 priceEquity = int256(clearinghouse.pnlPledgeUsdc(ACCOUNT) + engine.traderClaimBalanceUsdc(ACCOUNT)) + pnl;
        uint256 initialRequirement = markedNotional * 150 / 10_000;
        if (initialRequirement < 1e6) {
            initialRequirement = 1e6;
        }
        assertGe(priceEquity, int256(initialRequirement), "Every successful admission installs enough P+C price equity");
        assertGe(
            clearinghouse.vpiRebateReserveUsdc(ACCOUNT),
            lifetimeVpi < 0 ? uint256(-lifetimeVpi) : 0,
            "Negative lifetime VPI is physically reserved separately"
        );
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 0, "New risk cannot leave carry arrears");
    }

}
