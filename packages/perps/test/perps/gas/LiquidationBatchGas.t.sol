// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {PositionProtectionBook} from "@plether/perps/PositionProtectionBook.sol";

import {LiquidationBatchTestFixture} from "../shared/LiquidationBatchFixture.sol";

contract LiquidationBatchGasTest is LiquidationBatchTestFixture {

    function test_Batch_SplitComponentsFitDeploymentLimits() public view {
        assertLe(
            vm.getDeployedCode("OrderRouter.sol:OrderRouter").length,
            EIP170_RUNTIME_CODE_LIMIT,
            "batch entrypoint must keep production OrderRouter deployable"
        );

        address sidecar = router.liquidationBatchSidecar();
        address protectionBook = address(router.positionProtectionBook());
        OrderLifecycleBook lifecycleBook = router.lifecycleBook();
        assertNotEq(
            sidecar, protectionBook, "keeper sidecar and state-owning protection Book must be separate contracts"
        );
        assertNotEq(sidecar, address(lifecycleBook), "keeper sidecar and lifecycle Book must be separate contracts");
        assertNotEq(
            protectionBook, address(lifecycleBook), "position-protection and lifecycle Books must be separate contracts"
        );
        assertGt(sidecar.code.length, 0, "predeployed keeper sidecar must have code");
        assertLe(sidecar.code.length, EIP170_RUNTIME_CODE_LIMIT, "sidecar runtime must remain EIP-170 deployable");
        assertGt(protectionBook.code.length, 0, "Router must deploy the protection Book");
        assertLe(protectionBook.code.length, EIP170_RUNTIME_CODE_LIMIT, "Book runtime must remain EIP-170 deployable");
        assertGt(address(lifecycleBook).code.length, 0, "predeployed lifecycle Book must have code");
        assertLe(
            address(lifecycleBook).code.length,
            EIP170_RUNTIME_CODE_LIMIT,
            "lifecycle Book runtime must remain EIP-170 deployable"
        );
        assertEq(lifecycleBook.ROUTER(), address(router), "lifecycle Book must bind the exact Router");
        assertEq(lifecycleBook.ENGINE(), address(engine), "lifecycle Book Engine binding");
        assertEq(lifecycleBook.CLEARINGHOUSE(), address(clearinghouse), "lifecycle Book clearinghouse binding");
        assertEq(lifecycleBook.HOUSE_POOL(), address(pool), "lifecycle Book HousePool binding");

        uint256 sidecarCreationInputLength = type(OrderRouterLiquidationBatchSidecar).creationCode.length + 32;
        assertLe(sidecarCreationInputLength, EIP3860_INITCODE_LIMIT, "sidecar initcode must remain EIP-3860 deployable");

        uint256 lifecycleCreationInputLength = type(OrderLifecycleBook).creationCode.length + (4 * 32);
        assertLe(
            lifecycleCreationInputLength,
            EIP3860_INITCODE_LIMIT,
            "lifecycle Book creation input must remain EIP-3860 deployable"
        );

        uint256 routerCreationInputLength = type(OrderRouter).creationCode.length + (8 * 32);
        assertLe(
            routerCreationInputLength, EIP3860_INITCODE_LIMIT, "Router creation input must remain EIP-3860 deployable"
        );
        assertLe(
            type(PositionProtectionBook).creationCode.length + (2 * 32),
            EIP3860_INITCODE_LIMIT,
            "Book creation input must remain EIP-3860 deployable"
        );
    }

    function test_Gas_BatchDirectionalPricesWithPendingCarryFitDefaultItemBudget() public {
        assertEq(router.minEngineGas(), 600_000, "retain the default engine gas allowance");
        _assertDirectionalLiquidationBatch(false);
    }

}
