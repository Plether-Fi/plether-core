// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEngineOpenQuoter} from "@plether/perps/CfdEngineOpenQuoter.sol";

import {CfdEngineLensQuoteTestFixture} from "../shared/CfdEngineLensQuoteFixture.sol";

contract CfdEngineLensQuoteGasTest is CfdEngineLensQuoteTestFixture {

    function test_Runtime_QuoteComponentsFitDeploymentLimits() public {
        CfdEngineOpenQuoter quoter = new CfdEngineOpenQuoter();
        assertLe(address(engineLens).code.length, 24_576, "lens runtime exceeds EIP-170");
        assertLe(address(quoter).code.length, 24_576, "quoter runtime exceeds EIP-170");
        assertLe(
            type(CfdEngineLens).creationCode.length + abi.encode(address(engine)).length,
            49_152,
            "lens creation input exceeds EIP-3860"
        );
        assertLe(type(CfdEngineOpenQuoter).creationCode.length, 49_152, "quoter initcode exceeds EIP-3860");
    }

}

