// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IPyth} from "@plether/shared/interfaces/IPyth.sol";
import "forge-std/Script.sol";

interface ILpEpochSettlementRouter {

    function pyth() external view returns (IPyth);

    function settleLpEpoch(
        bytes[] calldata pythUpdateData
    ) external payable;

}

/**
 * @title LpEpochKeeper
 * @notice Validates one Pyth basket and atomically clears one bounded LP epoch pass through OrderRouter.
 * @dev Usage: PERPS_ORDER_ROUTER=<addr> KEEPER_PRIVATE_KEY=<key> \
 *             PYTH_UPDATE_DATA=<abi-encoded bytes[]> \
 *             forge script script/LpEpochKeeper.s.sol --tc LpEpochKeeper --rpc-url $RPC_URL --broadcast
 *      The call deliberately reverts when no matured queue item can advance, so operators should preflight queue
 *      state through PerpsPublicLens before broadcasting.
 */
contract LpEpochKeeper is Script {

    function run() external {
        address routerAddress = vm.envAddress("PERPS_ORDER_ROUTER");
        uint256 privateKey = vm.envUint("KEEPER_PRIVATE_KEY");
        bytes[] memory updateData = abi.decode(vm.envBytes("PYTH_UPDATE_DATA"), (bytes[]));

        ILpEpochSettlementRouter router = ILpEpochSettlementRouter(routerAddress);
        uint256 fee = router.pyth().getUpdateFee(updateData);

        console.log("OrderRouter:", routerAddress);
        console.log("Pyth update fee:", fee, "wei");

        vm.startBroadcast(privateKey);
        router.settleLpEpoch{value: fee}(updateData);
        vm.stopBroadcast();

        console.log("Atomic LP epoch settlement succeeded; inspect LpEpochSettled for the bounded-pass result");
    }

}
