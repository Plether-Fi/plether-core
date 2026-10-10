// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";

import {OrderRouterExecutionSidecarTestFixture} from "../shared/OrderRouterExecutionSidecarFixture.sol";

contract OrderRouterExecutionSidecarGasTest is OrderRouterExecutionSidecarTestFixture {

    function testProductionRuntimeFitsEip170() public {
        OrderRouterExecutionSidecar productionSidecar = new OrderRouterExecutionSidecar();
        assertLe(
            address(productionSidecar).code.length,
            EIP170_RUNTIME_CODE_LIMIT,
            "production execution sidecar must remain deployable"
        );
    }

}
