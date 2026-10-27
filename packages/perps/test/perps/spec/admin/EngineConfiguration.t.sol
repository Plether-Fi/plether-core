// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdTreasury} from "@plether/perps/CfdTreasury.sol";
import {HousePool} from "@plether/perps/HousePool.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineConfigurationTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_TreasuryLock_ActivatesImmediatelyAndEmitsEvents() public {
        address treasury = address(0xFEE90);
        vm.warp(1_000_000);
        assertEq(engine.protocolTreasuryLockedUntil(), 0);
        vm.expectEmit(true, false, false, true, address(engine));
        emit CfdTreasury.ProtocolTreasuryUpdated(treasury);
        vm.expectEmit(true, false, false, true, address(engine));
        emit CfdTreasury.ProtocolTreasuryLocked(treasury, 8_776_000);
        engine.setProtocolTreasury(treasury, 90 days);
        assertEq(engine.protocolTreasury(), treasury);
        assertEq(engine.protocolTreasuryLockedUntil(), 8_776_000);
    }

    function test_TreasuryLock_BlocksBothSettersAndSameAddressChanges() public {
        address treasury = engine.protocolTreasury();
        engine.setProtocolTreasury(treasury, 90 days);
        uint256 expiry = engine.protocolTreasuryLockedUntil();
        vm.warp(expiry - 1);
        bytes memory reason = abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(address(0xFEE91));
        vm.expectRevert(reason);
        engine.setProtocolTreasury(address(0xFEE91), 30 days);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(treasury);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(treasury, 1);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(treasury, 365 days);
        assertEq(engine.protocolTreasury(), treasury);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
    }

    function test_TreasuryLock_CanRelockAtExactExpiry() public {
        engine.setProtocolTreasury(address(0xFEE90), 90 days);
        uint256 expiry = engine.protocolTreasuryLockedUntil();
        vm.warp(expiry);
        assertEq(engine.protocolTreasury(), address(0xFEE90), "Expiry does not rotate the treasury");
        engine.setProtocolTreasury(address(0xFEE91), 30 days);
        assertEq(engine.protocolTreasury(), address(0xFEE91));
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 30 days);
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry + 30 days));
        engine.setProtocolTreasury(address(0xFEE92));
    }

    function test_TreasuryLock_LegacySetterWorksAtExpiryAndAfterward() public {
        engine.setProtocolTreasury(address(0xFEE90), 90 days);
        uint256 expiry = engine.protocolTreasuryLockedUntil();
        vm.warp(expiry);
        engine.setProtocolTreasury(address(0xFEE91));
        assertEq(engine.protocolTreasury(), address(0xFEE91));
        vm.warp(expiry + 1);
        engine.setProtocolTreasury(address(0xFEE92));
        assertEq(engine.protocolTreasury(), address(0xFEE92));
        assertEq(engine.protocolTreasuryLockedUntil(), expiry, "Legacy setter does not start another lock");
    }

    function test_TreasuryLock_CurrentAddressCanBeLockedAndRelocked() public {
        address treasury = engine.protocolTreasury();
        // Snapshot time through the cheatcode so via-IR cannot recompute it after vm.warp.
        uint256 expiry = vm.getBlockTimestamp() + 90 days;
        vm.expectEmit(true, false, false, true, address(engine));
        emit CfdTreasury.ProtocolTreasuryLocked(treasury, expiry);
        engine.setProtocolTreasury(treasury, 90 days);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        vm.warp(expiry + 1);
        engine.setProtocolTreasury(treasury, 1 days);
        assertEq(engine.protocolTreasury(), treasury);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + 1 + 1 days);
    }

    function test_TreasuryLock_NewOwnerCannotBypassLock() public {
        address treasury = engine.protocolTreasury();
        engine.setProtocolTreasury(treasury, 90 days);
        uint256 expiry = engine.protocolTreasuryLockedUntil();
        address nextOwner = address(0xA11CE);
        engine.transferOwnership(nextOwner);
        vm.startPrank(nextOwner);
        engine.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry));
        engine.setProtocolTreasury(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry));
        engine.setProtocolTreasury(nextOwner, 90 days);
        assertEq(engine.protocolTreasury(), treasury);
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        vm.warp(expiry);
        engine.setProtocolTreasury(nextOwner, 90 days);
        vm.stopPrank();
        assertEq(engine.protocolTreasury(), nextOwner);
    }

    function test_TreasuryLock_RejectsNonOwnerOnBothSetters() public {
        address caller = address(0xA11CE);
        bytes memory reason = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller);
        vm.startPrank(caller);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(caller, 90 days);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(caller);
        vm.stopPrank();
        assertEq(engine.protocolTreasuryLockedUntil(), 0);
    }

    function test_TreasuryLock_InvalidInputsLeaveStateUnchanged() public {
        address treasury = engine.protocolTreasury();
        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAddress.selector);
        engine.setProtocolTreasury(address(0), 90 days);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAddress.selector);
        engine.setProtocolTreasury(address(0));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidTreasuryLockDuration.selector);
        engine.setProtocolTreasury(address(0xFEE90), 0);
        vm.warp(1);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        engine.setProtocolTreasury(address(0xFEE90), type(uint256).max);
        assertEq(engine.protocolTreasury(), treasury);
        assertEq(engine.protocolTreasuryLockedUntil(), 0);
    }

    function testFuzz_TreasuryLock_RejectsChangesThroughoutDuration(
        uint64 start,
        uint64 durationSeed,
        uint256 elapsedSeed
    ) public {
        uint256 duration = bound(uint256(durationSeed), 1, type(uint64).max);
        vm.warp(uint256(start));
        engine.setProtocolTreasury(address(0xFEE90), duration);
        uint256 expiry = uint256(start) + duration;
        vm.warp(uint256(start) + bound(elapsedSeed, 0, duration - 1));
        bytes memory reason = abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TreasuryLocked.selector, expiry);
        vm.expectRevert(reason);
        engine.setProtocolTreasury(address(0xFEE91));
        vm.expectRevert(reason);
        engine.setProtocolTreasury(address(0xFEE91), duration);
        assertEq(engine.protocolTreasury(), address(0xFEE90));
        assertEq(engine.protocolTreasuryLockedUntil(), expiry);
        vm.warp(expiry);
        engine.setProtocolTreasury(address(0xFEE91), duration);
        assertEq(engine.protocolTreasury(), address(0xFEE91));
        assertEq(engine.protocolTreasuryLockedUntil(), expiry + duration);
    }

    function test_ConstructorRejectsMismatchedSettlementAsset() public {
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidSettlementAsset.selector);
        new CfdEngine(address(0xBEEF), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS);
    }

    function test_SetPoolRejectsMismatchedSettlementAsset() public {
        CfdEngine victim = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
        HousePool wrongAssetPool =
            new HousePool(address(0xBEEF), address(victim), address(housePoolRedemptionMathSidecar));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidPool.selector);
        victim.setPool(address(wrongAssetPool));
        assertEq(address(victim.pool()), address(0));
    }

    function test_SetPoolRejectsPoolBoundToAnotherEngine() public {
        CfdEngine victim = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidPool.selector);
        victim.setPool(address(pool));
        assertEq(address(victim.pool()), address(0));
    }

    function test_SetPoolRejectsNonContract() public {
        CfdEngine victim = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidPool.selector);
        victim.setPool(address(0xBEEF));
        assertEq(address(victim.pool()), address(0));
    }

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
        delta.requiredEffectiveAssetsAfterAssets = 1;
        CfdTypes.Position memory position;

        vm.mockCall(
            mockHost, abi.encodeWithSelector(bytes4(keccak256("clearinghouse()"))), abi.encode(mockClearinghouse)
        );
        vm.mockCall(mockHost, abi.encodeWithSelector(bytes4(keccak256("pool()"))), abi.encode(mockPool));
        vm.mockCall(mockHost, abi.encodeWithSelector(bytes4(keccak256("protocolTreasury()"))), abi.encode(address(0)));
        vm.mockCall(
            mockHost,
            abi.encodeWithSelector(bytes4(keccak256("totalTraderClaimBalanceAssets()"))),
            abi.encode(uint256(0))
        );

        IMarginClearinghouse.LockedMarginBuckets memory emptyBuckets;
        vm.mockCall(
            mockClearinghouse,
            abi.encodeWithSelector(IMarginClearinghouse.getLockedMarginBuckets.selector, delta.account),
            abi.encode(emptyBuckets)
        );
        vm.mockCall(
            mockClearinghouse,
            abi.encodeWithSelector(IMarginClearinghouse.vpiRebateReserveAssets.selector, delta.account),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            mockClearinghouse,
            abi.encodeWithSelector(IMarginClearinghouse.applyOpenCost.selector),
            abi.encode(int256(0), uint256(0))
        );
        vm.mockCall(
            mockClearinghouse,
            abi.encodeWithSelector(IMarginClearinghouse.pnlPledgeAssets.selector, delta.account),
            abi.encode(uint256(0))
        );
        vm.mockCall(mockPool, abi.encodeWithSelector(bytes4(keccak256("totalAssets()"))), abi.encode(uint256(0)));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__PostOpSolvencyBreach.selector);
        vm.prank(mockHost);
        sidecar.executeOpen(delta, position, uint64(block.timestamp));
    }

    function test_SettlementSidecar_RevertsWhenCallerIsNotImmutableEngine() public {
        CfdEngineSettlementSidecar sidecar = CfdEngineSettlementSidecar(address(engine.settlementSidecar()));
        CfdEngine wrongHost = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
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
        CfdEngine victim = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar wrongSidecar = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(victim), address(this));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidSettlementSidecar.selector);
        victim.setDependencies(address(planner), address(wrongSidecar), address(adminModule));
    }

    function test_SetDependencies_RevertsWhenSettlementSidecarHasNoEngineBinding() public {
        CfdEngine victim = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(victim), address(this));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidSettlementSidecar.selector);
        victim.setDependencies(address(planner), address(0xBEEF), address(adminModule));
    }

    function test_SetDependencies_RevertsWhenAdminBoundToDifferentEngine() public {
        CfdEngine victim = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(victim));
        CfdEngineAdmin wrongAdmin = new CfdEngineAdmin(address(engine), address(this));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidAdmin.selector);
        victim.setDependencies(address(planner), address(settlement), address(wrongAdmin));
    }

    function test_SetDependencies_RevertsWhenAdminHasNoCode() public {
        CfdEngine victim = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
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
        params.minBountyAssets = 0;
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
