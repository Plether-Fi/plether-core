// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract PendingDepositLifecycleEntryTest is BasePerpTest {

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_OpenPositionAllowsDepositRequestButNotUnfinalizedClaim() public {
        address trader = address(0x7100);
        address attacker = address(0xA77A);
        uint256 attackerDepositUsdc = 100_000e6;

        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(150_000_000, uint64(block.timestamp));

        assertEq(juniorVault.maxDeposit(attacker), 0, "no finalized request should expose claim capacity");
        assertGt(
            juniorVault.maxRequestDeposit(attacker), 0, "live positions should remain compatible with delayed entry"
        );

        usdc.mint(attacker, attackerDepositUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), attackerDepositUsdc);
        vm.expectRevert(TrancheVault.TrancheVault__DepositEpochNotFinalized.selector);
        juniorVault.deposit(attackerDepositUsdc, attacker);
        vm.stopPrank();
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_PendingJuniorDepositFinalizesAtPostLiquidationNav() public {
        address trader = address(0x7101);
        address attacker = address(0xA77A2);
        address keeper = address(0xB0B0);
        uint256 attackerDepositUsdc = 100_000e6;

        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint256 immediateSharesBeforeLiquidation = juniorVault.estimateDepositShares(attackerDepositUsdc);

        usdc.mint(attacker, attackerDepositUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), attackerDepositUsdc);
        uint256 epochId = juniorVault.requestDeposit(attackerDepositUsdc, attacker);
        vm.stopPrank();

        assertEq(juniorVault.balanceOf(attacker), 0, "pending deposits must not mint active shares");
        assertEq(
            juniorVault.pendingDepositAssets(attacker, epochId),
            attackerDepositUsdc,
            "pending assets should be assigned to the activation epoch"
        );

        uint256 poolDepthUsdc = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(trader, 150_000_000, poolDepthUsdc, uint64(block.timestamp), keeper);

        vm.warp(juniorVault.depositEpochStart(epochId));
        vm.prank(address(router));
        engine.updateMarkPrice(150_000_000, uint64(block.timestamp));
        IHousePool.LpEpochSettlementResult memory settlement = _settleLpEpochForTest();
        uint256 finalizedShares = settlement.juniorDepositShares;

        assertLt(
            finalizedShares,
            immediateSharesBeforeLiquidation,
            "finalized shares should price in liquidation revenue realized during the pending period"
        );

        vm.prank(attacker);
        uint256 claimedShares = juniorVault.claimDepositShares(epochId);

        assertEq(claimedShares, finalizedShares, "single depositor should receive the finalized epoch shares");
        assertEq(juniorVault.balanceOf(attacker), claimedShares, "claimed shares should be self-custodied");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_HealthyPendingDepositCanCancelOnlyBeforeActivationEpoch() public {
        address attacker = address(0xCACE1);
        uint256 depositUsdc = 100_000e6;

        usdc.mint(attacker, depositUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), depositUsdc);
        uint256 epochId = juniorVault.requestDeposit(depositUsdc, attacker);
        juniorVault.cancelPendingDeposit(epochId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(attacker), depositUsdc, "pre-activation cancellation should refund assets");
        assertEq(juniorVault.pendingDepositAssets(attacker, epochId), 0, "cancelled request should clear pending state");

        usdc.mint(attacker, depositUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), depositUsdc);
        epochId = juniorVault.requestDeposit(depositUsdc, attacker);
        vm.warp(juniorVault.depositEpochStart(epochId));
        vm.expectRevert(TrancheVault.TrancheVault__DepositEpochAlreadyActive.selector);
        juniorVault.cancelPendingDeposit(epochId);
        vm.stopPrank();
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ActivePendingDepositCanCancelWhenSeniorImpairmentBlocksFinalization() public {
        address pendingLp = address(0xCAFE2);
        uint256 depositUsdc = 50_000e6;

        usdc.mint(pendingLp, depositUsdc);
        vm.startPrank(pendingLp);
        usdc.approve(address(juniorVault), depositUsdc);
        uint256 epochId = juniorVault.requestDeposit(depositUsdc, pendingLp);
        vm.stopPrank();

        uint256 activationTime = juniorVault.depositEpochStart(epochId);
        vm.warp(activationTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(activationTime));

        vm.prank(address(engine));
        pool.payOut(address(0xD15C0), 1_001_500e6);

        assertTrue(
            pool.isSeniorImpairedAfterPendingDepositReconcile(), "pending deposit finalization should be impaired"
        );
        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        pool.settleLpEpoch(0, 0);
        assertEq(juniorVault.claimableDepositRequest(epochId, pendingLp), 0, "deferred entry must not be claimable");

        vm.prank(pendingLp);
        uint256 refunded = juniorVault.cancelPendingDeposit(epochId);

        (uint256 epochAssets,,,, bool finalized) = juniorVault.depositEpochs(epochId);
        assertEq(refunded, depositUsdc, "active impaired cancellation should refund pending assets");
        assertEq(usdc.balanceOf(pendingLp), depositUsdc, "depositor should recover escrowed USDC");
        assertEq(juniorVault.pendingDepositAssets(pendingLp, epochId), 0, "pending balance should clear");
        assertEq(epochAssets, 0, "epoch aggregate assets should decrease");
        assertFalse(finalized, "epoch should remain unfinalized");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_PendingDepositClaimsAllocateAllFinalizedShares() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        uint256 aliceDepositUsdc = 33_333e6;
        uint256 bobDepositUsdc = 66_667e6;

        usdc.mint(alice, aliceDepositUsdc);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), aliceDepositUsdc);
        uint256 epochId = juniorVault.requestDeposit(aliceDepositUsdc, alice);
        vm.stopPrank();

        usdc.mint(bob, bobDepositUsdc);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), bobDepositUsdc);
        assertEq(juniorVault.requestDeposit(bobDepositUsdc, bob), epochId, "same epoch should batch together");
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(epochId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        IHousePool.LpEpochSettlementResult memory settlement = _settleLpEpochForTest();
        uint256 finalizedShares = settlement.juniorDepositShares;

        vm.prank(alice);
        uint256 aliceShares = juniorVault.claimDepositShares(epochId);
        vm.prank(bob);
        uint256 bobShares = juniorVault.claimDepositShares(epochId);

        (,, uint256 claimedAssets, uint256 claimedShares,) = juniorVault.depositEpochs(epochId);
        assertLe(aliceShares + bobShares, finalizedShares, "controller floors must not over-allocate shares");
        assertLe(
            finalizedShares - aliceShares - bobShares,
            1,
            "two-controller allocation should burn at most one share of terminal dust"
        );
        assertEq(claimedAssets, aliceDepositUsdc + bobDepositUsdc, "epoch should mark all assets claimed");
        assertEq(claimedShares, finalizedShares, "epoch should mark all shares claimed");
        assertEq(juniorVault.balanceOf(address(juniorVault)), 0, "terminal deposit dust must leave escrow");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_FinalizedPendingDepositSharesAreEscrowedBeforeClaim() public {
        address pendingLp = address(0xE5C20);
        uint256 depositUsdc = 100_000e6;

        usdc.mint(pendingLp, depositUsdc);
        vm.startPrank(pendingLp);
        usdc.approve(address(juniorVault), depositUsdc);
        uint256 epochId = juniorVault.requestDeposit(depositUsdc, pendingLp);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(epochId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        uint256 incumbentAssetsBefore = juniorVault.estimateRedeemAssets(juniorVault.balanceOf(address(this)));
        IHousePool.LpEpochSettlementResult memory settlement = _settleLpEpochForTest();
        uint256 finalizedShares = settlement.juniorDepositShares;

        assertEq(
            juniorVault.balanceOf(address(juniorVault)),
            finalizedShares,
            "finalized shares must be escrowed before user claim"
        );
        assertApproxEqAbs(
            juniorVault.estimateRedeemAssets(juniorVault.balanceOf(address(this))),
            incumbentAssetsBefore,
            2,
            "unclaimed finalized deposits must not boost incumbent withdrawal value"
        );

        vm.prank(pendingLp);
        juniorVault.claimDepositShares(epochId);

        assertEq(juniorVault.balanceOf(address(juniorVault)), 0, "claim should release escrowed shares");
        assertEq(juniorVault.balanceOf(pendingLp), finalizedShares, "claim should transfer escrowed shares");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_PendingSeniorDepositUsesSameDelayedActivationFlow() public {
        address trader = address(0x7102);
        address seniorLp = address(0x5E7102);
        uint256 depositUsdc = 25_000e6;

        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        assertEq(seniorVault.maxDeposit(seniorLp), 0, "no finalized request should expose claim capacity");
        assertGt(seniorVault.maxRequestDeposit(seniorLp), 0, "senior pending deposit requests should remain available");

        usdc.mint(seniorLp, depositUsdc);
        vm.startPrank(seniorLp);
        usdc.approve(address(seniorVault), depositUsdc);
        uint256 epochId = seniorVault.requestDeposit(depositUsdc, seniorLp);
        vm.stopPrank();

        uint256 activationTime = seniorVault.depositEpochStart(epochId);
        vm.warp(activationTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(activationTime));
        IHousePool.LpEpochSettlementResult memory settlement = _settleLpEpochForTest();
        uint256 finalizedShares = settlement.seniorDepositShares;

        vm.prank(seniorLp);
        uint256 claimedShares = seniorVault.claimDepositShares(epochId);

        assertEq(claimedShares, finalizedShares, "single senior depositor should receive the finalized epoch shares");
        assertEq(seniorVault.balanceOf(seniorLp), claimedShares, "senior claimed shares should be self-custodied");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ZeroLiabilityOpenInterestStillUsesDelayedDepositClaims() public {
        address trader = address(0x7101);
        address lp = address(0x1A11CE);

        _fundTrader(trader, 5000e6);
        _open(trader, CfdTypes.Side.SHORT, 10_000e18, 2000e6, CAP_PRICE);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(snapshot.maxLiabilityUsdc, 0, "SHORT opened at the cap has no bounded upside liability");
        assertTrue(snapshot.hasOpenPositions, "snapshot must still expose live open interest");
        assertEq(juniorVault.maxDeposit(lp), 0, "no finalized request should expose claim capacity");
        assertGt(juniorVault.maxRequestDeposit(lp), 0, "pending deposit requests should remain available");
    }

}

contract SymmetricNavEntryCancellationTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
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

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ActivePendingDepositCanCancelWhenSymmetricNavImpairsSenior() public {
        address pendingLp = address(0xCAFE3);
        address trader = address(0xBEA4);
        uint256 depositUsdc = 50e6;

        usdc.mint(pendingLp, depositUsdc);
        vm.startPrank(pendingLp);
        usdc.approve(address(juniorVault), depositUsdc);
        uint256 epochId = juniorVault.requestDeposit(depositUsdc, pendingLp);
        vm.stopPrank();

        _fundTrader(trader, 100e6);
        _open(trader, CfdTypes.Side.SHORT, 1600e18, 50e6, 1e8);

        uint256 activationTime = juniorVault.depositEpochStart(epochId);
        vm.warp(activationTime);
        vm.prank(address(router));
        engine.updateMarkPrice(CAP_PRICE, uint64(activationTime));

        (uint256 depositSeniorAssets,) = pool.getPendingDepositTrancheState();
        assertLt(
            depositSeniorAssets,
            pool.seniorHighWaterMark(),
            "symmetric entry and exit NAV must expose the same terminal-price impairment"
        );
        assertTrue(
            pool.isSeniorImpairedAfterPendingDepositReconcile(),
            "active cancellation gate must match conservative finalization accounting"
        );

        uint256 markPrice = engine.lastMarkPrice();
        uint256 markTime = engine.lastMarkTime();
        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        vm.prank(address(router));
        pool.settleLpEpoch(markPrice, markTime);
        assertEq(juniorVault.claimableDepositRequest(epochId, pendingLp), 0, "deferred entry must not be claimable");

        vm.prank(pendingLp);
        uint256 refunded = juniorVault.cancelPendingDeposit(epochId);

        assertEq(refunded, depositUsdc, "active cancellation should refund escrowed assets");
        assertEq(usdc.balanceOf(pendingLp), depositUsdc, "depositor should recover escrowed USDC");
        assertEq(juniorVault.pendingDepositAssets(pendingLp, epochId), 0, "pending balance should clear");
    }

}
