// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {PositionProtectionBook} from "@plether/perps/PositionProtectionBook.sol";

import {Test} from "forge-std/Test.sol";

import {PositionProtectionLiquidationBatchTestFixture} from "../shared/PositionProtectionLiquidationBatchFixture.sol";

contract OrderRouterInitcodeSizeTest is Test {

    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    function test_OrderRouterCreationCodeAndConstructorArgsFitsEip3860() public pure {
        assertLe(
            type(OrderRouter).creationCode.length + (8 * 32),
            EIP3860_INITCODE_LIMIT,
            "OrderRouter creation code plus eight static constructor arguments must fit EIP-3860"
        );
        assertLe(
            type(OrderRouterLiquidationBatchSidecar).creationCode.length + 32,
            EIP3860_INITCODE_LIMIT,
            "sidecar creation code plus its static constructor argument must fit EIP-3860"
        );
        assertLe(
            type(OrderLifecycleBook).creationCode.length + (4 * 32),
            EIP3860_INITCODE_LIMIT,
            "OrderLifecycleBook creation code plus four static constructor arguments must fit EIP-3860"
        );
        assertLe(
            type(PositionProtectionBook).creationCode.length + (2 * 32),
            EIP3860_INITCODE_LIMIT,
            "PositionProtectionBook creation code plus two static constructor arguments must fit EIP-3860"
        );
    }

}

contract PositionProtectionLiquidationBatchGasTest is PositionProtectionLiquidationBatchTestFixture {

    function test_Batch_SplitComponentBindingAndRuntimeFitsEip170() public view {
        address sidecar = router.liquidationBatchSidecar();
        address book = address(protectionBook);
        assertNotEq(sidecar, book, "keeper sidecar and state-owning protection Book must be separate contracts");
        assertEq(
            OrderRouterLiquidationBatchSidecar(sidecar).ROUTER(), address(router), "sidecar must bind the exact Router"
        );
        assertEq(PositionProtectionBook(book).ROUTER(), address(router), "Book must bind the exact Router");
        assertLe(
            vm.getDeployedCode("OrderRouter.sol:OrderRouter").length,
            EIP170_RUNTIME_CODE_LIMIT,
            "production OrderRouter runtime must fit EIP-170"
        );
        assertGt(sidecar.code.length, 0, "keeper sidecar must be deployed");
        assertLe(sidecar.code.length, EIP170_RUNTIME_CODE_LIMIT, "keeper sidecar runtime must fit EIP-170");
        assertGt(book.code.length, 0, "PositionProtectionBook must be deployed");
        assertLe(book.code.length, EIP170_RUNTIME_CODE_LIMIT, "PositionProtectionBook runtime must fit EIP-170");
    }

}
