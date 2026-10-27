// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MockToken} from "@plether/test-utils/MockToken.sol";

/// @dev Perps-only, freely mintable six-decimal collateral fixture.
contract MockSettlementToken is MockToken {

    constructor() MockToken("Settlement Token", "SETTLEMENT", 6) {}

}
