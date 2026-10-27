// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ExecutionBlockNumberLib} from "@plether/perps/libraries/ExecutionBlockNumberLib.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Executed by the archive node through eth_call's ephemeral code override.
/// The library therefore calls native ArbSys, not Forge's local test shim.
contract PerpsBlockNumberProbe {

    function read() external view returns (uint64 executionBlock, uint256 solidityBlock) {
        return (ExecutionBlockNumberLib.current(), block.number);
    }

}

/// @notice Read-only native-Arbitrum check of the production execution-block library.
/// Requires an archive RPC supporting eth_call state overrides. No transaction is broadcast.
contract PerpsNativeArbSysForkTest is Test {

    uint256 internal constant FORK_BLOCK = 319_094_449;
    address internal constant PROBE = address(0xC0DE);

    function setUp() public {
        vm.createSelectFork(vm.envString("ARB_SEPOLIA_RPC_URL"), FORK_BLOCK);
        assertEq(block.chainid, 421_614);
    }

    function test_ProductionBlockLibraryReadsNativeL2HeightAcrossAdjacentBlocks() public {
        (uint64 first, uint256 firstL1) = _readNative(FORK_BLOCK);
        (uint64 second, uint256 secondL1) = _readNative(FORK_BLOCK + 1);
        assertEq(first, FORK_BLOCK);
        assertEq(second, FORK_BLOCK + 1);
        assertEq(second, first + 1, "Execution block advances with the actual L2 block");
        assertGt(firstL1, 0);
        assertLt(firstL1, first, "Solidity block.number is the ancestor L1 height on Arbitrum");
        assertEq(secondL1, firstL1, "These adjacent L2 blocks share an L1 ancestor");
        assertEq(PROBE.code.length, 0, "The remote override must not deploy a local contract");
    }

    function _readNative(
        uint256 number
    ) internal returns (uint64 executionBlock, uint256 solidityBlock) {
        string memory params = string.concat(
            '[{"to":"',
            vm.toString(PROBE),
            '","data":"',
            vm.toString(abi.encodeCall(PerpsBlockNumberProbe.read, ())),
            '"},"',
            vm.toString(abi.encodePacked(uint32(number))),
            '",{"',
            vm.toString(PROBE),
            '":{"code":"',
            vm.toString(type(PerpsBlockNumberProbe).runtimeCode),
            '"}}]'
        );
        bytes memory response = vm.rpc("eth_call", params);
        assertEq(response.length, 64, "Native probe returns both block-number domains");
        return abi.decode(response, (uint64, uint256));
    }

}
