// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineConfigurationTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_SettlementSidecar_RevertsWhenCalledDirectly() public {
        CfdEngineSettlementSidecar sidecar = CfdEngineSettlementSidecar(address(engine.settlementSidecar()));
        CfdEnginePlanTypes.CloseDelta memory delta;
        CfdTypes.Position memory position;

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeClose(delta, position, uint64(block.timestamp));
    }

    function test_SettlementSidecar_RejectsCanonicalPostOpenSolvencyBreach() public {
        address mockHost = address(0x51DEC4A);
        address mockClearinghouse = address(0xC1EA41);
        address mockPool = address(0xA55001);
        vm.etch(mockHost, hex"00");
        vm.etch(mockClearinghouse, hex"00");
        vm.etch(mockPool, hex"00");

        CfdEngineSettlementSidecar sidecar = new CfdEngineSettlementSidecar(mockHost);
        CfdEnginePlanTypes.OpenDelta memory delta;
        delta.account = address(0xA11CE);
        delta.requiredEffectiveAssetsAfterUsdc = 1;
        CfdTypes.Position memory position;

        vm.mockCall(
            mockHost, abi.encodeWithSelector(bytes4(keccak256("clearinghouse()"))), abi.encode(mockClearinghouse)
        );
        vm.mockCall(mockHost, abi.encodeWithSelector(bytes4(keccak256("pool()"))), abi.encode(mockPool));
        vm.mockCall(mockHost, abi.encodeWithSelector(bytes4(keccak256("protocolTreasury()"))), abi.encode(address(0)));
        vm.mockCall(
            mockHost, abi.encodeWithSelector(bytes4(keccak256("totalTraderClaimBalanceUsdc()"))), abi.encode(uint256(0))
        );

        IMarginClearinghouse.LockedMarginBuckets memory emptyBuckets;
        vm.mockCall(
            mockClearinghouse,
            abi.encodeWithSelector(IMarginClearinghouse.getLockedMarginBuckets.selector, delta.account),
            abi.encode(emptyBuckets)
        );
        vm.mockCall(
            mockClearinghouse,
            abi.encodeWithSelector(IMarginClearinghouse.vpiRebateReserveUsdc.selector, delta.account),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            mockClearinghouse,
            abi.encodeWithSelector(IMarginClearinghouse.applyOpenCost.selector),
            abi.encode(int256(0), uint256(0))
        );
        vm.mockCall(
            mockClearinghouse,
            abi.encodeWithSelector(IMarginClearinghouse.pnlPledgeUsdc.selector, delta.account),
            abi.encode(uint256(0))
        );
        vm.mockCall(mockPool, abi.encodeWithSelector(bytes4(keccak256("totalAssets()"))), abi.encode(uint256(0)));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__PostOpSolvencyBreach.selector);
        vm.prank(mockHost);
        sidecar.executeOpen(delta, position, uint64(block.timestamp));
    }

    function test_SettlementSidecar_RevertsWhenCallerIsNotImmutableEngine() public {
        CfdEngineSettlementSidecar sidecar = CfdEngineSettlementSidecar(address(engine.settlementSidecar()));
        CfdEngine wrongHost =
            new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS);
        CfdEnginePlanTypes.OpenDelta memory openDelta;
        CfdEnginePlanTypes.CloseDelta memory closeDelta;
        CfdEnginePlanTypes.LiquidationDelta memory liquidationDelta;
        CfdTypes.Position memory position;

        vm.startPrank(address(wrongHost));

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeOpen(openDelta, position, uint64(block.timestamp));

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeClose(closeDelta, position, uint64(block.timestamp));

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeLiquidation(liquidationDelta, uint64(block.timestamp), address(this));

        vm.stopPrank();
    }

    function test_SetDependencies_RevertsWhenSettlementSidecarBoundToDifferentEngine() public {
        CfdEngine victim =
            new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar wrongSidecar = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(victim), address(this));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidSettlementSidecar.selector);
        victim.setDependencies(address(planner), address(wrongSidecar), address(adminModule));
    }

    function test_SetDependencies_RevertsWhenSettlementSidecarHasNoEngineBinding() public {
        CfdEngine victim =
            new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(victim), address(this));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidSettlementSidecar.selector);
        victim.setDependencies(address(planner), address(0xBEEF), address(adminModule));
    }

    function test_SetDependencies_RevertsWhenAdminBoundToDifferentEngine() public {
        CfdEngine victim =
            new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(victim));
        CfdEngineAdmin wrongAdmin = new CfdEngineAdmin(address(engine), address(this));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidAdmin.selector);
        victim.setDependencies(address(planner), address(settlement), address(wrongAdmin));
    }

    function test_SetDependencies_RevertsWhenAdminHasNoCode() public {
        CfdEngine victim =
            new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(victim));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidAdmin.selector);
        victim.setDependencies(address(planner), address(settlement), address(0xBEEF));
    }

    function test_Unauthorized_Caller_Reverts() public {
        address account = address(uint160(1));
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });

        vm.prank(address(0xDEAD));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__Unauthorized.selector);
        engine.processOrderTyped(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        vm.prank(address(0xDEAD));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__Unauthorized.selector);
        engine.liquidatePosition(account, 1e8, 1_000_000 * 1e6, uint64(block.timestamp), address(this));
    }

    function test_ProposeRiskParams_RevertsOnZeroMaintMargin() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maintMarginBps = 0;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsOnZeroInitMargin() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 0;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsWhenInitMarginBelowMaint() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = params.maintMarginBps - 1;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsWhenFadMarginBelowMaint() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.fadMarginBps = params.maintMarginBps - 1;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsWhenFadMarginExceeds100Percent() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.fadMarginBps = 10_001;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsOnZeroMinBounty() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.minBountyUsdc = 0;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsOnZeroBountyBps() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.bountyBps = 0;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

}

