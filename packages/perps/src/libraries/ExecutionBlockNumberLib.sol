// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

interface IArbSysBlockNumber {

    function arbBlockNumber() external view returns (uint256);

}

/// @notice Returns the block number of the chain executing the transaction.
/// @dev On Arbitrum, Solidity's block.number is an ancestor L1 block number and can be shared by many L2 blocks.
///      The ArbSys precompile returns the L2 block number. An unavailable precompile on a listed Arbitrum chain
///      reverts instead of silently weakening same-block protections.
library ExecutionBlockNumberLib {

    address private constant ARB_SYS = address(100);

    function current() internal view returns (uint64) {
        if (block.chainid == 42_161 || block.chainid == 42_170 || block.chainid == 421_614) {
            return uint64(IArbSysBlockNumber(ARB_SYS).arbBlockNumber());
        }
        return uint64(block.number);
    }

}
