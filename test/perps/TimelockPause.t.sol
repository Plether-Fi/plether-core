// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "../../src/perps/CfdEngineAdmin.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "../../src/perps/OrderRouterAdmin.sol";
import {ICfdEngineAdminHost} from "../../src/perps/interfaces/ICfdEngineAdminHost.sol";
import {IOrderRouterAdminHost} from "../../src/perps/interfaces/IOrderRouterAdminHost.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract TimelockPauseTest is BasePerpTest {

    event RiskConfigCancelled();

    address alice = address(0x111);
    address nonOwner = address(0xBAD);
    address pauser = address(0xCAFE);

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
        clearinghouse.deposit(alice, 50_000 * 1e6);
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

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = 7;
        engineAdmin.proposeRiskConfig(config);
        assertGt(engineAdmin.riskConfigActivationTime(), 0);
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

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = 7;
        engineAdmin.proposeRiskConfig(config);

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__TimelockNotReady.selector);
        engineAdmin.finalizeRiskConfig();
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

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = 7;
        engineAdmin.proposeRiskConfig(config);
        _warpForward(48 hours + 1);
        engineAdmin.finalizeRiskConfig();

        (,, uint256 maintMarginBps,,,,,) = engine.riskParams();
        assertEq(maintMarginBps, 200);
        assertEq(engine.executionFeeBps(), 7);
        assertEq(engineAdmin.riskConfigActivationTime(), 0);
    }

    function test_FinalizeRiskParams_NoProposal_Reverts() public {
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__NoProposal.selector);
        engineAdmin.finalizeRiskConfig();
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

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = engine.executionFeeBps();
        engineAdmin.proposeRiskConfig(config);
        vm.expectEmit(false, false, false, true);
        emit RiskConfigCancelled();
        engineAdmin.cancelRiskConfig();
        assertEq(engineAdmin.riskConfigActivationTime(), 0);

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__NoProposal.selector);
        engineAdmin.finalizeRiskConfig();
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
            bountyBps: 10
        });

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = engine.executionFeeBps();
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        engineAdmin.proposeRiskConfig(config);
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
            bountyBps: 10
        });

        ICfdEngineAdminHost.EngineRiskConfig memory firstConfig;
        firstConfig.riskParams = first;
        firstConfig.executionFeeBps = engine.executionFeeBps();
        engineAdmin.proposeRiskConfig(firstConfig);
        uint256 firstActivation = engineAdmin.riskConfigActivationTime();

        _warpForward(24 hours);

        CfdTypes.RiskParams memory second = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 300,
            initMarginBps: ((300) * 15) / 10,
            fadMarginBps: 500,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10
        });

        ICfdEngineAdminHost.EngineRiskConfig memory secondConfig;
        secondConfig.riskParams = second;
        secondConfig.executionFeeBps = engine.executionFeeBps();
        engineAdmin.proposeRiskConfig(secondConfig);
        uint256 secondActivation = engineAdmin.riskConfigActivationTime();

        assertGt(secondActivation, firstActivation);
    }

    // ==========================================
    // HousePool TIMELOCK TESTS
    // ==========================================

    function test_ProposePoolConfig_TimelockFlow() public {
        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1200;
        pool.proposePoolConfig(config);
        assertGt(pool.poolConfigActivationTime(), 0);

        vm.expectRevert(HousePool.HousePool__TimelockNotReady.selector);
        pool.finalizePoolConfig();

        _warpForward(48 hours + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        assertEq(pool.seniorRateBps(), 1200);
        assertEq(pool.poolConfigActivationTime(), 0);
    }

    function test_ProposePoolConfig_TimelockFlow_ForMarkStalenessLimit() public {
        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.markStalenessLimit = 60;
        pool.proposePoolConfig(config);
        assertGt(pool.poolConfigActivationTime(), 0);

        vm.expectRevert(HousePool.HousePool__TimelockNotReady.selector);
        pool.finalizePoolConfig();

        _warpForward(48 hours + 1);
        pool.finalizePoolConfig();

        assertEq(pool.markStalenessLimit(), 60);
        assertEq(pool.poolConfigActivationTime(), 0);
    }

    function test_FinalizePoolConfig_NoProposal_Reverts() public {
        vm.expectRevert(HousePool.HousePool__NoProposal.selector);
        pool.finalizePoolConfig();
    }

    function test_CancelPoolConfig_ClearsPending() public {
        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1500;
        pool.proposePoolConfig(config);
        pool.cancelPoolConfigProposal();
        assertEq(pool.poolConfigActivationTime(), 0);
    }

    function test_ProposePoolConfig_TimelockFlow_ForFrozenLpFees() public {
        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 40;
        config.juniorFrozenLpFeeBps = 90;
        pool.proposePoolConfig(config);
        assertGt(pool.poolConfigActivationTime(), 0);

        vm.expectRevert(HousePool.HousePool__TimelockNotReady.selector);
        pool.finalizePoolConfig();

        _warpForward(48 hours + 1);
        pool.finalizePoolConfig();

        assertEq(pool.seniorFrozenLpFeeBps(), 40);
        assertEq(pool.juniorFrozenLpFeeBps(), 90);
        assertEq(pool.poolConfigActivationTime(), 0);
    }

    function test_CancelPoolConfig_ZeroesPendingStruct() public {
        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 40;
        config.juniorFrozenLpFeeBps = 90;
        pool.proposePoolConfig(config);
        pool.cancelPoolConfigProposal();
        assertEq(pool.poolConfigActivationTime(), 0);
        (
            uint256 pendingSeniorRate,
            uint256 pendingMarkStaleness,
            uint256 pendingSeniorFrozenFee,
            uint256 pendingJuniorFrozenFee
        ) = pool.pendingPoolConfig();
        assertEq(pendingSeniorRate, 0);
        assertEq(pendingMarkStaleness, 0);
        assertEq(pendingSeniorFrozenFee, 0);
        assertEq(pendingJuniorFrozenFee, 0);
    }

    function test_ProposePoolConfig_RevertsForInvalidFrozenLpFees() public {
        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 1001;
        vm.expectRevert(HousePool.HousePool__InvalidFrozenLpFee.selector);
        pool.proposePoolConfig(config);

        config = _currentPoolConfig();
        config.juniorFrozenLpFeeBps = 1001;
        vm.expectRevert(HousePool.HousePool__InvalidFrozenLpFee.selector);
        pool.proposePoolConfig(config);
    }

    // ==========================================
    // OrderRouter TIMELOCK TESTS
    // ==========================================

    function test_ProposeMaxOrderAge_TimelockFlow() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 600;
        config.openOrderExecutionBountyBps = 2;
        config.minOpenOrderExecutionBountyUsdc = 20_000;
        config.maxOpenOrderExecutionBountyUsdc = 300_000;
        config.closeOrderExecutionBountyUsdc = 250_000;
        config.maxPendingOrders = 7;
        config.minEngineGas = 700_000;
        config.maxPruneOrdersPerCall = 32;
        routerAdmin.proposeRouterConfig(config);

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__TimelockNotReady.selector);
        routerAdmin.finalizeRouterConfig();

        _warpForward(48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        assertEq(router.maxOrderAge(), 600);
        assertEq(router.openOrderExecutionBountyBps(), 2);
        assertEq(router.minOpenOrderExecutionBountyUsdc(), 20_000);
        assertEq(router.maxOpenOrderExecutionBountyUsdc(), 300_000);
        assertEq(router.closeOrderExecutionBountyUsdc(), 250_000);
        assertEq(router.maxPendingOrders(), 7);
        assertEq(router.minEngineGas(), 700_000);
        assertEq(router.maxPruneOrdersPerCall(), 32);
        assertEq(routerAdmin.routerConfigActivationTime(), 0);
    }

    function test_FinalizeMaxOrderAge_NoProposal_Reverts() public {
        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__NoProposal.selector);
        routerAdmin.finalizeRouterConfig();
    }

    function test_OrderRouter_OnlyOwner() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        routerAdmin.proposeRouterConfig(config);
    }

    function test_OrderRouter_InvalidPendingOrderLimit_Reverts() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxPendingOrders = 33;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidPendingOrderLimit.selector);
        routerAdmin.proposeRouterConfig(config);
    }

    function test_OrderRouter_InvalidCloseOrderExecutionBounty_Reverts() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.closeOrderExecutionBountyUsdc = 1_000_001;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidExecutionBounty.selector);
        routerAdmin.proposeRouterConfig(config);
    }

    function test_OrderRouter_InvalidMinEngineGas_Reverts() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.minEngineGas = 99_999;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidGasLimit.selector);
        routerAdmin.proposeRouterConfig(config);

        config = _routerConfig();
        config.minEngineGas = 5_000_001;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidGasLimit.selector);
        routerAdmin.proposeRouterConfig(config);
    }

    function test_OrderRouter_InvalidMaxPruneOrdersPerCall_Reverts() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxPruneOrdersPerCall = 257;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidGasLimit.selector);
        routerAdmin.proposeRouterConfig(config);
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

        address account = alice;
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.98e8);

        router.executeLiquidation(account, pythData);

        (uint256 size,,,,,,) = engine.positions(account);
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
        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__UnauthorizedPauser.selector);
        routerAdmin.pause();
    }

    function test_SetPauser_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        routerAdmin.setPauser(pauser);
    }

    function test_Pauser_CanPauseRouter_ButNotUnpause() public {
        routerAdmin.setPauser(pauser);

        vm.prank(pauser);
        routerAdmin.pause();
        assertTrue(routerAdmin.paused());

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pauser));
        routerAdmin.unpause();
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
        vm.expectRevert(HousePool.HousePool__UnauthorizedPauser.selector);
        pool.pause();
    }

    function test_HousePool_SetPauser_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        pool.setPauser(pauser);
    }

    function test_HousePool_Pauser_CanPause_ButNotUnpause() public {
        pool.setPauser(pauser);

        vm.prank(pauser);
        pool.pause();
        assertTrue(pool.paused());

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pauser));
        pool.unpause();
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
