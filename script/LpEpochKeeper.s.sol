// SPDX-License-Identifier: MIT
pragma solidity 0.8.39;

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {ISettlementMonitorLens} from "@plether/perps/interfaces/ISettlementMonitorLens.sol";
import {SettlementMonitorViewTypes} from "@plether/perps/interfaces/SettlementMonitorViewTypes.sol";
import "forge-std/Script.sol";

interface ILpEpochSettlementOracle {

    function getUpdateFee(
        bytes[] calldata pythUpdateData
    ) external view returns (uint256);

    function getOrderExecutionFee(
        bytes[] calldata pythUpdateData
    ) external view returns (uint256);

}

interface ILpEpochSettlementRouter is IPerpsKeeper {

    function pletherOracle() external view returns (ILpEpochSettlementOracle);

    function nextExecuteId() external view returns (uint64);

    function globalTailOrderId() external view returns (uint64);

    function maxPruneOrdersPerCall() external view returns (uint256);

}

interface ILpEpochSettlementPool {

    function settleLpEpoch(
        uint256 expectedMarkPrice,
        uint256 expectedPublishTime
    ) external;

}

interface ILpEpochSettlementMonitor is ISettlementMonitorLens {

    function ROUTER() external view returns (address);

    function HOUSE_POOL() external view returns (address);

}

/**
 * @title LpEpochKeeper
 * @notice Provides a bounded order pass followed by Lens-routed settlement in a separate script invocation.
 * @dev Usage: SETTLEMENT_MONITOR_LENS=<addr> PERPS_ORDER_ROUTER=<addr> OBSERVED_EPOCH=<epoch> \
 *             KEEPER_PRIVATE_KEY=<key> [PYTH_UPDATE_DATA=<abi-encoded bytes[]>] \
 *             [ORDER_PYTH_UPDATE_DATA=<abi-encoded bytes[]>] \
 *             bash scripts/settle-lp-epoch.sh --rpc-url $RPC_URL --broadcast
 *      Poll the lighter SettlementMonitorLens status view. Before broadcasting, select `observedEpoch` and record the
 *      composite as a block-pinned checkpoint; its roughly 6 KB return / 0.8-1.3m representative eth_call gas is not
 *      intended for every polling tick. The script refuses unknown/no-work routing. `CachedMark` calls HousePool
 *      directly without Pyth data or ETH; `AtomicOracleRefresh` requires a Hermes payload and calls the Router with
 *      the active PletherOracle's exact fee. When `minimumAtomicPublishTime` is nonzero, that payload must be published
 *      at or after the reported boundary; frozen stale-mark recovery deliberately reports zero and uses frozen-policy
 *      freshness instead. An active LP epoch settlement hold is rejected before any Hermes payload is decoded or fee
 *      is quoted. The observed epoch does not select what either route settles.
 *      Monitoring is advisory and route state can race, so Foundry's exact transaction simulation remains mandatory;
 *      do not use `--skip-simulation`. Always use the SettlementMonitorLens facade, not its monitor-only sidecar.
 */
contract LpEpochKeeper is Script {

    uint256 internal constant MAX_ORDER_IDS_PER_PASS = 4;

    error LpEpochKeeper__InvalidContract(address target);
    error LpEpochKeeper__RouterMismatch(address expected, address actual);
    error LpEpochKeeper__ExecutionPathUnknown(uint256 dependencyMask);
    error LpEpochKeeper__LpEpochSettlementPaused();
    error LpEpochKeeper__NoMaturedWork();
    error LpEpochKeeper__UnsupportedExecutionPath(SettlementMonitorViewTypes.ExecutionPath executionPath);

    /// @notice Makes one best-effort pass; the runner invokes LP settlement independently of this transaction.
    function processOrders() external {
        ILpEpochSettlementRouter router = ILpEpochSettlementRouter(vm.envAddress("PERPS_ORDER_ROUTER"));
        (SettlementMonitorViewTypes.SettlementStatus memory status,) =
            _prepareSettlement(vm.envAddress("SETTLEMENT_MONITOR_LENS"), address(router), vm.envUint("OBSERVED_EPOCH"));

        uint64 tail = router.globalTailOrderId();
        if (tail == 0) {
            return;
        }
        uint64 head = router.nextExecuteId();
        uint256 count = uint256(tail) - head + 1;
        if (count > MAX_ORDER_IDS_PER_PASS) {
            count = MAX_ORDER_IDS_PER_PASS;
        }

        bytes memory encoded = vm.envOr("ORDER_PYTH_UPDATE_DATA", bytes(""));
        bytes[] memory orderData = encoded.length == 0 ? new bytes[](0) : abi.decode(encoded, (bytes[]));
        if (!status.oracleFrozen) {
            if (orderData.length == 0) {
                _clearInvalidOrders(router, head, count);
                return;
            }
            // Executing an open in a flat Pool can make the atomic settlement route necessary.
            if (status.requiredExecutionPath == SettlementMonitorViewTypes.ExecutionPath.CachedMark) {
                bytes memory lpData = vm.envOr("PYTH_UPDATE_DATA", bytes(""));
                if (lpData.length == 0 || abi.decode(lpData, (bytes[])).length == 0) {
                    console.log("Current LP oracle data unavailable; checking invalid orders only");
                    _clearInvalidOrders(router, head, count);
                    return;
                }
            }
        }

        // Each order may require a separate historical parse. The Router refunds unused funding.
        uint256 fee = router.pletherOracle().getOrderExecutionFee(orderData) * count;
        uint64 last = uint64(uint256(head) + count - 1);
        vm.broadcast(vm.envUint("KEEPER_PRIVATE_KEY"));
        OrderV3Types.BatchResult memory result = router.executeOrderBatch{value: fee}(last, orderData);
        console.log("Order pass terminal count:", result.terminalCount);
        console.log("Order pass next order:", result.nextOrderId);
        console.log("Order pass stop reason:", uint256(result.stopReason));
    }

    function run() external {
        address monitorAddress = vm.envAddress("SETTLEMENT_MONITOR_LENS");
        address routerAddress = vm.envAddress("PERPS_ORDER_ROUTER");
        uint256 observedEpoch = vm.envUint("OBSERVED_EPOCH");
        uint256 privateKey = vm.envUint("KEEPER_PRIVATE_KEY");

        (SettlementMonitorViewTypes.SettlementStatus memory status, address poolAddress) =
            _prepareSettlement(monitorAddress, routerAddress, observedEpoch);

        console.log("SettlementMonitorLens:", monitorAddress);
        console.log("OrderRouter:", routerAddress);
        console.log("Observed epoch:", observedEpoch);
        console.log("Execution path:", uint256(uint8(status.requiredExecutionPath)));

        if (status.requiredExecutionPath == SettlementMonitorViewTypes.ExecutionPath.CachedMark) {
            console.log("HousePool:", poolAddress);
            console.log("Cached mark price:", status.cachedMarkPrice);
            console.log("Cached mark time:", status.cachedMarkTime);

            vm.startBroadcast(privateKey);
            _executeCachedMark(poolAddress, status.cachedMarkPrice, status.cachedMarkTime);
            vm.stopBroadcast();

            console.log("Cached-mark LP epoch settlement succeeded; inspect LpEpochSettled for the bounded-pass result");
            return;
        }

        if (status.requiredExecutionPath != SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh) {
            revert LpEpochKeeper__UnsupportedExecutionPath(status.requiredExecutionPath);
        }

        bytes[] memory updateData = abi.decode(vm.envBytes("PYTH_UPDATE_DATA"), (bytes[]));
        uint256 fee = _quoteAtomicFee(routerAddress, updateData);
        console.log("Pyth update fee:", fee, "wei");

        vm.startBroadcast(privateKey);
        _executeAtomicRefresh(routerAddress, updateData, fee);
        vm.stopBroadcast();

        console.log("Atomic LP epoch settlement succeeded; inspect LpEpochSettled for the bounded-pass result");
    }

    function _clearInvalidOrders(
        ILpEpochSettlementRouter router,
        uint64 head,
        uint256 count
    ) internal {
        uint256 maxPrune = router.maxPruneOrdersPerCall();
        if (count > maxPrune) {
            count = maxPrune;
        }
        uint64[] memory ids = new uint64[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = uint64(uint256(head) + i);
        }
        vm.broadcast(vm.envUint("KEEPER_PRIVATE_KEY"));
        (, uint256 cleared) = router.clearInvalidOrders(ids);
        console.log("Order pass invalid orders cleared:", cleared);
    }

    function _prepareSettlement(
        address monitorAddress,
        address routerAddress,
        uint256 observedEpoch
    ) internal view returns (SettlementMonitorViewTypes.SettlementStatus memory status, address poolAddress) {
        _requireContract(monitorAddress);
        _requireContract(routerAddress);

        ILpEpochSettlementMonitor monitor = ILpEpochSettlementMonitor(monitorAddress);
        address boundRouter = monitor.ROUTER();
        if (boundRouter != routerAddress) {
            revert LpEpochKeeper__RouterMismatch(routerAddress, boundRouter);
        }
        poolAddress = monitor.HOUSE_POOL();
        _requireContract(poolAddress);

        status = monitor.getSettlementStatus(observedEpoch);
        if (status.lpEpochSettlementPaused) {
            revert LpEpochKeeper__LpEpochSettlementPaused();
        }
        if (status.executionPathDependencyMask != 0) {
            revert LpEpochKeeper__ExecutionPathUnknown(status.executionPathDependencyMask);
        }
        if (
            !status.hasMaturedWork
                || status.requiredExecutionPath == SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork
        ) {
            revert LpEpochKeeper__NoMaturedWork();
        }
        if (status.requiredExecutionPath == SettlementMonitorViewTypes.ExecutionPath.Unknown) {
            revert LpEpochKeeper__ExecutionPathUnknown(0);
        }
    }

    function _quoteAtomicFee(
        address routerAddress,
        bytes[] memory updateData
    ) internal view returns (uint256 fee) {
        ILpEpochSettlementOracle oracle = ILpEpochSettlementRouter(routerAddress).pletherOracle();
        _requireContract(address(oracle));
        return oracle.getUpdateFee(updateData);
    }

    function _executeCachedMark(
        address poolAddress,
        uint256 cachedMarkPrice,
        uint256 cachedMarkTime
    ) internal {
        ILpEpochSettlementPool(poolAddress).settleLpEpoch(cachedMarkPrice, cachedMarkTime);
    }

    function _executeAtomicRefresh(
        address routerAddress,
        bytes[] memory updateData,
        uint256 fee
    ) internal {
        ILpEpochSettlementRouter(routerAddress).settleLpEpoch{value: fee}(updateData);
    }

    function _requireContract(
        address target
    ) internal view {
        if (target == address(0) || target.code.length == 0) {
            revert LpEpochKeeper__InvalidContract(target);
        }
    }

}
