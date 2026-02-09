// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPyth} from "../src/interfaces/IPyth.sol";
import "forge-std/Script.sol";

/**
 * @title PythKeeper
 * @notice Pushes fresh Pyth price data on-chain. Supports Sepolia and Mainnet.
 * @dev Usage: PYTH_ADDRESS=<addr> KEEPER_PRIVATE_KEY=<key> PYTH_UPDATE_DATA=<abi-encoded bytes[]> \
 *             forge script script/PythKeeper.s.sol --tc PythKeeper --rpc-url $RPC_URL --broadcast
 *      Use scripts/pyth-keeper.sh to fetch data from Hermes and run this automatically.
 */
contract PythKeeper is Script {

    function run() external {
        address pyth = vm.envAddress("PYTH_ADDRESS");
        uint256 privateKey = vm.envUint("KEEPER_PRIVATE_KEY");

        bytes memory rawUpdateData = vm.envBytes("PYTH_UPDATE_DATA");
        bytes[] memory updateData = abi.decode(rawUpdateData, (bytes[]));

        uint256 fee = IPyth(pyth).getUpdateFee(updateData);
        console.log("Pyth update fee:", fee, "wei");

        vm.startBroadcast(privateKey);
        IPyth(pyth).updatePriceFeeds{value: fee}(updateData);
        vm.stopBroadcast();

        console.log("Pyth prices updated successfully");
    }

}
