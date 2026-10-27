// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

/// @dev Forge forks use the L2 RPC height for block.number but do not implement ArbSys.
/// This test-only shim follows vm.roll, preserving same-L2-block execution checks.
contract ForkArbSys {

    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }

}

library ArbitrumForkSupport {

    function install() internal {
        require(block.chainid == 421_614, "Arbitrum Sepolia fork required");
        Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).etch(address(100), type(ForkArbSys).runtimeCode);
    }

}
