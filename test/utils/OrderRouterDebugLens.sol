// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";

library OrderRouterDebugLens {

    function loadOrderRecord(
        Vm vm_,
        OrderRouter router,
        uint64 orderId
    ) internal view returns (OrderRouter.OrderRecord memory record) {
        uint256 baseSlot = uint256(keccak256(abi.encode(orderId, uint256(0))));

        record.core.accountId = vm_.load(address(router), bytes32(baseSlot));
        record.core.sizeDelta = uint256(vm_.load(address(router), bytes32(baseSlot + 1)));
        record.core.marginDelta = uint256(vm_.load(address(router), bytes32(baseSlot + 2)));
        record.core.targetPrice = uint256(vm_.load(address(router), bytes32(baseSlot + 3)));

        uint256 packedCore = uint256(vm_.load(address(router), bytes32(baseSlot + 4)));
        record.core.commitTime = uint64(packedCore);
        record.core.commitBlock = uint64(packedCore >> 64);
        record.core.orderId = uint64(packedCore >> 128);
        record.core.side = CfdTypes.Side(uint8(packedCore >> 192));
        record.core.isClose = ((packedCore >> 200) & 0xff) != 0;

        record.status = IOrderRouterAccounting.OrderStatus(uint8(uint256(vm_.load(address(router), bytes32(baseSlot + 5)))));
        record.executionBountyUsdc = uint256(vm_.load(address(router), bytes32(baseSlot + 6)));

        uint256 packedLinks = uint256(vm_.load(address(router), bytes32(baseSlot + 7)));
        record.nextGlobalOrderId = uint64(packedLinks);
        record.prevGlobalOrderId = uint64(packedLinks >> 64);
        record.nextAccountOrderId = uint64(packedLinks >> 128);
        record.prevAccountOrderId = uint64(packedLinks >> 192);

        uint256 packedFlags = uint256(vm_.load(address(router), bytes32(baseSlot + 8)));
        record.nextMarginOrderId = uint64(packedFlags);
        record.prevMarginOrderId = uint64(packedFlags >> 64);
        record.inAccountQueue = ((packedFlags >> 128) & 0xff) != 0;
        record.inMarginQueue = ((packedFlags >> 136) & 0xff) != 0;
    }

    function loadOrderStatus(
        Vm vm_,
        OrderRouter router,
        uint64 orderId
    ) internal view returns (IOrderRouterAccounting.OrderStatus) {
        uint256 baseSlot = uint256(keccak256(abi.encode(orderId, uint256(0))));
        return IOrderRouterAccounting.OrderStatus(uint8(uint256(vm_.load(address(router), bytes32(baseSlot + 5)))));
    }
}
