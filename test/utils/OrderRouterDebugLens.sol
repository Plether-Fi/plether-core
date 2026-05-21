// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vm} from "forge-std/Vm.sol";

library OrderRouterDebugLens {

    function loadOrderRecord(
        Vm vm_,
        OrderRouter router,
        uint64 orderId
    ) internal view returns (OrderRouter.OrderRecord memory record) {
        uint256 baseSlot = uint256(keccak256(abi.encode(orderId, uint256(0))));

        record.core.account = address(uint160(uint256(vm_.load(address(router), bytes32(baseSlot)))));
        record.core.sizeDelta = uint256(vm_.load(address(router), bytes32(baseSlot + 1)));
        record.core.marginDelta = uint256(vm_.load(address(router), bytes32(baseSlot + 2)));
        record.core.targetPrice = uint256(vm_.load(address(router), bytes32(baseSlot + 3)));

        uint256 packedCore = uint256(vm_.load(address(router), bytes32(baseSlot + 4)));
        record.core.commitTime = _packedUint64(packedCore, 0);
        record.core.commitBlock = _packedUint64(packedCore, 64);
        record.core.orderId = _packedUint64(packedCore, 128);
        record.core.side = CfdTypes.Side(_packedUint8(packedCore, 192));
        record.core.isClose = ((packedCore >> 200) & 0xff) != 0;

        record.status = IOrderRouterAccounting.OrderStatus(
            SafeCast.toUint8(uint256(vm_.load(address(router), bytes32(baseSlot + 5))))
        );
        record.executionBountyUsdc = uint256(vm_.load(address(router), bytes32(baseSlot + 6)));

        uint256 packedLinks = uint256(vm_.load(address(router), bytes32(baseSlot + 7)));
        record.nextGlobalOrderId = _packedUint64(packedLinks, 0);
        record.prevGlobalOrderId = _packedUint64(packedLinks, 64);
        record.nextAccountOrderId = _packedUint64(packedLinks, 128);
        record.prevAccountOrderId = _packedUint64(packedLinks, 192);

        uint256 packedFlags = uint256(vm_.load(address(router), bytes32(baseSlot + 8)));
        record.nextMarginOrderId = _packedUint64(packedFlags, 0);
        record.prevMarginOrderId = _packedUint64(packedFlags, 64);
        record.inAccountQueue = ((packedFlags >> 128) & 0xff) != 0;
        record.inMarginQueue = ((packedFlags >> 136) & 0xff) != 0;
    }

    function loadOrderStatus(
        Vm vm_,
        OrderRouter router,
        uint64 orderId
    ) internal view returns (IOrderRouterAccounting.OrderStatus) {
        uint256 baseSlot = uint256(keccak256(abi.encode(orderId, uint256(0))));
        return
            IOrderRouterAccounting.OrderStatus(
                SafeCast.toUint8(uint256(vm_.load(address(router), bytes32(baseSlot + 5))))
            );
    }

    function _packedUint64(
        uint256 value,
        uint256 shift
    ) private pure returns (uint64) {
        return SafeCast.toUint64((value >> shift) & type(uint64).max);
    }

    function _packedUint8(
        uint256 value,
        uint256 shift
    ) private pure returns (uint8) {
        return SafeCast.toUint8((value >> shift) & type(uint8).max);
    }

}
