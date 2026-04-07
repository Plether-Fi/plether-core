// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../../src/perps/CfdTypes.sol";

contract CfdEngineHarness is CfdEngine {

    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams
    ) CfdEngine(_usdc, _clearinghouse, _capPrice, _riskParams) {}

}
