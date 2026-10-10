// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#close-settlement

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

contract LiquidityDepthRoundTripTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.01e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#close-settlement.
    function test_DepthManipulationShouldNotBeProfitable() public {
        _fundJunior(bob, 1_000_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 200_000e18, 40_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, _mockPythUpdateData(1e8));

        usdc.mint(address(pool), 9_000_000e6);
        pool.accountExcess();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        bytes[] memory closePrice = _mockPythUpdateData(1e8);
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balanceUsdc(aliceAccount);

        assertLe(aliceBalAfter, aliceBalBefore, "Depth manipulation round-trip must not produce positive PnL");
    }

}

contract MarketMakerVpiRoundTripTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#close-settlement.
    function test_VpiClampPreventsNetRebateExtraction() public {
        address skewTrader = address(0x901);
        address marketMaker = address(0x902);
        address flipper = address(0x903);

        _fundJunior(address(this), 2_000_000 * 1e6);

        _fundTrader(skewTrader, 500_000 * 1e6);
        _fundTrader(marketMaker, 500_000 * 1e6);
        _fundTrader(flipper, 500_000 * 1e6);

        address skewAccount = skewTrader;
        address mmAccount = marketMaker;
        address flipAccount = flipper;

        _open(skewAccount, CfdTypes.Side.SHORT, 500_000 * 1e18, 50_000 * 1e6, 1e8);
        _open(mmAccount, CfdTypes.Side.LONG, 500_000 * 1e18, 50_000 * 1e6, 1e8);
        _open(flipAccount, CfdTypes.Side.LONG, 1_000_000 * 1e18, 100_000 * 1e6, 1e8);

        _close(mmAccount, CfdTypes.Side.LONG, 500_000 * 1e18, 1e8);

        uint256 mmAfter = clearinghouse.balanceUsdc(mmAccount);
        uint256 depositAmount = 500_000 * 1e6;
        uint256 execFeesRoundTrip = ((500_000 * 1e6 * 4) / 10_000) * 2;

        assertEq(mmAfter, depositAmount - execFeesRoundTrip, "VPI clamp should prevent net rebate extraction");
    }

}
