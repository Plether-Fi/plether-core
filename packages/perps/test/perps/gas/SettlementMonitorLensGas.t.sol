// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SettlementMonitorLens} from "@plether/perps/SettlementMonitorLens.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {SettlementMonitorLensTestFixture} from "../shared/SettlementMonitorLensFixture.sol";

contract SettlementMonitorLensGasTest is SettlementMonitorLensTestFixture {

    using stdStorage for StdStorage;

    function test_SettlementMonitorLensRuntimeFitsEip170() public view {
        assertGt(address(monitorLens).code.length, 0);
        assertLe(address(monitorLens).code.length, EIP170_RUNTIME_CODE_LIMIT);
        assertGt(address(monitorLens.SIDECAR()).code.length, 0);
        assertLe(address(monitorLens.SIDECAR()).code.length, EIP170_RUNTIME_CODE_LIMIT);
    }

    function test_SettlementMonitorLensCreationInputFitsEip3860() public pure {
        uint256 creationInputLength = type(SettlementMonitorLens).creationCode.length + 32;
        assertLe(
            creationInputLength,
            EIP3860_INITCODE_LIMIT,
            "SettlementMonitorLens creation code plus constructor argument must remain deployable"
        );
    }

}

