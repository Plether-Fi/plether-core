// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/// @notice Caller used to prove that the Router's final ETH refund cannot reenter LP settlement.
import {AtomicLpEpochSettlementTestFixture} from "../shared/AtomicLpEpochSettlementFixture.sol";

contract AtomicLpEpochSettlementGasTest is AtomicLpEpochSettlementTestFixture {

    using stdStorage for StdStorage;

    function test_AtomicLpEpoch_RuntimeFitsEip170() public view {
        assertLe(
            address(engine).code.length,
            CFD_ENGINE_RUNTIME_TARGET,
            "CfdEngine must remain within its measured treasury-scheduling runtime target"
        );
        assertLe(address(engine).code.length, EIP170_RUNTIME_CODE_LIMIT, "CfdEngine must remain EIP-170 deployable");
        assertLe(
            address(engine.planningReader()).code.length,
            EIP170_RUNTIME_CODE_LIMIT,
            "planning reader must remain EIP-170 deployable"
        );
        assertLe(
            address(engine.settlementSidecar()).code.length,
            EIP170_RUNTIME_CODE_LIMIT,
            "settlement sidecar must remain EIP-170 deployable"
        );
        assertLe(
            vm.getCode("CfdEngine.sol:CfdEngine").length
                + abi.encode(
                    address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
                )
                .length,
            49_152,
            "engine initcode including its planning reader must remain EIP-3860 deployable"
        );
        assertLe(
            address(pool).code.length,
            HOUSE_POOL_RUNTIME_TARGET,
            "atomic LP settlement must keep HousePool within its measured runtime target"
        );
        assertLt(address(pool).code.length, EIP170_RUNTIME_CODE_LIMIT, "HousePool must remain EIP-170 deployable");
        assertLt(
            address(housePoolRedemptionMathSidecar).code.length,
            REDEMPTION_MATH_SIDECAR_RUNTIME_LIMIT,
            "redemption math sidecar must remain below its runtime limit"
        );
        assertLe(
            vm.getDeployedCode("OrderRouter.sol:OrderRouter").length,
            EIP170_RUNTIME_CODE_LIMIT,
            "atomic LP settlement must keep production OrderRouter deployable"
        );
    }

}
