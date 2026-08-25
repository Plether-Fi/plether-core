// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {Test} from "forge-std/Test.sol";

contract ConfigVersionEngineHostMock is ICfdEngineAdminHost {

    error ApplyFailed();

    bool public shouldRevert;
    uint256 public riskApplyCount;
    uint256 public calendarApplyCount;
    uint256 public freshnessApplyCount;

    function setShouldRevert(
        bool value
    ) external {
        shouldRevert = value;
    }

    function applyRiskConfig(
        EngineRiskConfig calldata
    ) external {
        _requireSuccess();
        riskApplyCount += 1;
    }

    function applyCalendarConfig(
        EngineCalendarConfig calldata
    ) external {
        _requireSuccess();
        calendarApplyCount += 1;
    }

    function applyFreshnessConfig(
        EngineFreshnessConfig calldata
    ) external {
        _requireSuccess();
        freshnessApplyCount += 1;
    }

    function _requireSuccess() private view {
        if (shouldRevert) {
            revert ApplyFailed();
        }
    }

}

contract ConfigVersionRouterHostMock is IOrderRouterAdminHost {

    error ApplyFailed();

    bool public shouldRevert;
    uint64 public nextCommitId = 1;
    uint256 public routerApplyCount;
    uint256 public oracleApplyCount;

    function setShouldRevert(
        bool value
    ) external {
        shouldRevert = value;
    }

    function setNextCommitId(
        uint64 value
    ) external {
        nextCommitId = value;
    }

    function applyRouterConfig(
        RouterConfig calldata
    ) external {
        _requireSuccess();
        routerApplyCount += 1;
    }

    function applyOracleConfig(
        OracleConfig calldata
    ) external {
        _requireSuccess();
        oracleApplyCount += 1;
    }

    function _requireSuccess() private view {
        if (shouldRevert) {
            revert ApplyFailed();
        }
    }

}

contract AdminConfigVersionTest is Test {

    ConfigVersionEngineHostMock private engineHost;
    ConfigVersionRouterHostMock private routerHost;
    CfdEngineAdmin private engineAdmin;
    OrderRouterAdmin private routerAdmin;

    function setUp() public {
        engineHost = new ConfigVersionEngineHostMock();
        routerHost = new ConfigVersionRouterHostMock();
        engineAdmin = new CfdEngineAdmin(address(engineHost), address(this));
        routerAdmin = new OrderRouterAdmin(address(routerHost), address(this));
    }

    function test_ConfigVersions_StartAtOne() public view {
        assertEq(engineAdmin.activeConfigVersion(), 1);
        assertEq(routerAdmin.activeConfigVersion(), 1);
    }

    function test_EngineConfigVersion_AdvancesForEverySuccessfulFinalizationIncludingIdenticalConfigs() public {
        ICfdEngineAdminHost.EngineRiskConfig memory riskConfig = _riskConfig();
        _finalizeRiskConfig(riskConfig);
        assertEq(engineAdmin.activeConfigVersion(), 2);

        _finalizeRiskConfig(riskConfig);
        assertEq(engineAdmin.activeConfigVersion(), 3);

        ICfdEngineAdminHost.EngineCalendarConfig memory calendarConfig;
        calendarConfig.fadDayTimestamps = new uint256[](0);
        calendarConfig.fadRunwaySeconds = 0;
        engineAdmin.proposeCalendarConfig(calendarConfig);
        _elapseTimelock();
        engineAdmin.finalizeCalendarConfig();
        assertEq(engineAdmin.activeConfigVersion(), 4);

        ICfdEngineAdminHost.EngineFreshnessConfig memory freshnessConfig =
            ICfdEngineAdminHost.EngineFreshnessConfig({fadMaxStaleness: 1, engineMarkStalenessLimit: 1});
        engineAdmin.proposeFreshnessConfig(freshnessConfig);
        _elapseTimelock();
        engineAdmin.finalizeFreshnessConfig();
        assertEq(engineAdmin.activeConfigVersion(), 5);

        assertEq(engineHost.riskApplyCount(), 2);
        assertEq(engineHost.calendarApplyCount(), 1);
        assertEq(engineHost.freshnessApplyCount(), 1);
    }

    function test_RouterConfigVersion_AdvancesForEverySuccessfulFinalizationIncludingIdenticalConfigs() public {
        IOrderRouterAdminHost.RouterConfig memory routerConfig = _routerConfig();
        _finalizeRouterConfig(routerConfig);
        assertEq(routerAdmin.activeConfigVersion(), 2);

        _finalizeRouterConfig(routerConfig);
        assertEq(routerAdmin.activeConfigVersion(), 3);

        IOrderRouterAdminHost.OracleConfig memory oracleConfig =
            IOrderRouterAdminHost.OracleConfig({pletherOracle: address(engineHost)});
        _finalizeOracleConfig(oracleConfig);
        assertEq(routerAdmin.activeConfigVersion(), 4);

        _finalizeOracleConfig(oracleConfig);
        assertEq(routerAdmin.activeConfigVersion(), 5);

        assertEq(routerHost.routerApplyCount(), 2);
        assertEq(routerHost.oracleApplyCount(), 2);
    }

    function test_ProposalsCancellationsAndEmergencyPause_DoNotAdvanceVersions() public {
        engineAdmin.proposeRiskConfig(_riskConfig());
        engineAdmin.cancelRiskConfig();
        assertEq(engineAdmin.activeConfigVersion(), 1);

        routerAdmin.proposeRouterConfig(_routerConfig());
        routerAdmin.cancelRouterConfig();
        assertEq(routerAdmin.activeConfigVersion(), 1);

        routerHost.setNextCommitId(9);
        routerAdmin.pause();
        assertTrue(routerAdmin.paused());
        assertEq(routerAdmin.riskOffOrderCutoff(), 8);
        assertEq(routerAdmin.activeConfigVersion(), 1);

        routerAdmin.unpause();
        assertFalse(routerAdmin.paused());
        assertEq(routerAdmin.riskOffOrderCutoff(), 8);
        assertEq(routerAdmin.activeConfigVersion(), 1);
    }

    function test_FailedEngineFinalization_DoesNotAdvanceVersionOrConsumeProposal() public {
        engineAdmin.proposeRiskConfig(_riskConfig());
        uint256 activationTime = engineAdmin.riskConfigActivationTime();
        _elapseTimelock();
        engineHost.setShouldRevert(true);

        vm.expectRevert(ConfigVersionEngineHostMock.ApplyFailed.selector);
        engineAdmin.finalizeRiskConfig();

        assertEq(engineAdmin.activeConfigVersion(), 1);
        assertEq(engineAdmin.riskConfigActivationTime(), activationTime);
        assertEq(engineHost.riskApplyCount(), 0);
    }

    function test_FailedRouterFinalization_DoesNotAdvanceVersionOrConsumeProposal() public {
        routerAdmin.proposeRouterConfig(_routerConfig());
        uint256 activationTime = routerAdmin.routerConfigActivationTime();
        _elapseTimelock();
        routerHost.setShouldRevert(true);

        vm.expectRevert(ConfigVersionRouterHostMock.ApplyFailed.selector);
        routerAdmin.finalizeRouterConfig();

        assertEq(routerAdmin.activeConfigVersion(), 1);
        assertEq(routerAdmin.routerConfigActivationTime(), activationTime);
        assertEq(routerHost.routerApplyCount(), 0);
    }

    function _finalizeRiskConfig(
        ICfdEngineAdminHost.EngineRiskConfig memory config
    ) private {
        engineAdmin.proposeRiskConfig(config);
        _elapseTimelock();
        engineAdmin.finalizeRiskConfig();
    }

    function _finalizeRouterConfig(
        IOrderRouterAdminHost.RouterConfig memory config
    ) private {
        routerAdmin.proposeRouterConfig(config);
        _elapseTimelock();
        routerAdmin.finalizeRouterConfig();
    }

    function _finalizeOracleConfig(
        IOrderRouterAdminHost.OracleConfig memory config
    ) private {
        routerAdmin.proposeOracleConfig(config);
        _elapseTimelock();
        routerAdmin.finalizeOracleConfig();
    }

    function _elapseTimelock() private {
        vm.warp(block.timestamp + 48 hours);
    }

    function _riskConfig() private pure returns (ICfdEngineAdminHost.EngineRiskConfig memory config) {
        config.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0,
            maintMarginBps: 100,
            initMarginBps: 200,
            fadMarginBps: 300,
            baseCarryBps: 0,
            minBountyUsdc: 1,
            bountyBps: 1,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
        config.executionFeeBps = 1;
        config.frozenCloseSpreadBps = 1;
    }

    function _routerConfig() private pure returns (IOrderRouterAdminHost.RouterConfig memory config) {
        config.maxOrderAge = 60;
        config.orderExecutionStalenessLimit = 60;
        config.liquidationStalenessLimit = 60;
        config.basketMaxConfidenceRatioBps = 100;
        config.orderSettlementWindow = 30;
        config.maxComponentPublishTimeDivergence = 10;
        config.adverseConfidenceMultiplierBps = 10_000;
        config.minOpenNotionalUsdc = 1;
        config.openOrderExecutionBountyBps = 1;
        config.minOpenOrderExecutionBountyUsdc = 1;
        config.maxOpenOrderExecutionBountyUsdc = 1;
        config.closeOrderExecutionBountyUsdc = 1;
        config.positionProtectionCommitsEnabled = false;
        config.positionProtectionTriggerBountyUsdc = 1;
        config.maxPendingOrders = 1;
        config.minEngineGas = 100_000;
        config.maxPruneOrdersPerCall = 1;
    }

}
