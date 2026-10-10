// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";

import {VmSafe} from "forge-std/Vm.sol";

import {TerminalNavBookV2TestFixture} from "../shared/TerminalNavBookV2Fixture.sol";

contract TerminalNavBookV2GasTest is TerminalNavBookV2TestFixture {

    function test_Gas_CappedInsertAndRelocationStayWithinBookGate() public {
        address account = address(1);
        driver.setPosition(account, _curveInput(1000, 100_000e6, 20_000e6, CfdTypes.Side.LONG));
        uint256 gasBefore = gasleft();
        (bytes32 firstHash,) = driver.sync(account, bytes32(0));
        uint256 insertGas = gasBefore - gasleft();
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLt(insertGas, 500_000);
        }

        driver.setPosition(account, _curveInput(1000, 100_000e6, 50_000e6, CfdTypes.Side.LONG));
        gasBefore = gasleft();
        driver.sync(account, firstHash);
        uint256 relocationGas = gasBefore - gasleft();
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLt(relocationGas, 500_000);
        }
    }

    function test_Gas_AbsentPositionAndCurveNoOpStaysWithinBookGate() public {
        uint256 gasBefore = gasleft();
        driver.sync(address(1), bytes32(0));
        uint256 noOpGas = gasBefore - gasleft();
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLt(noOpGas, 50_000);
        }
    }

    function test_Gas_MaximumRadixReadStaysWithinBookGate() public {
        (, TerminalNavBookV2 maxBook) = _deployBook(type(uint32).max);
        uint256 gasBefore = gasleft();
        maxBook.terminalLpPriceDeltaUsdcAtoms(type(uint32).max);
        uint256 queryGas = gasBefore - gasleft();
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLt(queryGas, 400_000);
        }
    }

}

