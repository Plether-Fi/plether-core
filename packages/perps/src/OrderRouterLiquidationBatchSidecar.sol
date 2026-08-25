// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterEmergencyAdmin} from "@plether/perps/interfaces/IOrderRouterEmergencyAdmin.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IOrderRouterLiquidationBatchHost} from "@plether/perps/interfaces/IOrderRouterLiquidationBatchHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

/// @title OrderRouterLiquidationBatchSidecar
/// @notice Immutable stateless delegate module for the Router's size-heavy liquidation-batch orchestration.
/// @dev Declares no mutable storage and accesses Router state only through public getters and a self-only item callback.
contract OrderRouterLiquidationBatchSidecar is IOrderRouterErrors {

    error OrderRouterLiquidationBatchSidecar__OnlyDelegateCall();

    uint256 internal constant MAX_LIQUIDATION_BATCH_ACCOUNTS = 256;
    uint256 internal constant LIQUIDATION_BATCH_ROUTER_GAS = 250_000;
    uint256 internal constant LIQUIDATION_BATCH_GAS_PER_ORDER = 150_000;
    uint256 internal constant LIQUIDATION_BATCH_TAIL_GAS = 250_000;

    /// @notice Router that deployed this fixed module and is the only valid delegatecall context.
    address public immutable ROUTER;

    constructor() {
        ROUTER = msg.sender;
    }

    /// @notice Executes the Router liquidation-batch flow in the Router's call context.
    function executeLiquidationBatch(
        address[] calldata accounts,
        bytes[] calldata pythUpdateData
    ) external payable returns (uint256 nextIndex) {
        if (address(this) != ROUTER) {
            revert OrderRouterLiquidationBatchSidecar__OnlyDelegateCall();
        }

        uint256 accountCount = accounts.length;
        if (accountCount == 0 || accountCount > MAX_LIQUIDATION_BATCH_ACCOUNTS) {
            revert OrderRouter__InvalidLiquidationBatchSize();
        }

        IOrderRouterLiquidationBatchHost router = IOrderRouterLiquidationBatchHost(address(this));
        uint64 riskOffCutoff = IOrderRouterEmergencyAdmin(router.admin()).riskOffOrderCutoff();
        IPletherOracle.LiquidationBatchSnapshot memory snapshot = IPletherOracle(router.pletherOracle())
        .updateLiquidationBatchPrice{value: msg.value}(
            msg.sender, pythUpdateData
        );
        ICfdEngineCore(router.engine()).updateMarkPrice(snapshot.markPrice, snapshot.publishTime);
        uint256 engineGas = router.minEngineGas();

        while (nextIndex < accountCount) {
            address account = accounts[nextIndex];
            uint256 itemGas = engineGas + LIQUIDATION_BATCH_ROUTER_GAS
                + (router.pendingOrderCounts(account) * LIQUIDATION_BATCH_GAS_PER_ORDER);
            if (gasleft() <= itemGas + LIQUIDATION_BATCH_TAIL_GAS) {
                emit LiquidationBatchStopped(nextIndex);
                return nextIndex;
            }

            try router.executeLiquidationBatchItem{gas: itemGas}(
                account, snapshot.bullPrice, snapshot.bearPrice, snapshot.publishTime, msg.sender, riskOffCutoff
            ) returns (
                uint256 outcome
            ) {
                bool restoredSolvency = outcome == type(uint256).max;
                emit LiquidationBatchItem(
                    nextIndex,
                    account,
                    restoredSolvency ? LiquidationBatchResult.SkippedSolvent : LiquidationBatchResult.Liquidated,
                    restoredSolvency ? 0 : outcome,
                    bytes4(0)
                );
            } catch (bytes memory revertData) {
                if (revertData.length == 0) {
                    emit LiquidationBatchStopped(nextIndex);
                    return nextIndex;
                }
                bytes4 selector = revertData.length >= 4 ? bytes4(revertData) : bytes4(0);
                emit LiquidationBatchItem(nextIndex, account, _liquidationBatchResult(selector), 0, selector);
            }

            unchecked {
                ++nextIndex;
            }
        }
    }

    function _liquidationBatchResult(
        bytes4 selector
    ) private pure returns (LiquidationBatchResult result) {
        if (selector == ICfdEngineTypes.CfdEngine__NoPositionToLiquidate.selector) {
            return LiquidationBatchResult.SkippedNoPosition;
        }
        if (selector == ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector) {
            return LiquidationBatchResult.SkippedSolvent;
        }
        return LiquidationBatchResult.Failed;
    }

}
