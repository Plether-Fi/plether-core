// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {EmergencyPauseCoordinatorTestFixture} from "../shared/EmergencyPauseCoordinatorFixture.sol";

contract EmergencyPauseCoordinatorGasTest is EmergencyPauseCoordinatorTestFixture {

    function test_SettlementHoldGasIsBounded() public {
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        uint256 gasBefore = gasleft();
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);
        uint256 gasUsed = gasBefore - gasleft();

        assertLe(gasUsed, 100_000);
    }

    function test_FullContainmentGasIsBounded() public {
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        uint256 gasBefore = gasleft();
        coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH);
        uint256 gasUsed = gasBefore - gasleft();

        assertLe(gasUsed, 250_000);
    }

}

