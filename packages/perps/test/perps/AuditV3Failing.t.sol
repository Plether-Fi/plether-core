// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Historical audit identifiers and test names are retained for traceability.
// The assertions below exercise current behavior; legacy names do not describe unfixed vulnerabilities.

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

// =====================================================================
// #1 regression - USDC-funded commits need no ETH and orders have a finite default lifetime
// =====================================================================

contract AuditV3Failing_QueueGriefing is BasePerpTest {

    function test_1_CommitOrderDoesNotRequireEth() public {
        _fundTrader(address(0xA11CE), 10_000e6);

        vm.prank(address(0xA11CE));
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 1000e6, 1e8, false);

        assertEq(router.nextCommitId(), 2, "Commit should succeed without sending ETH");
    }

    function test_1_MaxExecutionWindowSecondsShouldBeNonZeroByDefault() public {
        // A nonzero default lifetime lets terminal cleanup expire abandoned queue entries.
        assertGt(router.maxExecutionWindowSeconds(), 0, "maxExecutionWindowSeconds should have a non-zero default");
    }

}

// =====================================================================
// #2 regression - FAD-only live markets retain the normal mark-age limit
// =====================================================================

contract AuditV3Failing_FadStaleness is BasePerpTest {

    address alice = address(0xA11CE);

    function _fridayAt(
        uint256 hourUtc
    ) internal pure returns (uint256) {
        uint256 fridayMidnight = 1_709_856_000;
        return fridayMidnight + (hourUtc * 3600);
    }

    function test_2_CheckWithdrawAcceptsStaleMarkDuringLiveMarketFadWindow() public {
        address account = alice;
        _fundTrader(alice, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        // Friday 21:30 UTC: FAD active but oracle still live until 22:00.
        uint256 fridayEvening = _fridayAt(21) + 30 minutes;
        vm.warp(fridayEvening);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(fridayEvening));

        // 29m 59s later: still before the 22:00 oracle freeze boundary.
        // Mark is far beyond the normal 120s limit and should revert.
        vm.warp(fridayEvening + 30 minutes - 1);

        vm.prank(alice);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdraw(account, 100e6);
    }

    function test_2_HousePoolAcceptsStaleMarkDuringLiveMarketFadWindow() public {
        address account = alice;
        _fundTrader(alice, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        uint256 fridayEvening = _fridayAt(21) + 30 minutes;
        vm.warp(fridayEvening);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(fridayEvening));

        vm.warp(fridayEvening + 30 minutes - 1);

        // FAD alone does not relax mark age: the stale live-market mark blocks a new LP request.
        address lp = address(0x1111);
        uint256 depositAmount = pool.minTrancheDepositUsdc();
        usdc.mint(lp, depositAmount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), depositAmount);
        assertEq(juniorVault.maxRequestDeposit(lp), 0, "stale mark should zero junior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        juniorVault.requestDeposit(depositAmount, lp);
        vm.stopPrank();
    }

}

// =====================================================================
// #4 regression - ordinary LP deposits cannot recapitalize terminally wiped tranches
// =====================================================================

contract AuditV3Failing_JuniorWipeout is BasePerpTest {

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

    function test_4_JuniorCannotBeRecapitalizedAfterWipeoutViaOrdinaryDeposit() public {
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

contract AuditV3Failing_SeniorImpairment is BasePerpTest {

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

    function test_4_SeniorCannotBeRecapitalizedAfterFullWipeoutViaOrdinaryDeposit() public {
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

// =====================================================================
// #5 regression - wrong-side close commitment is rejected before execution
// =====================================================================

contract AuditV3Failing_CloseSlippageInversion is BasePerpTest {

    address alice = address(0xA11CE);

    function test_5_RouterAllowsQueuedCloseWithMismatchedSide() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        address account = alice;
        _open(account, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SideMismatch.selector);
        router.commitOrder(CfdTypes.Side.SHORT, 20_000e18, 0, 0, true);
    }

}
