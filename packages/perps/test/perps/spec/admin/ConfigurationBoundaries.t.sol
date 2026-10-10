// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/SECURITY.md#timelocked-admin-state

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract RiskRatioValidationTest is BasePerpTest {

    /// @dev spec; source: SECURITY.md#timelocked-admin-state.
    function test_ProposeRiskParamsRejectsMaxSkewRatioAboveOne() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maxSkewRatio = 1e18 + 1;
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

}

contract ImmutableRouterBindingTest is BasePerpTest {

    /// @dev spec; source: SECURITY.md#timelocked-admin-state.
    function test_EngineRouterBindingCannotBeReassigned() public {
        vm.expectRevert(ICfdEngineTypes.CfdEngine__RouterAlreadySet.selector);
        engine.setOrderRouter(address(0x123));
    }

}
