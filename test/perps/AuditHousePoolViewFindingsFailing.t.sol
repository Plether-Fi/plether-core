// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {HousePoolAccountingLib} from "../../src/perps/libraries/HousePoolAccountingLib.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract HousePoolAccountingLibHarness {

    function buildWithdrawal(
        ICfdEngine.HousePoolInputSnapshot memory snapshot
    ) external pure returns (HousePoolAccountingLib.WithdrawalSnapshot memory) {
        return HousePoolAccountingLib.buildWithdrawalSnapshot(snapshot);
    }

    function buildReconcile(
        ICfdEngine.HousePoolInputSnapshot memory snapshot
    ) external pure returns (HousePoolAccountingLib.ReconcileSnapshot memory) {
        return HousePoolAccountingLib.buildReconcileSnapshot(snapshot);
    }

}

contract AuditHousePoolViewFindingsFailing_ZeroPrincipalCapture is BasePerpTest {

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

    function test_H1_ZeroPrincipalRecapitalizationCashMustNotBeCapturableByNextJuniorDepositor() public {
        uint256 strandedCash = 1000e6;
        usdc.mint(address(pool), strandedCash);
        pool.accountExcess();

        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(attacker, strandedCash);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), strandedCash);
        vm.expectRevert(TrancheVault.TrancheVault__TradingNotActive.selector);
        juniorVault.deposit(strandedCash, attacker);
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

contract AuditHousePoolViewFindingsFailing_EmptyJuniorRevenue is BasePerpTest {

    address seniorLp = address(0x1111);
    address juniorLp = address(0x2222);

    uint256 constant SEEDED_JUNIOR_SHARES = 1_000_000_000_000;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_M1_ReconcileMustNotAssignRevenueToZeroSupplyJuniorTranche() public {
        _fundSenior(seniorLp, 100_000e6);
        _fundJunior(juniorLp, 100_000e6);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.startPrank(juniorLp);
        juniorVault.redeem(juniorVault.balanceOf(juniorLp), juniorLp, juniorLp);
        vm.stopPrank();

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

contract AuditHousePoolViewFindingsFailing_StaleYieldBackfill is BasePerpTest {

    address seniorLp = address(0x4444);
    address juniorLp = address(0x5555);
    address trader = address(0x6666);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_L1_StaleReconcileMustPreserveClock() public {
        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);

        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 before = pool.lastReconcileTime();

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            pool.lastReconcileTime(),
            before,
            "Stale reconcile should preserve the clock so stale-window yield is not destroyed"
        );
    }

}

contract AuditHousePoolViewFindingsFailing_ProjectedFundingViews is BasePerpTest {

    address trader = address(0x7777);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.5e18,
            maxApy: 3e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function test_L2_SimpleHealthViewsMustUseProjectedFunding() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 30 days);

        CfdEngine.PositionView memory positionView = engine.getPositionView(accountId);
        ICfdEngine.AccountLedgerSnapshot memory snapshot = engine.getAccountLedgerSnapshot(accountId);
        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, 1e8);

        assertEq(positionView.pendingFundingUsdc, preview.fundingUsdc, "Position view should project pending funding");
        assertEq(snapshot.pendingFundingUsdc, preview.fundingUsdc, "Ledger snapshot should project pending funding");
    }

}

contract AuditHousePoolViewFindingsFailing_WithdrawalCapLiveness is BasePerpTest {

    address seniorLp = address(0x8888);
    address juniorLp = address(0x9999);
    address trader = address(0xAAAA);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function test_L3_WithdrawalCapGettersMustZeroWhenWithdrawalsAreNotLive() public {
        _fundSenior(seniorLp, 100_000e6);
        _fundJunior(juniorLp, 100_000e6);
        _fundTrader(trader, 50_000e6);

        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 121);

        assertFalse(pool.isWithdrawalLive(), "Withdrawal liveness should be false once the mark is stale");
        assertEq(pool.getMaxSeniorWithdraw(), 0, "Senior withdrawal cap getter should be liveness-gated");
        assertEq(pool.getMaxJuniorWithdraw(), 0, "Junior withdrawal cap getter should be liveness-gated");
    }

}

contract AuditHousePoolViewFindingsFailing_GrossAssetsReconstruction is BasePerpTest {

    HousePoolAccountingLibHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new HousePoolAccountingLibHarness();
    }

    function test_M2_GrossAssetsMustNotExceedActualCashWhenFeesExceedCash() public {
        address trader = address(0x1234);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundJunior(address(this), 500_000e6);
        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 fees = engine.accumulatedFeesUsdc();
        assertGt(fees, 0, "Setup must accrue protocol fees");

        uint256 actualCash = 10_000_000;
        uint256 burnAmount = pool.totalAssets() - actualCash;
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), burnAmount);

        ICfdEngine.HousePoolInputSnapshot memory snapshot = engine.getHousePoolInputSnapshot(pool.markStalenessLimit());
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot = harness.buildWithdrawal(snapshot);
        HousePoolAccountingLib.ReconcileSnapshot memory reconcileSnapshot = harness.buildReconcile(snapshot);

        assertEq(snapshot.netPhysicalAssetsUsdc, 0, "Net physical assets should saturate to zero once fees exceed cash");
        assertEq(pool.totalAssets(), actualCash, "Test must leave the pool with less cash than the fee ledger");
        assertLe(
            withdrawalSnapshot.physicalAssets,
            pool.totalAssets(),
            "Withdrawal snapshot gross assets must not exceed actual cash"
        );
        assertLe(
            reconcileSnapshot.physicalAssets,
            pool.totalAssets(),
            "Reconcile snapshot gross assets must not exceed actual cash"
        );
    }

}
