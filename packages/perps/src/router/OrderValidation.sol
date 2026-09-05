// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IOrderRouterV2ExecutionHost} from "@plether/perps/interfaces/IOrderRouterV2ExecutionHost.sol";
import {OrderBountyAccounting} from "@plether/perps/router/OrderBountyAccounting.sol";

/// @title OrderValidation
/// @notice Owns the commit cursor and dispatches risk-off settlement and terminal receipts to V2 execution.
abstract contract OrderValidation is OrderBountyAccounting {

    /// @notice Next order id assigned by a successful commit; starts at one.
    uint64 public nextCommitId = 1;

    /// @notice Settles one cutoff-invalid open through the V2 sidecar and records its canonical receipt.
    /// @dev The external Router self-call supplies an independent rollback boundary while preserving the original
    ///      external cleaner or liquidation keeper as the receipt executor.
    function _settleRiskOffOrderWithReceipt(
        uint64 orderId,
        address executor
    ) internal returns (OrderV2Types.ExecutionResult memory result) {
        uint256 neutralMarkPrice = engine.lastMarkPrice();
        uint256 capPrice = engine.CAP_PRICE();
        if (neutralMarkPrice > capPrice) {
            neutralMarkPrice = capPrice;
        }
        // Solidity zero-initializes oracle fields that are deliberately absent from pre-oracle risk-off cleanup.
        // slither-disable-next-line uninitialized-local
        IOrderRouterV2ExecutionHost.ItemRequest memory request;
        request.orderId = orderId;
        request.action = IOrderRouterV2ExecutionHost.ItemAction.RiskOff;
        request.executor = executor;
        request.observedConfigHash = lifecycleBook.currentExecutionConfigHash();
        request.neutralMarkPrice = neutralMarkPrice;
        request.poolDepthUsdc = housePool.totalAssets();
        request.bountyAccountingPrice = neutralMarkPrice;
        request.bountyAccountingPublishTime = engine.lastMarkTime();
        return IOrderRouterV2ExecutionHost(address(this)).executeV2OrderItemFromSidecar(request);
    }

    /// @notice Delegates canonical receipt construction for accounting already settled by liquidation.
    function _recordSettledTerminalReceipt(
        IOrderRouterV2ExecutionHost.SettledTerminalInput memory input
    ) internal returns (OrderV2Types.ExecutionResult memory result) {
        return IOrderRouterV2ExecutionHost(address(this)).recordSettledTerminal(input);
    }

}
