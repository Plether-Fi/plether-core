// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

contract MarginCappedMtmTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_MarginTracking_IncreasesOnOpen() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        assertEq(_sideTotalMargin(CfdTypes.Side.LONG), 0);
        assertEq(_sideTotalMargin(CfdTypes.Side.SHORT), 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        assertEq(_sideTotalMargin(CfdTypes.Side.LONG), 0, "Long margin unchanged");
        assertGt(_sideTotalMargin(CfdTypes.Side.SHORT), 0, "Short margin tracked after open");
    }

    function test_MarginTracking_DecreasesOnClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        uint256 shortMarginAfterOpen = _sideTotalMargin(CfdTypes.Side.SHORT);
        assertGt(shortMarginAfterOpen, 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 100_000e18, 0, 1e8, true);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        assertEq(_sideTotalMargin(CfdTypes.Side.SHORT), 0, "Short margin zero after full close");
    }

    function test_MarginTracking_PartialClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        uint256 shortMarginFull = _sideTotalMargin(CfdTypes.Side.SHORT);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 50_000e18, 0, 1e8, true);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        uint256 shortMarginHalf = _sideTotalMargin(CfdTypes.Side.SHORT);
        assertLt(shortMarginHalf, shortMarginFull, "Margin decreases on partial close");
        assertGt(shortMarginHalf, 0, "Margin still tracked for remaining position");
    }

    function test_MarginTracking_ZeroAfterLiquidation() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 100_000e18, 2000e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        assertGt(_sideTotalMargin(CfdTypes.Side.SHORT), 0);

        bytes[] memory liqPrice = new bytes[](1);
        liqPrice[0] = abi.encode(uint256(0.5e8));
        address account = alice;
        router.executeLiquidation(account, liqPrice);

        assertEq(_sideTotalMargin(CfdTypes.Side.SHORT), 0, "Short margin zero after liquidation");
    }

    function test_PhantomProfitCappedAtMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 0.5e8, false);
        bytes[] memory priceData = _mockPythUpdateData(0.5e8);
        router.executeOrder(2, priceData);

        int256 uncappedPnl = _unrealizedTraderPnl();
        uint256 cappedMtm = _poolMtmAdjustment();

        assertLt(uncappedPnl, -int256(_sideTotalMargin(CfdTypes.Side.SHORT)), "Uncapped loss exceeds deposited margin");
        assertGt(int256(cappedMtm), uncappedPnl, "Capped MtM is less aggressive than uncapped");
    }

    function test_ReconcileDoesNotInflateBeyondMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 0.5e8, false);
        bytes[] memory priceData = _mockPythUpdateData(0.5e8);
        router.executeOrder(2, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 juniorAfter = pool.juniorPrincipal();

        uint256 revenue = juniorAfter > juniorBefore ? juniorAfter - juniorBefore : 0;
        assertLe(
            revenue,
            _sideTotalMargin(CfdTypes.Side.SHORT) + _sideTotalMargin(CfdTypes.Side.LONG),
            "Recognized revenue must not exceed seizable margin"
        );
    }

    function test_MtmAdjustment_PositiveWhenTradersWinning() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1.2e8, false);
        bytes[] memory priceData = _mockPythUpdateData(1.2e8);
        router.executeOrder(2, priceData);

        uint256 mtm = _poolMtmAdjustment();
        assertGt(mtm, 0, "Positive MtM = pool liability when traders are winning (no cap needed)");
    }

    function test_MtmAdjustment_ZeroWithNoPositions() public {
        _fundJunior(bob, 500_000e6);
        assertEq(_poolMtmAdjustment(), 0, "MtM should be zero with no positions");
    }

}
