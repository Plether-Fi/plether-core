// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

contract CfdEngineHarness is CfdEngine {

    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams,
        uint256 _frozenCloseVpiFactor
    ) CfdEngine(_usdc, _clearinghouse, _capPrice, _riskParams, _frozenCloseVpiFactor) {}

}
