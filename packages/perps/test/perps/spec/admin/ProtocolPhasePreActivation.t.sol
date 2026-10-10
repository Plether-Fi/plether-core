// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";

contract ProtocolPhasePreActivationTest is BasePerpTest {

    function _autoActivateTrading() internal pure override returns (bool) {
        return false;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_PhaseRemainsConfiguringUntilTradingActivation() public {
        assertTrue(pool.isSeedLifecycleComplete(), "setup should finish seed lifecycle");
        assertFalse(pool.isTradingActive(), "setup should leave trading inactive");
        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Configuring),
            "Configured but inactive trading should still report Configuring"
        );

        pool.activateTrading();

        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Active),
            "Trading activation should unlock Active phase"
        );
    }

}
