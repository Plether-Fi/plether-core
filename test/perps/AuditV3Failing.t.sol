// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

// =====================================================================
// #1 - Queue griefing: zero-fee fake close orders block FIFO queue
// =====================================================================

contract AuditV3Failing_QueueGriefing is BasePerpTest {

    function test_1_CommitOrderDoesNotRequireEth() public {
        _fundTrader(address(0xA11CE), 10_000e6);

        vm.prank(address(0xA11CE));
        router.commitOrder(CfdTypes.Side.BULL, 1000e18, 1000e6, 1e8, false);

        assertEq(router.nextCommitId(), 2, "Commit should succeed without sending ETH");
    }

    function test_1_MaxOrderAgeShouldBeNonZeroByDefault() public {
        // maxOrderAge defaults to 0 — _skipStaleOrders early-returns,
        // so bogus orders never expire and block the queue permanently.
        assertGt(router.maxOrderAge(), 0, "maxOrderAge should have a non-zero default");
    }

}

// =====================================================================
// #2 - FAD vs oracle-frozen: stale marks accepted during live markets
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
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        // Friday 20:00 UTC: FAD active (starts 19:00) but oracle still live (frozen at 22:00)
        uint256 fridayEvening = _fridayAt(20);
        vm.warp(fridayEvening);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(fridayEvening));

        // 1h 59m 59s later: still before the 22:00 oracle freeze boundary.
        // Mark is far beyond the normal 120s limit and should revert.
        vm.warp(fridayEvening + 2 hours - 1);

        vm.prank(alice);
        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdraw(accountId, 100e6);
    }

    function test_2_HousePoolAcceptsStaleMarkDuringLiveMarketFadWindow() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        uint256 fridayEvening = _fridayAt(20);
        vm.warp(fridayEvening);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(fridayEvening));

        vm.warp(fridayEvening + 2 hours - 1);

        // LP deposit should revert (stale mark during live markets).
        // But _requireFreshMark uses isFadWindow() -> fadMaxStaleness (3 days).
        address lp = address(0x1111);
        usdc.mint(lp, 1000e6);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), 1000e6);
        assertEq(juniorVault.maxDeposit(lp), 0, "stale mark should zero junior maxDeposit during live FAD");
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, lp, 1000e6, 0));
        juniorVault.deposit(1000e6, lp);
        vm.stopPrank();
    }

}

// =====================================================================
// #4 - Tranche wipeout bricks recapitalization
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
        bytes32 accountId = bytes32(uint256(uint160(address(0xA11CE))));
        _fundTrader(address(0xA11CE), 100_000e6);

        // BULL profits when price drops. Max profit = 1e8 * 50_000e18 / 1e20 = 50_000e6
        _open(accountId, CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1e8);
        _close(accountId, CfdTypes.Side.BULL, 50_000e18, 0);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Junior wiped");
        assertGt(juniorVault.totalSupply(), 0, "Shares still exist");

        // Recapitalization deposit should succeed.
        // Currently reverts with TrancheImpaired (totalAssets=0, totalSupply>0).
        usdc.mint(lp, 50_000e6);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), 50_000e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.deposit(50_000e6, lp);
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
            bountyBps: 10
        });
    }

    function test_4_SeniorCannotBeRecapitalizedAfterFullWipeoutViaOrdinaryDeposit() public {
        bytes32 accountId = bytes32(uint256(uint160(address(0xA11CE))));
        _fundTrader(address(0xA11CE), 600_000e6);

        // Round 1: Wipe junior (50k).
        _open(accountId, CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1e8);
        _close(accountId, CfdTypes.Side.BULL, 50_000e18, 0);

        vm.prank(address(juniorVault));
        pool.reconcile();

        // Round 2: Junior is 0, further losses wipe senior completely.
        _open(accountId, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);
        _close(accountId, CfdTypes.Side.BULL, 500_000e18, 0);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Senior wiped out");
        assertGt(pool.seniorHighWaterMark(), 0, "Stale HWM remains before recap");

        // Recapitalization deposit should succeed.
        // Previously reverted forever because HWM remained above zero after wipeout.
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(seniorVault), 1_000_000e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        seniorVault.deposit(1_000_000e6, lp);
        vm.stopPrank();
    }

}

// =====================================================================
// #5 - Close order with wrong side inverts slippage protection
// =====================================================================

contract AuditV3Failing_CloseSlippageInversion is BasePerpTest {

    address alice = address(0xA11CE);

    function test_5_RouterAllowsQueuedCloseWithMismatchedSide() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 4));
        router.commitOrder(CfdTypes.Side.BEAR, 20_000e18, 0, 0, true);
    }

}
