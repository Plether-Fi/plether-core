// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "../../src/perps/CfdEngineAdmin.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouterAdmin} from "../../src/perps/OrderRouterAdmin.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract TimelockPauseTest is BasePerpTest {

    event RiskParamsProposalCancelled();

    address alice = address(0x111);
    address nonOwner = address(0xBAD);

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 500_000 * 1e6;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000 * 1e6;
    }

    function setUp() public override {
        super.setUp();

        usdc.mint(alice, 50_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), 50_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();
    }

    // ==========================================
    // CfdEngine TIMELOCK TESTS
    // ==========================================

    function test_ProposeRiskParams_StoresAndSetsActivationTime() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            maintMarginBps: 200,
            initMarginBps: ((200) * 15) / 10,
            fadMarginBps: 500,
            baseCarryBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20
        });

        engineAdmin.proposeRiskParams(newParams);
        assertGt(engineAdmin.riskParamsActivationTime(), 0);
    }

    function test_FinalizeRiskParams_BeforeTimelock_Reverts() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            maintMarginBps: 200,
            initMarginBps: ((200) * 15) / 10,
            fadMarginBps: 500,
            baseCarryBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20
        });

        engineAdmin.proposeRiskParams(newParams);

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__TimelockNotReady.selector);
        engineAdmin.finalizeRiskParams();
    }

    function test_FinalizeRiskParams_AfterTimelock_Succeeds() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            maintMarginBps: 200,
            initMarginBps: ((200) * 15) / 10,
            fadMarginBps: 500,
            baseCarryBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20
        });

        engineAdmin.proposeRiskParams(newParams);
        _warpForward(48 hours + 1);
        engineAdmin.finalizeRiskParams();

        (,, uint256 maintMarginBps,,,,,) = engine.riskParams();
        assertEq(maintMarginBps, 200);
        assertEq(engineAdmin.riskParamsActivationTime(), 0);
    }

    function test_FinalizeRiskParams_NoProposal_Reverts() public {
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__NoProposal.selector);
        engineAdmin.finalizeRiskParams();
    }

    function test_CancelRiskParams_ClearsPending() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            maintMarginBps: 200,
            initMarginBps: ((200) * 15) / 10,
            fadMarginBps: 500,
            baseCarryBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20
        });

        engineAdmin.proposeRiskParams(newParams);
        vm.expectEmit(false, false, false, true);
        emit RiskParamsProposalCancelled();
        engineAdmin.cancelRiskParamsProposal();
        assertEq(engineAdmin.riskParamsActivationTime(), 0);

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__NoProposal.selector);
        engineAdmin.finalizeRiskParams();
    }

    function test_ProposeRiskParams_OnlyOwner() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        engineAdmin.proposeRiskParams(newParams);
    }

    function test_RePropose_OverwritesPendingAndResetsTimer() public {
        CfdTypes.RiskParams memory first = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 200,
            initMarginBps: ((200) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        engineAdmin.proposeRiskParams(first);
        uint256 firstActivation = engineAdmin.riskParamsActivationTime();

        _warpForward(24 hours);

        CfdTypes.RiskParams memory second = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 300,
            initMarginBps: ((300) * 15) / 10,
            fadMarginBps: 500,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        engineAdmin.proposeRiskParams(second);
        uint256 secondActivation = engineAdmin.riskParamsActivationTime();

        assertGt(secondActivation, firstActivation);
    }

    // ==========================================
    // HousePool TIMELOCK TESTS
    // ==========================================

    function test_ProposeSeniorRate_TimelockFlow() public {
        pool.proposeSeniorRate(1200);
        assertGt(pool.seniorRateActivationTime(), 0);

        vm.expectRevert(HousePool.HousePool__TimelockNotReady.selector);
        pool.finalizeSeniorRate();

        _warpForward(48 hours + 1);
        pool.finalizeSeniorRate();

        assertEq(pool.seniorRateBps(), 1200);
        assertEq(pool.seniorRateActivationTime(), 0);
    }

    function test_ProposeMarkStalenessLimit_TimelockFlow() public {
        pool.proposeMarkStalenessLimit(60);
        assertGt(pool.markStalenessLimitActivationTime(), 0);

        vm.expectRevert(HousePool.HousePool__TimelockNotReady.selector);
        pool.finalizeMarkStalenessLimit();

        _warpForward(48 hours + 1);
        pool.finalizeMarkStalenessLimit();

        assertEq(pool.markStalenessLimit(), 60);
        assertEq(pool.markStalenessLimitActivationTime(), 0);
    }

    function test_FinalizeSeniorRate_NoProposal_Reverts() public {
        vm.expectRevert(HousePool.HousePool__NoProposal.selector);
        pool.finalizeSeniorRate();
    }

    function test_CancelSeniorRate_ClearsPending() public {
        pool.proposeSeniorRate(1500);
        pool.cancelSeniorRateProposal();
        assertEq(pool.seniorRateActivationTime(), 0);
    }

    // ==========================================
    // OrderRouter TIMELOCK TESTS
    // ==========================================

    function test_ProposeMaxOrderAge_TimelockFlow() public {
        routerAdmin.proposeMaxOrderAge(600);

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__TimelockNotReady.selector);
        routerAdmin.finalizeMaxOrderAge();

        _warpForward(48 hours + 1);
        routerAdmin.finalizeMaxOrderAge();

        assertEq(router.maxOrderAge(), 600);
        assertEq(routerAdmin.maxOrderAgeActivationTime(), 0);
    }

    function test_FinalizeMaxOrderAge_NoProposal_Reverts() public {
        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__NoProposal.selector);
        routerAdmin.finalizeMaxOrderAge();
    }

    function test_OrderRouter_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        routerAdmin.proposeMaxOrderAge(600);
    }

    // ==========================================
    // MarginClearinghouse CONFIG TESTS
    // ==========================================

    function test_SetEngine_SucceedsOnce() public {
        MarginClearinghouse fresh = new MarginClearinghouse(address(usdc));
        fresh.setEngine(address(engine));

        assertEq(fresh.engine(), address(engine));
    }

    function test_SetEngine_OnlyOwner() public {
        MarginClearinghouse fresh = new MarginClearinghouse(address(usdc));

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        fresh.setEngine(address(engine));
    }

    function test_SetEngine_CannotBeChanged() public {
        MarginClearinghouse fresh = new MarginClearinghouse(address(usdc));
        fresh.setEngine(address(engine));

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__EngineAlreadySet.selector);
        fresh.setEngine(address(router));
    }

    // ==========================================
    // PAUSE TESTS — OrderRouter
    // ==========================================

    function test_CommitOrder_RevertsWhenPaused() public {
        routerAdmin.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
    }

    function test_ExecuteOrder_WorksWhenPaused() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        routerAdmin.pause();

        bytes[] memory empty;
        router.executeOrder(1, empty);
        assertEq(router.nextExecuteId(), 0);
    }

    function test_ExecuteLiquidation_WorksWhenPaused() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        routerAdmin.pause();

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.98e8);

        router.executeLiquidation(accountId, pythData);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0);
    }

    function test_UpdateMarkPrice_WorksWhenPaused() public {
        routerAdmin.pause();

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.05e8);
        router.updateMarkPrice(pythData);

        assertEq(engine.lastMarkPrice(), 1.05e8);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        routerAdmin.pause();
    }

    function test_Unpause_RestoresCommitOrder() public {
        routerAdmin.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        routerAdmin.unpause();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        assertEq(router.nextCommitId(), 2);
    }

    // ==========================================
    // PAUSE TESTS — HousePool
    // ==========================================

    function test_DepositSenior_RevertsWhenHousePoolPaused() public {
        pool.pause();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 10_000 * 1e6);
        assertEq(seniorVault.maxDeposit(alice), 0, "paused pool should zero senior maxDeposit");
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 10_000 * 1e6, 0));
        seniorVault.deposit(10_000 * 1e6, alice);
        vm.stopPrank();
    }

    function test_DepositJunior_RevertsWhenHousePoolPaused() public {
        pool.pause();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 10_000 * 1e6);
        assertEq(juniorVault.maxDeposit(alice), 0, "paused pool should zero junior maxDeposit");
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 10_000 * 1e6, 0));
        juniorVault.deposit(10_000 * 1e6, alice);
        vm.stopPrank();
    }

    function test_WithdrawSenior_WorksWhenHousePoolPaused() public {
        _warpForward(1 hours);
        pool.pause();

        uint256 maxW = seniorVault.maxWithdraw(address(this));
        if (maxW > 0) {
            seniorVault.withdraw(maxW, address(this), address(this));
        }
    }

    function test_WithdrawJunior_WorksWhenHousePoolPaused() public {
        _warpForward(1 hours);
        pool.pause();

        uint256 maxW = juniorVault.maxWithdraw(address(this));
        if (maxW > 0) {
            juniorVault.withdraw(maxW, address(this), address(this));
        }
    }

    function test_HousePool_Pause_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        pool.pause();
    }

    function test_HousePool_Unpause_RestoresDeposits() public {
        pool.pause();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 10_000 * 1e6);
        assertEq(juniorVault.maxDeposit(alice), 0, "paused pool should zero junior maxDeposit");
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 10_000 * 1e6, 0));
        juniorVault.deposit(10_000 * 1e6, alice);
        vm.stopPrank();

        pool.unpause();

        vm.prank(alice);
        juniorVault.deposit(10_000 * 1e6, alice);
        assertGt(juniorVault.balanceOf(alice), 0);
    }

}
