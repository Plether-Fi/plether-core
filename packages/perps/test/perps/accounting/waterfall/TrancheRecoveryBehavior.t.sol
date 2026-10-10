// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract SeniorHighWaterRecoveryTest is BasePerpTest {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_PostWipeoutRequiresExplicitRecapForHwmReset() public {
        uint256 seedAssets = 50_000e6;
        uint256 recapAmount = 10_000e6;
        address seed = address(0xBEEF);

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, seed);

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(address(seniorVault), recapAmount);
        vm.startPrank(address(seniorVault));
        usdc.approve(address(pool), recapAmount);
        (bool legacyDepositAccepted,) =
            address(pool).call(abi.encodeWithSignature("depositSenior(uint256)", recapAmount));
        assertFalse(legacyDepositAccepted, "removed synchronous Senior entrypoint must stay unavailable");
        vm.stopPrank();

        usdc.mint(address(pool), recapAmount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            recapAmount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), recapAmount, "Explicit recapitalization should restore senior principal");
        assertEq(pool.seniorHighWaterMark(), recapAmount, "Explicit recapitalization should reset the HWM");
    }

}

contract TerminalEconomicStateRecoveryTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_SeniorHighWaterMarkMustSurviveFullWipeout() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.seniorHighWaterMark(), 0, "Senior recovery rights should survive wipeout");
    }

}

contract ImpairedSeniorEntryTest is BasePerpTest {

    address alice = address(0x111);
    address attacker = address(0x666);

    uint256 constant SEEDED_SENIOR = 1000e6;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
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

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_ImpairedSeniorRejectsNewDepositRequests() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(alice, 50_000 * 1e6);

        assertEq(
            pool.seniorHighWaterMark(),
            pool.seniorPrincipal(),
            "new senior principal and async-epoch coupon accrual must remain at the HWM"
        );
        assertGt(pool.seniorHighWaterMark(), SEEDED_SENIOR + 100_000 * 1e6);

        // Open a SHORT position. SHORT profits when oracle price rises.
        // 100k tokens at $1.00, max profit = 100k * ($2 - $1) = $100k
        // Pool has $150k, so solvency check passes.
        _fundTrader(address(0xAAA), 5000 * 1e6);
        address traderAccount = address(0xAAA);
        _open(traderAccount, CfdTypes.Side.SHORT, 100_000 * 1e18, 5000 * 1e6, 1e8);

        // Price rises to $1.80 → SHORT unrealized PnL = 100k * 0.8 = $80k
        // Reconcile: distributable ≈ cash - mtm, loss ≈ $80k
        // Junior absorbs $50k, senior absorbs $30k → senior = $70k, HWM = $100k
        vm.prank(address(router));
        engine.updateMarkPrice(1.8e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertLt(pool.seniorPrincipal(), pool.seniorHighWaterMark(), "Deficit must exist after crash");

        // deposit into impaired tranche is now blocked
        usdc.mint(attacker, 1_000_000 * 1e6);
        vm.startPrank(attacker);
        usdc.approve(address(seniorVault), 1_000_000 * 1e6);
        assertEq(seniorVault.maxRequestDeposit(attacker), 0, "impaired senior should zero request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(1_000_000 * 1e6, attacker);
        vm.stopPrank();
    }

}

contract ImpairedTrancheAdmissionTest is BasePerpTest {

    address alice = address(0x111);
    address attacker = address(0x666);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
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

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_ImpairedTrancheRejectsOrdinaryEntry() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(address(this), 50_000 * 1e6);

        // Create a deficit: SHORT trader profits, wiping junior and dipping into senior
        _fundTrader(address(0xAAA), 5000 * 1e6);
        address traderAccount = address(0xAAA);
        _open(traderAccount, CfdTypes.Side.SHORT, 100_000 * 1e18, 5000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1.8e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorPrincipal = pool.seniorPrincipal();
        uint256 hwm = pool.seniorHighWaterMark();
        assertLt(seniorPrincipal, hwm, "Senior tranche is impaired");

        // New deposits must be rejected while Senior principal is below its high-water mark.
        uint256 depositAmount = pool.minTrancheDepositUsdc();
        usdc.mint(attacker, depositAmount);
        vm.startPrank(attacker);
        usdc.approve(address(seniorVault), depositAmount);
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(depositAmount, attacker);
        vm.stopPrank();
    }

}

contract UnassignedRecapitalizationTest is BasePerpTest {

    address attacker = address(0xBAD);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _autoActivateTrading() internal pure override returns (bool) {
        return false;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_ZeroPrincipalRecapitalizationCashMustNotBeCapturableByNextJuniorDepositor() public {
        uint256 strandedCash = 1000e6;
        usdc.mint(address(pool), strandedCash);
        pool.accountExcess();

        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(attacker, strandedCash);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), strandedCash);
        vm.expectRevert(TrancheVault.TrancheVault__TradingNotActive.selector);
        juniorVault.requestDeposit(strandedCash, attacker);
        vm.stopPrank();

        assertEq(
            usdc.balanceOf(attacker),
            strandedCash,
            "Deposits must stay blocked until governance explicitly assigns unclaimed pool cash"
        );
        assertEq(pool.unassignedAssets(), strandedCash, "Zero-principal pool cash should remain quarantined");

        pool.assignUnassignedAssets(false, address(this));

        assertEq(pool.unassignedAssets(), 0, "Explicit bootstrap should consume the quarantined cash bucket");
        assertGt(juniorVault.balanceOf(address(this)), 0, "Bootstrap assignment should mint claimable junior shares");
    }

}

contract EmptyTrancheRevenueTest is BasePerpTest {

    address seniorLp = address(0x1111);
    address juniorLp = address(0x2222);

    uint256 constant SEEDED_JUNIOR_SHARES = 1_000_000_000_000;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_RevenueBelongsToPermanentJuniorSeedAfterPublicExit() public {
        _fundSenior(seniorLp, 100_000e6);
        _fundJunior(juniorLp, 100_000e6);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 redeemShares = juniorVault.balanceOf(juniorLp);
        vm.prank(juniorLp);
        uint256 requestId = juniorVault.requestRedeem(redeemShares, juniorLp, juniorLp);
        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();
        uint256 claimableShares = juniorVault.claimableRedeemRequest(requestId, juniorLp);
        vm.prank(juniorLp);
        juniorVault.claimRedeem(requestId, claimableShares, juniorLp, juniorLp);

        usdc.mint(address(pool), 100e6);
        pool.accountExcess();
        uint256 unassignedBefore = pool.unassignedAssets();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(juniorVault.totalSupply(), SEEDED_JUNIOR_SHARES, "Only the permanent junior seed floor should remain");
        assertGt(pool.juniorPrincipal(), 1000e6, "Revenue should remain owned by the seeded junior floor");
        assertEq(pool.unassignedAssets(), unassignedBefore, "Seed-owned junior revenue should not be quarantined");
    }

}

contract AccountPriceCollateralRecoveryTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
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
        return 1_000_000e6;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_WipedTrancheRejectsNewDeposits() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        address recapLp = address(0xCAFE);
        usdc.mint(recapLp, 10_000e6);

        vm.startPrank(recapLp);
        usdc.approve(address(seniorVault), type(uint256).max);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        seniorVault.requestDeposit(10_000e6, recapLp);
        vm.stopPrank();
    }

}

contract JuniorWipeoutAdmissionTest is BasePerpTest {

    address lp = address(0xB0B);
    address attacker = address(0xBAD);
    address trader = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
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

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_OneDollarDepositCannotRecapWipedTranche() public {
        // Senior absorbs last-loss; junior absorbs first-loss.
        // With senior + junior, a trading loss that exceeds junior wipes it to exactly 0.
        _fundSenior(address(this), 10_000e6);
        _fundJunior(lp, 40_000e6);
        uint256 lpShares = juniorVault.balanceOf(lp);
        assertGt(lpShares, 0, "LP should have shares");

        // Trader opens a LONG with $50K maximum profit, exceeding Junior capital.
        _fundTrader(trader, 50_000e6);
        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8);

        // LONG profits when oracle drops. Close at 0 for exact max payout.
        _close(traderAccount, CfdTypes.Side.LONG, 50_000e18, 0);

        // Reconcile: loss exceeds juniorPrincipal → junior wiped to exactly 0.
        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorPrincipalAfterWipe = pool.juniorPrincipal();
        uint256 totalSupplyAfterWipe = juniorVault.totalSupply();

        assertEq(juniorPrincipalAfterWipe, 0, "junior must be fully wiped");
        assertGt(totalSupplyAfterWipe, 0, "shares must survive the wipeout");

        // A new LP cannot recapitalize the wiped tranche through an ordinary deposit request.
        usdc.mint(attacker, 1e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 1e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.requestDeposit(1e6, attacker);
        vm.stopPrank();
    }

}

contract TerminalJuniorEntryTest is BasePerpTest {

    address lp = address(0x1111);

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _autoActivateTrading() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        usdc.mint(address(this), 550_000e6);
        usdc.approve(address(pool), 550_000e6);
        pool.initializeSeedPosition(false, 50_000e6, address(this));
        pool.initializeSeedPosition(true, 500_000e6, address(this));
        pool.activateTrading();
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_JuniorCannotBeRecapitalizedAfterWipeoutViaOrdinaryDeposit() public {
        address account = address(0xA11CE);
        _fundTrader(address(0xA11CE), 100_000e6);

        // LONG profits when price drops. Max profit = 1e8 * 50_000e18 / 1e20 = 50_000e6
        _open(account, CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8);
        _close(account, CfdTypes.Side.LONG, 50_000e18, 0);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Junior wiped");
        assertGt(juniorVault.totalSupply(), 0, "Shares still exist");

        // Ordinary entry into a zero-NAV tranche with surviving shares is intentionally rejected.
        // Governance recapitalization is a separate path; this test does not exercise it.
        usdc.mint(lp, 50_000e6);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), 50_000e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.requestDeposit(50_000e6, lp);
        vm.stopPrank();
    }

}

contract TerminalSeniorEntryTest is BasePerpTest {

    address lp = address(0x1111);

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _autoActivateTrading() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        usdc.mint(address(this), 550_000e6);
        usdc.approve(address(pool), 550_000e6);
        pool.initializeSeedPosition(false, 50_000e6, address(this));
        pool.initializeSeedPosition(true, 500_000e6, address(this));
        pool.activateTrading();
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
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

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_SeniorCannotBeRecapitalizedAfterFullWipeoutViaOrdinaryDeposit() public {
        address account = address(0xA11CE);
        _fundTrader(address(0xA11CE), 600_000e6);

        // Exercise the terminal-wipeout path independently of the optional admission buffer.
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.settlementBufferBps = 0;
        engineAdmin.proposeRiskConfig(config);
        vm.warp(engineAdmin.riskConfigActivationTime());
        engineAdmin.finalizeRiskConfig();

        // Round 1: Wipe junior (50k).
        _open(account, CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8);
        _close(account, CfdTypes.Side.LONG, 50_000e18, 0);

        vm.prank(address(juniorVault));
        pool.reconcile();

        // Round 2: Junior is 0, further losses wipe senior completely.
        _open(account, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);
        _close(account, CfdTypes.Side.LONG, 500_000e18, 0);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Senior wiped out");
        assertGt(pool.seniorHighWaterMark(), 0, "Stale HWM remains before recap");

        // The terminal-wipeout guard rejects ordinary entry even though the old HWM remains.
        // This test does not attempt governance recapitalization.
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(seniorVault), 1_000_000e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        seniorVault.requestDeposit(1_000_000e6, lp);
        vm.stopPrank();
    }

}

contract ReservedSettlementBehaviorRecoveryTest is BasePerpTest {

    address trader = address(0x111);
    address traderA = address(0xAAA1);
    address traderB = address(0xBBB1);
    address keeper = address(0x222);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_SeniorRequiresExplicitRecapAfterFullWipeout() public {
        address seniorLp = address(0x333);
        address juniorLp = address(0x444);

        _fundSenior(seniorLp, 100_000 * 1e6);
        _fundJunior(juniorLp, 100_000 * 1e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 depositAmount = 10_000 * 1e6;
        usdc.mint(address(seniorVault), depositAmount);
        vm.startPrank(address(seniorVault));
        usdc.approve(address(pool), depositAmount);
        (bool legacyDepositAccepted,) =
            address(pool).call(abi.encodeWithSignature("depositSenior(uint256)", depositAmount));
        assertFalse(legacyDepositAccepted, "removed synchronous Senior entrypoint must stay unavailable");
        vm.stopPrank();

        usdc.mint(address(pool), depositAmount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            depositAmount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), depositAmount, "Senior tranche should accept recapitalization from zero");
        assertEq(pool.seniorHighWaterMark(), depositAmount, "Recapitalization should seed a fresh HWM");
    }

}

contract RecapitalizationRevenueOwnershipTest is BasePerpTest {

    function _claimantLedgerUsdc() internal view returns (uint256) {
        return pool.seniorPrincipal() + pool.juniorPrincipal() + pool.unassignedAssets()
            + pool.pendingRecapitalizationUsdc() + pool.pendingTradingRevenueUsdc();
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_PendingRevenueCannotDisappearDuringRecapitalization() public {
        usdc.burn(address(pool), pool.rawAssets());

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal() + pool.juniorPrincipal(), 0, "Setup must fully wipe claimant principal");

        uint256 recapitalizationUsdc = 1000e6;
        uint256 revenueUsdc = 1000e6;
        usdc.mint(address(pool), recapitalizationUsdc + revenueUsdc);

        vm.startPrank(address(engine));
        pool.recordClaimantInflow(
            recapitalizationUsdc,
            IHousePool.ClaimantInflowKind.Recapitalization,
            IHousePool.ClaimantInflowCashMode.CashArrived
        );
        pool.recordClaimantInflow(
            revenueUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.stopPrank();

        uint256 claimantLedgerBefore = _claimantLedgerUsdc();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            _claimantLedgerUsdc(),
            claimantLedgerBefore,
            "Settled pending revenue must be credited to principal or unassigned assets before its bucket is decremented"
        );
    }

}
