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
            CFD_ENGINE_RUNTIME_BASELINE,
            "terminal NAV synchronization must not grow CfdEngine runtime"
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

