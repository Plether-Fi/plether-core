// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPyth} from "../src/interfaces/IPyth.sol";
import "forge-std/Script.sol";

/**
 * @title PythKeeper
 * @notice Pushes fresh Pyth price data on-chain for Sepolia PythAdapters.
 * @dev Usage: PYTH_UPDATE_DATA=<abi-encoded bytes[]> forge script script/PythKeeper.s.sol --tc PythKeeper --rpc-url $SEPOLIA_RPC_URL --broadcast
 *      Use scripts/pyth-keeper.sh to fetch data from Hermes and run this automatically.
 */
contract PythKeeper is Script {

    address constant PYTH_SEPOLIA = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21;

    function run() external {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");

        bytes memory rawUpdateData = vm.envBytes("PYTH_UPDATE_DATA");
        bytes[] memory updateData = abi.decode(rawUpdateData, (bytes[]));

        uint256 fee = IPyth(PYTH_SEPOLIA).getUpdateFee(updateData);
        console.log("Pyth update fee:", fee, "wei");

        vm.startBroadcast(privateKey);
        IPyth(PYTH_SEPOLIA).updatePriceFeeds{value: fee}(updateData);
        vm.stopBroadcast();

        console.log("Pyth prices updated successfully");
    }

}
