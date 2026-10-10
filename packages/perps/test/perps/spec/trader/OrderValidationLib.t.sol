// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {OrderValidationLib} from "@plether/perps/libraries/OrderValidationLib.sol";
import {Test} from "forge-std/Test.sol";

contract OrderValidationLibHarness {

    function validateBaseCommit(
        uint256 sizeDelta,
        uint256 marginDelta,
        bool isClose
    ) external pure {
        OrderValidationLib.validateBaseCommit(sizeDelta, marginDelta, isClose);
    }

}

contract OrderValidationLibTest is Test {

    OrderValidationLibHarness internal harness = new OrderValidationLibHarness();

    function test_AcceptsAlignedOpenAndCloseSizes() public view {
        harness.validateBaseCommit(CfdTypes.SIZE_QUANTUM, 1e6, false);
        harness.validateBaseCommit(17 * CfdTypes.SIZE_QUANTUM, 0, true);
    }

    function test_RejectsNonLotOpen() public {
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidSizeQuantum.selector);
        harness.validateBaseCommit(CfdTypes.SIZE_QUANTUM - 1, 1e6, false);
    }

    function test_RejectsNonLotClose() public {
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidSizeQuantum.selector);
        harness.validateBaseCommit(CfdTypes.SIZE_QUANTUM + 1, 0, true);
    }

    function test_ZeroSizeKeepsDedicatedError() public {
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ZeroSize.selector);
        harness.validateBaseCommit(0, 0, false);
    }

}
