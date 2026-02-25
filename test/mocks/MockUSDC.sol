// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockToken} from "./MockToken.sol";

contract MockUSDC is MockToken {

    constructor() MockToken("USDC", "USDC", 6) {}

}
