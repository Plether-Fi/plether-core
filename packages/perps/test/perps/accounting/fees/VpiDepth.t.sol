// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {VpiRebateExtractionSnapshot} from "../../shared/CfdEngineTestBase.sol";

contract VpiDepthTest is BasePerpTest {

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
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _settleAvailableJuniorWithdrawal(
        address owner
    ) internal returns (uint256 claimedAssets) {
        uint256 maxShares = juniorVault.maxRequestRedeem(owner);
        if (maxShares == 0) {
            return 0;
        }

        uint256 ownerAssets = juniorVault.estimateRedeemAssets(maxShares);
        (,,, uint256 maxJuniorWithdrawUsdc) = pool.getPendingTrancheState();
        uint256 targetAssets = ownerAssets < maxJuniorWithdrawUsdc ? ownerAssets : maxJuniorWithdrawUsdc;
        if (targetAssets == 0) {
            return 0;
        }

        uint256 requestedShares = juniorVault.estimateWithdrawShares(targetAssets);
        if (requestedShares > maxShares) {
            requestedShares = maxShares;
        }
        vm.prank(owner);
        uint256 requestId = juniorVault.requestRedeem(requestedShares, owner, owner);

        vm.warp(pool.lpEpochStart(requestId));
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
        _settleLpEpochForTest();

        uint256 claimableShares = juniorVault.claimableRedeemRequest(requestId, owner);
        if (claimableShares == 0) {
            return 0;
        }
        vm.prank(owner);
        claimedAssets = juniorVault.claimRedeem(requestId, claimableShares, owner, owner);
    }

    function test_MinorityVpiRebateCannotExceedPaidCharges() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 200_000 * 1e18, 40_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundTrader(alice, 50_000 * 1e6);
        address aliceAccount = alice;
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        _fundJuniorDelayed(bob, 9_000_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balanceUsdc(aliceAccount);

        assertLe(aliceBalAfter, aliceBalBefore, "Minority VPI depth attack must not be profitable");
    }

    function test_SizeAdditionCannotBypassVpiBound() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        address aliceAccount = alice;
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundJuniorDelayed(bob, 9_000_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 2 hours);
        bytes[] memory freshPrice = new bytes[](1);
        freshPrice[0] = abi.encode(uint256(1e8));
        router.updateMarkPrice(freshPrice);
        _settleAvailableJuniorWithdrawal(bob);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 110_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balanceUsdc(aliceAccount);

        assertLe(aliceBalAfter, aliceBalBefore, "Size addition VPI bypass must not be profitable");
    }

    function _openNegativeVpiIsolationFixture(
        address skewTrader,
        address rebateTrader,
        address deepLp
    ) internal returns (address rebateAccount, uint256 reserveTargetUsdc) {
        _fundJunior(deepLp, 10_000_000e6);
        _fundTrader(skewTrader, 100_000e6);
        _fundTrader(rebateTrader, 20_000e6);

        uint256 depth = pool.totalAssets();
        _open(skewTrader, CfdTypes.Side.SHORT, 500_000e18, 50_000e6, 1e8, depth);
        rebateAccount = rebateTrader;
        _open(rebateAccount, CfdTypes.Side.LONG, 500_000e18, 10_000e6, 1e8, depth);

        (,,,,,, int256 storedVpi) = engine.positions(rebateAccount);
        assertLt(storedVpi, 0, "Fixture must create a negative lifetime VPI obligation");
        reserveTargetUsdc = uint256(-(storedVpi + 1)) + 1;
        assertEq(
            clearinghouse.vpiRebateReserveUsdc(rebateAccount),
            reserveTargetUsdc,
            "Fixture must exactly fund the mandatory VPI reserve"
        );
    }

    function test_VpiReserveOverfund_DoesNotImproveExactPriceHealth() public {
        (address account, uint256 reserveTargetUsdc) =
            _openNegativeVpiIsolationFixture(address(0x7111), address(0x7112), address(0x7113));
        AccountLensViewTypes.AccountLedgerSnapshot memory beforeSnapshot =
            engineAccountLens.getAccountLedgerSnapshot(account);
        bytes32 curveHashBefore = terminalNavBook.curveHashOf(account);

        vm.prank(address(engine));
        clearinghouse.lockVpiRebateReserve(account, 1e6);

        AccountLensViewTypes.AccountLedgerSnapshot memory afterSnapshot =
            engineAccountLens.getAccountLedgerSnapshot(account);
        assertEq(
            clearinghouse.vpiRebateReserveUsdc(account),
            reserveTargetUsdc + 1e6,
            "Fixture must overfund the independent VPI reserve"
        );
        assertEq(
            afterSnapshot.netEquityUsdc,
            beforeSnapshot.netEquityUsdc,
            "VPI reserve overfund must never count as exact price collateral"
        );
        assertEq(
            afterSnapshot.liquidatable,
            beforeSnapshot.liquidatable,
            "VPI reserve overfund must never improve the exact price-health decision"
        );
        assertEq(
            terminalNavBook.curveHashOf(account),
            curveHashBefore,
            "Action-reserve overfund must not mutate the terminal price-PnL curve"
        );
        _assertTerminalCurveMatchesEngine(account);
    }

    function test_VpiReserveUnderfund_FailsClosedAsIndependentDelinquency() public {
        (address account, uint256 reserveTargetUsdc) =
            _openNegativeVpiIsolationFixture(address(0x7121), address(0x7122), address(0x7123));
        AccountLensViewTypes.AccountLedgerSnapshot memory fundedSnapshot =
            engineAccountLens.getAccountLedgerSnapshot(account);
        assertFalse(fundedSnapshot.liquidatable, "Exactly funded healthy fixture must not start delinquent");

        vm.prank(address(engine));
        clearinghouse.releaseVpiRebateReserve(account, 1);

        AccountLensViewTypes.AccountLedgerSnapshot memory underfundedSnapshot =
            engineAccountLens.getAccountLedgerSnapshot(account);
        assertEq(
            clearinghouse.vpiRebateReserveUsdc(account),
            reserveTargetUsdc - 1,
            "Fixture must leave exactly one VPI-reserve atom uncovered"
        );
        assertEq(
            underfundedSnapshot.netEquityUsdc,
            fundedSnapshot.netEquityUsdc,
            "Independent VPI delinquency must not distort exact price equity"
        );
        assertTrue(underfundedSnapshot.liquidatable, "One uncovered VPI-reserve atom must fail closed");
        assertEq(engineAccountLens.getWithdrawableUsdc(account), 0, "Underfunded VPI reserve must block withdrawal");

        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);
        _assertTerminalCurveMatchesEngine(account);
    }

    function test_VpiRebateReserve_BlocksRebateExtractionAcrossWithdrawAndFullClose() public {
        address rebateTrader = address(0x666);
        VpiRebateExtractionSnapshot memory beforeOpen = _openVpiRebateExtractionFixture(rebateTrader);

        uint256 freeSettlementUsdc = clearinghouse.getAccountUsdcBuckets(rebateTrader).freeSettlementUsdc;
        assertEq(
            engineAccountLens.getWithdrawableUsdc(rebateTrader),
            freeSettlementUsdc,
            "Dedicated backing should leave genuinely free settlement withdrawable"
        );
        vm.prank(rebateTrader);
        clearinghouse.withdraw(rebateTrader, freeSettlementUsdc);

        assertEq(
            clearinghouse.vpiRebateReserveUsdc(rebateTrader),
            beforeOpen.rebateReserveUsdc,
            "Withdrawing free cash must not touch rebate backing"
        );

        _close(rebateTrader, CfdTypes.Side.LONG, 500_000 * 1e18, 1e8, pool.totalAssets());

        (uint256 sizeAfter,,,,,,) = engine.positions(rebateTrader);
        assertEq(sizeAfter, 0, "The terminal close should complete");
        assertEq(clearinghouse.vpiRebateReserveUsdc(rebateTrader), 0, "Terminal clawback must consume the reserve");
        assertGe(pool.totalAssets(), beforeOpen.poolAssetsBeforeOpen, "The round trip must not extract LP cash");
        assertLe(
            usdc.balanceOf(rebateTrader) + clearinghouse.balanceUsdc(rebateTrader),
            beforeOpen.walletBeforeOpen + beforeOpen.settlementBeforeOpen,
            "Withdrawal plus terminal close must not turn the rebate into trader profit"
        );
    }

    function _openVpiRebateExtractionFixture(
        address rebateTrader
    ) internal returns (VpiRebateExtractionSnapshot memory beforeOpen) {
        uint256 smallDepth;
        {
            address deepLp = address(0x444);
            address skewTrader = address(0x555);
            _fundJunior(bob, 1_000_000 * 1e6);
            _fundJunior(deepLp, 10_000_000 * 1e6);
            _fundTrader(skewTrader, 100_000 * 1e6);
            _fundTrader(rebateTrader, 20_000 * 1e6);

            uint256 largeDepth = pool.totalAssets();
            _open(skewTrader, CfdTypes.Side.SHORT, 500_000 * 1e18, 50_000 * 1e6, 1e8, largeDepth);

            vm.warp(block.timestamp + 2 hours);
            bytes[] memory freshPrice = new bytes[](1);
            freshPrice[0] = abi.encode(uint256(1e8));
            router.updateMarkPrice(freshPrice);
            _settleAvailableJuniorWithdrawal(deepLp);

            smallDepth = pool.totalAssets();
            assertLt(smallDepth, largeDepth, "LP withdrawal should shrink live pool depth");
        }
        beforeOpen.settlementBeforeOpen = clearinghouse.balanceUsdc(rebateTrader);
        beforeOpen.walletBeforeOpen = usdc.balanceOf(rebateTrader);
        beforeOpen.poolAssetsBeforeOpen = smallDepth;

        uint64 rebatePublishTime = engine.lastMarkTime();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: rebateTrader,
                sizeDelta: 500_000 * 1e18,
                marginDelta: 10_000 * 1e6,
                targetPrice: 1e8,
                commitTime: rebatePublishTime,
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.LONG,
                isClose: false
            }),
            1e8,
            smallDepth,
            rebatePublishTime
        );

        (,,,,,, int256 storedVpi) = engine.positions(rebateTrader);
        assertLt(storedVpi, 0, "Setup must create negative accrued VPI on the rebate-bearing leg");
        beforeOpen.rebateReserveUsdc = clearinghouse.vpiRebateReserveUsdc(rebateTrader);
        assertEq(
            beforeOpen.rebateReserveUsdc,
            uint256(-storedVpi),
            "The gross lifetime rebate must be backed one-for-one inside action reserve"
        );
        assertGe(
            clearinghouse.actionReserveUsdc(rebateTrader),
            beforeOpen.rebateReserveUsdc,
            "The VPI sub-ledger must remain a floor inside action reserve"
        );
        assertGt(
            clearinghouse.balanceUsdc(rebateTrader),
            beforeOpen.settlementBeforeOpen,
            "Skew-healing open should credit net rebate into settlement balance"
        );
    }

}
