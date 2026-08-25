// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {OrderExecutionSettlement} from "@plether/perps/router/OrderExecutionSettlement.sol";

contract TimelockPauseTest is BasePerpTest {

    event RiskConfigCancelled();
    event Paused(address account);
    event RiskOffActivated(uint64 previousCutoff, uint64 newCutoff);
    event OrderFailed(uint64 indexed orderId, OrderExecutionSettlement.OrderFailReason reason);
    event LpEpochSettlementPauseUpdated(address indexed caller, bool paused);

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

    function test_FrozenCloseSpread_UsesConstructorConfiguredWeekendProtectionValue() public view {
        assertEq(engine.frozenCloseSpreadBps(), 50);
    }

    function test_CfdEngineConstructor_RevertsWhenFrozenCloseSpreadIsZero() public {
        CfdTypes.RiskParams memory params = _riskParams();

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidRiskParams.selector);
        new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 0);
    }

    function test_CfdEngineConstructor_RevertsWhenFrozenCloseSpreadExceedsMaximum() public {
        CfdTypes.RiskParams memory params = _riskParams();

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidRiskParams.selector);
        new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 1001);
    }

    function test_CfdEngineConstructor_AcceptsFrozenCloseSpreadBoundsIndependentOfVpiFactor() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 1e18;

        CfdEngine minSpreadEngine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 1);
        CfdEngine maxSpreadEngine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 1000);

        assertEq(minSpreadEngine.frozenCloseSpreadBps(), 1);
        assertEq(maxSpreadEngine.frozenCloseSpreadBps(), 1000);
    }

    function test_CfdEngineConstructor_RevertsWhenKeeperShareExceedsBpsDenominator() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.keeperShareBps = 10_001;

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidRiskParams.selector);
        new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 50);
    }

    function test_CfdEngineConstructor_RevertsWhenLiquidationSharesExceedBpsDenominator() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.protocolShareBps = 5001;

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidRiskParams.selector);
        new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 50);
    }

    function test_LiquidationShares_ChangeOnlyAfterRiskConfigTimelock() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        assertEq(config.riskParams.keeperShareBps, 5000, "Default keeper share should be 50%");
        assertEq(config.riskParams.protocolShareBps, 0, "Protocol liquidation fee should default to zero");
        config.riskParams.keeperShareBps = 2500;
        config.riskParams.protocolShareBps = 2500;

        engineAdmin.proposeRiskConfig(config);
        (,,,,,,,, uint256 keeperShareBefore, uint256 protocolShareBefore) = engine.riskParams();
        assertEq(keeperShareBefore, 5000, "Proposal must not change the live keeper share");
        assertEq(protocolShareBefore, 0, "Proposal must not change the live protocol share");

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__TimelockNotReady.selector);
        engineAdmin.finalizeRiskConfig();

        _warpForward(48 hours + 1);
        engineAdmin.finalizeRiskConfig();

        (,,,,,,,, uint256 keeperShareAfter, uint256 protocolShareAfter) = engine.riskParams();
        assertEq(keeperShareAfter, 2500, "Finalization should apply the configured keeper share");
        assertEq(protocolShareAfter, 2500, "Finalization should apply the configured protocol share");
    }

    function test_ProposeRiskConfig_RevertsWhenKeeperShareExceedsBpsDenominator() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.riskParams.keeperShareBps = 10_001;

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskConfig_RevertsWhenLiquidationSharesExceedBpsDenominator() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.riskParams.protocolShareBps = 5001;

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);

        config.riskParams.protocolShareBps = type(uint256).max;
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskConfig_AcceptsLiquidationShareBoundaries() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.riskParams.keeperShareBps = 0;
        config.riskParams.protocolShareBps = 10_000;
        engineAdmin.proposeRiskConfig(config);

        config.riskParams.keeperShareBps = 10_000;
        config.riskParams.protocolShareBps = 0;
        engineAdmin.proposeRiskConfig(config);

        config.riskParams.keeperShareBps = 5000;
        config.riskParams.protocolShareBps = 5000;
        engineAdmin.proposeRiskConfig(config);

        assertGt(engineAdmin.riskConfigActivationTime(), block.timestamp);
    }

    function test_ProposeRiskParams_StoresAndSetsActivationTime() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            maintMarginBps: 200,
            initMarginBps: ((200) * 15) / 10,
            fadMarginBps: 500,
            baseCarryBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = 7;
        config.frozenCloseSpreadBps = 70;
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
            bountyBps: 20,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = 7;
        config.frozenCloseSpreadBps = 70;
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
            bountyBps: 20,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = 7;
        config.frozenCloseSpreadBps = 70;
        engineAdmin.proposeRiskConfig(config);
        _warpForward(48 hours + 1);
        engineAdmin.finalizeRiskConfig();

        (,, uint256 maintMarginBps,,,,,,,) = engine.riskParams();
        assertEq(maintMarginBps, 200);
        assertEq(engine.executionFeeBps(), 7);
        assertEq(engine.frozenCloseSpreadBps(), 70);
        assertEq(engineAdmin.riskConfigActivationTime(), 0);
    }

    function test_FinalizeRiskParams_NoProposal_Reverts() public {
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__NoProposal.selector);
        engineAdmin.finalizeRiskConfig();
    }

    function test_ProposeRiskConfig_RevertsWhenFrozenCloseSpreadIsZero() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.frozenCloseSpreadBps = 0;

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskConfig_RevertsWhenFrozenCloseSpreadExceedsMaximum() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.frozenCloseSpreadBps = 1001;

        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskConfig_AcceptsFrozenCloseSpreadBoundsIndependentOfVpiFactor() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.riskParams.vpiFactor = 1e18;
        config.frozenCloseSpreadBps = 1;
        engineAdmin.proposeRiskConfig(config);

        config.frozenCloseSpreadBps = 1000;
        engineAdmin.proposeRiskConfig(config);

        assertGt(engineAdmin.riskConfigActivationTime(), block.timestamp);
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
            bountyBps: 20,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = 70;
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
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        engineAdmin.proposeRiskConfig(config);
    }

    function test_CfdEngineAdmin_OwnershipTransferRequiresPendingOwnerAcceptance() public {
        engineAdmin.transferOwnership(alice);

        assertEq(engineAdmin.owner(), address(this));
        assertEq(engineAdmin.pendingOwner(), alice);

        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        engineAdmin.proposeRiskConfig(config);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        engineAdmin.cancelRiskConfig();

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        engineAdmin.acceptOwnership();

        vm.prank(alice);
        engineAdmin.acceptOwnership();

        assertEq(engineAdmin.owner(), alice);
        assertEq(engineAdmin.pendingOwner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        engineAdmin.cancelRiskConfig();

        vm.prank(alice);
        engineAdmin.cancelRiskConfig();
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
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        ICfdEngineAdminHost.EngineRiskConfig memory firstConfig;
        firstConfig.riskParams = first;
        firstConfig.executionFeeBps = engine.executionFeeBps();
        firstConfig.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
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
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        ICfdEngineAdminHost.EngineRiskConfig memory secondConfig;
        secondConfig.riskParams = second;
        secondConfig.executionFeeBps = engine.executionFeeBps();
        secondConfig.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        engineAdmin.proposeRiskConfig(secondConfig);
        uint256 secondActivation = engineAdmin.riskConfigActivationTime();

        assertGt(secondActivation, firstActivation);
    }

    // ==========================================
    // HousePool TIMELOCK TESTS
    // ==========================================

    function test_ProposePoolConfig_TimelockFlow() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1200;
        pool.proposePoolConfig(config);
        assertGt(pool.poolConfigActivationTime(), 0);

        vm.expectRevert(IHousePool.HousePool__TimelockNotReady.selector);
        pool.finalizePoolConfig();

        _warpForward(48 hours + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        assertEq(pool.seniorRateBps(), 1200);
        assertEq(pool.poolConfigActivationTime(), 0);
    }

    function test_ProposePoolConfig_TimelockFlow_ForMarkStalenessLimit() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.markStalenessLimit = 60;
        pool.proposePoolConfig(config);
        assertGt(pool.poolConfigActivationTime(), 0);

        vm.expectRevert(IHousePool.HousePool__TimelockNotReady.selector);
        pool.finalizePoolConfig();

        _warpForward(48 hours + 1);
        pool.finalizePoolConfig();

        assertEq(pool.markStalenessLimit(), 60);
        assertEq(pool.poolConfigActivationTime(), 0);
    }

    function test_FinalizePoolConfig_NoProposal_Reverts() public {
        vm.expectRevert(IHousePool.HousePool__NoProposal.selector);
        pool.finalizePoolConfig();
    }

    function test_CancelPoolConfig_ClearsPending() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1500;
        pool.proposePoolConfig(config);
        pool.cancelPoolConfigProposal();
        assertEq(pool.poolConfigActivationTime(), 0);
    }

    function test_ProposePoolConfig_TimelockFlow_ForFrozenLpFees() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 40;
        config.juniorFrozenLpFeeBps = 90;
        pool.proposePoolConfig(config);
        assertGt(pool.poolConfigActivationTime(), 0);

        vm.expectRevert(IHousePool.HousePool__TimelockNotReady.selector);
        pool.finalizePoolConfig();

        _warpForward(48 hours + 1);
        pool.finalizePoolConfig();

        assertEq(pool.seniorFrozenLpFeeBps(), 40);
        assertEq(pool.juniorFrozenLpFeeBps(), 90);
        assertEq(pool.poolConfigActivationTime(), 0);
    }

    function test_CancelPoolConfig_ZeroesPendingStruct() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 40;
        config.juniorFrozenLpFeeBps = 90;
        pool.proposePoolConfig(config);
        pool.cancelPoolConfigProposal();
        assertEq(pool.poolConfigActivationTime(), 0);
        (
            uint256 pendingSeniorRate,
            uint256 pendingMarkStaleness,
            uint256 pendingSeniorFrozenFee,
            uint256 pendingJuniorFrozenFee,
            uint256 pendingMaxSeniorExposure,
            uint256 pendingMaxSeniorShareBps
        ) = pool.pendingPoolConfig();
        assertEq(pendingSeniorRate, 0);
        assertEq(pendingMarkStaleness, 0);
        assertEq(pendingSeniorFrozenFee, 0);
        assertEq(pendingJuniorFrozenFee, 0);
        assertEq(pendingMaxSeniorExposure, 0);
        assertEq(pendingMaxSeniorShareBps, 0);
    }

    function test_ProposePoolConfig_RevertsForInvalidFrozenLpFees() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorFrozenLpFeeBps = 1001;
        vm.expectRevert(IHousePool.HousePool__InvalidFrozenLpFee.selector);
        pool.proposePoolConfig(config);

        config = _currentPoolConfig();
        config.juniorFrozenLpFeeBps = 1001;
        vm.expectRevert(IHousePool.HousePool__InvalidFrozenLpFee.selector);
        pool.proposePoolConfig(config);
    }

    // ==========================================
    // OrderRouter TIMELOCK TESTS
    // ==========================================

    function test_ProposeMaxOrderAge_TimelockFlow() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 600;
        config.minOpenNotionalUsdc = 150e6;
        config.openOrderExecutionBountyBps = 2;
        config.minOpenOrderExecutionBountyUsdc = 200_000;
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
        assertEq(router.minOpenNotionalUsdc(), 150e6);
        assertEq(router.openOrderExecutionBountyBps(), 2);
        assertEq(router.minOpenOrderExecutionBountyUsdc(), 200_000);
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

    function test_OrderRouterAdmin_OwnershipTransferRequiresPendingOwnerAcceptance() public {
        routerAdmin.transferOwnership(alice);

        assertEq(routerAdmin.owner(), address(this));
        assertEq(routerAdmin.pendingOwner(), alice);

        routerAdmin.setPauser(pauser);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        routerAdmin.setPauser(nonOwner);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        routerAdmin.acceptOwnership();

        vm.prank(alice);
        routerAdmin.acceptOwnership();

        assertEq(routerAdmin.owner(), alice);
        assertEq(routerAdmin.pendingOwner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        routerAdmin.setPauser(nonOwner);

        vm.prank(alice);
        routerAdmin.setPauser(nonOwner);
        assertEq(routerAdmin.pauser(), nonOwner);
    }

    function test_OrderRouter_InvalidPendingOrderLimit_Reverts() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxPendingOrders = 33;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidPendingOrderLimit.selector);
        routerAdmin.proposeRouterConfig(config);
    }

    function test_OrderRouter_InvalidBasketConfidenceRatio_Reverts() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.basketMaxConfidenceRatioBps = 10_001;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidConfidenceRatio.selector);
        routerAdmin.proposeRouterConfig(config);
    }

    function test_OrderRouter_InvalidMaxOrderAge_Reverts() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 0;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidMaxOrderAge.selector);
        routerAdmin.proposeRouterConfig(config);

        config = _routerConfig();
        config.maxOrderAge = 1 hours + 1;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidMaxOrderAge.selector);
        routerAdmin.proposeRouterConfig(config);
    }

    function test_OrderRouter_InvalidOracleConfig_Reverts() public {
        IOrderRouterAdminHost.OracleConfig memory config;

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__InvalidOracleConfig.selector);
        routerAdmin.proposeOracleConfig(config);
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

    function test_ExecuteOrder_RefundsPrePauseOpenWithoutOracleWhenPaused() public {
        uint256 traderFreeSettlementBefore = _freeSettlementUsdc(alice);
        uint256 executorSettlementBefore = _settlementBalance(address(this));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        routerAdmin.pause();

        vm.expectEmit(address(router));
        emit OrderFailed(1, OrderExecutionSettlement.OrderFailReason.RiskOff);
        router.executeOrder(1, new bytes[](0));

        assertEq(router.nextExecuteId(), 0);
        assertEq(
            uint256(_orderRecord(1).status),
            uint256(IOrderRouterAccounting.OrderStatus.Failed),
            "risk-off open should become terminally failed"
        );
        assertEq(_freeSettlementUsdc(alice), traderFreeSettlementBefore, "trader should receive margin and bounty");
        assertEq(_settlementBalance(address(this)), executorSettlementBefore, "executor should receive no bounty");
        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 0, "risk-off open must never reach the engine");
    }

    function test_ExecuteLiquidation_WorksWhenPaused() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);

        router.executeOrder(1, _mockPythUpdateData());

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

    function test_Pause_SnapshotsInclusiveRiskOffCutoff() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.expectEmit(address(routerAdmin));
        emit Paused(address(this));
        vm.expectEmit(address(routerAdmin));
        emit RiskOffActivated(0, 1);
        routerAdmin.pause();

        assertEq(router.nextCommitId(), 2);
        assertEq(routerAdmin.riskOffOrderCutoff(), 1);
    }

    function test_Pause_EmptyQueueReaffirmsZeroRiskOffCutoff() public {
        vm.expectEmit(address(routerAdmin));
        emit Paused(address(this));
        vm.expectEmit(address(routerAdmin));
        emit RiskOffActivated(0, 0);
        routerAdmin.pause();

        assertEq(router.nextCommitId(), 1);
        assertEq(routerAdmin.riskOffOrderCutoff(), 0);
    }

    function test_Unpause_DoesNotClearRiskOffCutoff() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        routerAdmin.pause();
        routerAdmin.unpause();

        assertFalse(routerAdmin.paused());
        assertEq(routerAdmin.riskOffOrderCutoff(), 1);
    }

    function test_Pause_RiskOffCutoffIsMonotonicAcrossPauseCycles() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        routerAdmin.pause();
        assertEq(routerAdmin.riskOffOrderCutoff(), 1);

        routerAdmin.unpause();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.expectEmit(address(routerAdmin));
        emit Paused(address(this));
        vm.expectEmit(address(routerAdmin));
        emit RiskOffActivated(1, 2);
        routerAdmin.pause();

        assertEq(routerAdmin.riskOffOrderCutoff(), 2);

        routerAdmin.unpause();
        vm.expectEmit(address(routerAdmin));
        emit Paused(address(this));
        vm.expectEmit(address(routerAdmin));
        emit RiskOffActivated(2, 2);
        routerAdmin.pause();
        assertEq(routerAdmin.riskOffOrderCutoff(), 2);
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
        assertEq(seniorVault.maxRequestDeposit(alice), 0, "paused pool should zero senior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(10_000 * 1e6, alice, alice);
        vm.stopPrank();
    }

    function test_DepositJunior_RevertsWhenHousePoolPaused() public {
        pool.pause();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 10_000 * 1e6);
        assertEq(juniorVault.maxRequestDeposit(alice), 0, "paused pool should zero junior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        juniorVault.requestDeposit(10_000 * 1e6, alice, alice);
        vm.stopPrank();
    }

    function test_WithdrawSenior_WorksWhenHousePoolPaused() public {
        _warpForward(1 hours);
        pool.pause();

        _withdrawTrancheWhileHousePoolPaused(seniorVault);
    }

    function test_WithdrawJunior_WorksWhenHousePoolPaused() public {
        _warpForward(1 hours);
        pool.pause();

        _withdrawTrancheWhileHousePoolPaused(juniorVault);
    }

    function test_HousePool_Pause_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(IHousePool.HousePool__UnauthorizedPauser.selector);
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
        assertEq(juniorVault.maxRequestDeposit(alice), 0, "paused pool should zero junior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        juniorVault.requestDeposit(10_000 * 1e6, alice, alice);
        vm.stopPrank();

        pool.unpause();

        vm.prank(alice);
        uint256 requestId = juniorVault.requestDeposit(10_000 * 1e6, alice, alice);
        _settleLpEpochAt(requestId);

        uint256 claimableAssets = juniorVault.claimableDepositRequest(requestId, alice);
        assertEq(claimableAssets, 10_000 * 1e6, "unpaused deposit request should become claimable");
        vm.prank(alice);
        juniorVault.deposit(claimableAssets, alice);
        assertGt(juniorVault.balanceOf(alice), 0);
    }

    function test_HousePool_SettlementHold_PauserCanActivateButOnlyOwnerCanRelease() public {
        vm.prank(nonOwner);
        vm.expectRevert(IHousePool.HousePool__UnauthorizedPauser.selector);
        pool.pauseLpEpochSettlement();

        pool.setPauser(pauser);
        vm.expectEmit(true, false, false, true);
        emit LpEpochSettlementPauseUpdated(pauser, true);
        vm.prank(pauser);
        pool.pauseLpEpochSettlement();
        assertTrue(pool.lpEpochSettlementPaused());

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pauser));
        pool.unpauseLpEpochSettlement();

        vm.expectRevert(IHousePool.HousePool__LpEpochSettlementPaused.selector);
        pool.pauseLpEpochSettlement();

        vm.expectEmit(true, false, false, true);
        emit LpEpochSettlementPauseUpdated(address(this), false);
        pool.unpauseLpEpochSettlement();
        assertFalse(pool.lpEpochSettlementPaused());

        vm.expectRevert(IHousePool.HousePool__LpEpochSettlementNotPaused.selector);
        pool.unpauseLpEpochSettlement();
    }

    function test_HousePool_EntryPauseAndSettlementHoldAreIndependent() public {
        pool.pause();
        assertTrue(pool.paused());
        assertFalse(pool.lpEpochSettlementPaused());

        pool.pauseLpEpochSettlement();
        assertTrue(pool.paused());
        assertTrue(pool.lpEpochSettlementPaused());

        pool.unpause();
        assertFalse(pool.paused(), "entry pause recovery must not remain active");
        assertTrue(pool.lpEpochSettlementPaused(), "entry pause recovery must not release settlement");

        pool.pause();
        pool.unpauseLpEpochSettlement();
        assertTrue(pool.paused(), "settlement recovery must not reopen LP entry");
        assertFalse(pool.lpEpochSettlementPaused());
    }

    function test_HousePool_SettlementHoldAllowsNewRequestsAndTheirExistingCancellationRules() public {
        pool.pauseLpEpochSettlement();
        assertFalse(pool.paused(), "settlement-only hold must not engage entry pause");

        uint256 depositAssets = 10_000e6;
        usdc.mint(alice, depositAssets);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), depositAssets);
        assertGe(juniorVault.maxRequestDeposit(alice), depositAssets, "settlement hold must retain request capacity");
        uint256 depositId = juniorVault.requestDeposit(depositAssets, alice, alice);
        assertEq(juniorVault.cancelPendingDeposit(depositId), depositAssets);
        vm.stopPrank();

        uint256 redeemCapacity = juniorVault.maxRequestRedeem(address(this));
        assertGt(redeemCapacity, 0, "settlement hold must retain redemption request capacity");
        uint256 redeemShares = redeemCapacity / 10;
        uint256 redeemId = juniorVault.requestRedeem(redeemShares, address(this), address(this));
        assertEq(juniorVault.cancelRedeemRequest(redeemId, address(this)), redeemShares);

        assertEq(juniorVault.pendingDepositRequest(depositId, alice), 0);
        assertEq(juniorVault.pendingRedeemRequest(redeemId, address(this)), 0);
    }

    function test_HousePool_SettlementHoldLeavesAlreadyFundedClaimsLive() public {
        uint256 redeemCapacity = juniorVault.maxRequestRedeem(address(this));
        assertGt(redeemCapacity, 0);
        uint256 redeemShares = redeemCapacity / 10;
        uint256 redeemId = juniorVault.requestRedeem(redeemShares, address(this), address(this));

        uint256 depositAssets = 10_000e6;
        usdc.mint(alice, depositAssets);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), depositAssets);
        uint256 depositId = juniorVault.requestDeposit(depositAssets, alice, alice);
        vm.stopPrank();
        assertEq(depositId, redeemId, "fixture must fund entry and exit in one epoch");

        _settleLpEpochAt(depositId);
        uint256 claimableShares = juniorVault.claimableDepositRequest(depositId, alice);
        uint256 claimableAssets = juniorVault.claimableRedeemAssets(redeemId, address(this));
        assertEq(claimableShares, depositAssets);
        assertGt(claimableAssets, 0);

        pool.pauseLpEpochSettlement();

        vm.prank(alice);
        uint256 mintedShares = juniorVault.deposit(claimableShares, alice);
        assertGt(mintedShares, 0, "funded deposit claim must remain callable");

        uint256 balanceBefore = usdc.balanceOf(address(this));
        uint256 consumedShares = juniorVault.withdraw(claimableAssets, address(this), address(this));
        assertEq(consumedShares, redeemShares, "funded redemption must consume the reserved shares");
        assertEq(
            usdc.balanceOf(address(this)), balanceBefore + claimableAssets, "funded redemption must remain payable"
        );
    }

    function test_HousePool_SettlementHoldLeavesOpenCloseAndMarkRefreshLive() public {
        pool.pauseLpEpochSettlement();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());
        (uint256 sizeAfterOpen,,,,,,) = engine.positions(alice);
        assertEq(sizeAfterOpen, 10_000e18, "settlement hold must not block new trading risk");

        router.updateMarkPrice(_mockPythUpdateData(1.05e8));
        assertEq(engine.lastMarkPrice(), 1.05e8, "settlement hold must not block mark refresh");

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, sizeAfterOpen, 0, 0, true);
        router.executeOrder(2, _mockPythUpdateData(1.05e8));
        (uint256 sizeAfterClose,,,,,,) = engine.positions(alice);
        assertEq(sizeAfterClose, 0, "settlement hold must never block a trader close");
    }

    function test_HousePool_SettlementHoldLeavesLiquidationLive() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        pool.pauseLpEpochSettlement();
        router.executeLiquidation(alice, _mockPythUpdateData(1.98e8));

        (uint256 sizeAfter,,,,,,) = engine.positions(alice);
        assertEq(sizeAfter, 0, "settlement hold must retain permissionless liquidation");
    }

    function _withdrawTrancheWhileHousePoolPaused(
        TrancheVault vault
    ) internal {
        uint256 requestCapacity = vault.maxRequestRedeem(address(this));
        assertGt(requestCapacity, 0, "paused pool should retain redeem request capacity");

        uint256 requestedShares = requestCapacity / 10;
        uint256 requestId = vault.requestRedeem(requestedShares, address(this), address(this));
        assertEq(vault.maxWithdraw(address(this)), 0, "withdraw limit should remain zero before settlement");

        _settleLpEpochAt(requestId);

        uint256 claimableAssets = vault.claimableRedeemAssets(requestId, address(this));
        assertGt(claimableAssets, 0, "paused settlement should fund the redeem request");
        assertEq(
            vault.maxWithdraw(address(this)), claimableAssets, "funded assets should remain claimable while paused"
        );

        uint256 balanceBefore = usdc.balanceOf(address(this));
        uint256 consumedShares = vault.withdraw(claimableAssets, address(this), address(this));
        assertEq(consumedShares, requestedShares, "withdraw claim should consume the requested shares");
        assertEq(
            usdc.balanceOf(address(this)),
            balanceBefore + claimableAssets,
            "withdraw claim should pay assets while the pool is paused"
        );
    }

    function _settleLpEpochAt(
        uint256 epochId
    ) internal {
        uint256 activationTime = pool.lpEpochStart(epochId);
        if (block.timestamp < activationTime) {
            vm.warp(activationTime);
        }
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
        _settleLpEpochForTest();
    }

}
