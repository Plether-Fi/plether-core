// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderRouterExecutionHost} from "@plether/perps/interfaces/IOrderRouterExecutionHost.sol";
import {OrderBountyAccounting} from "@plether/perps/router/OrderBountyAccounting.sol";

/// @title OrderValidation
/// @notice Owns the commit cursor and dispatches risk-off settlement and terminal receipts to V3 execution.
abstract contract OrderValidation is OrderBountyAccounting {

    /// @notice Next order id assigned by a successful commit; starts at one.
    uint64 public nextCommitId = 1;

    /// @notice Settles one cutoff-invalid open through the V3 sidecar and records its canonical receipt.
    /// @dev The external Router self-call supplies an independent rollback boundary while preserving the original
    ///      external cleaner or liquidation keeper as the receipt executor.
    function _settleRiskOffOrderWithReceipt(
        uint64 orderId,
        address executor
    ) internal returns (OrderV3Types.ExecutionResult memory result) {
        uint256 neutralMarkPrice = engine.lastMarkPrice();
        uint256 capPrice = engine.CAP_PRICE();
        if (neutralMarkPrice > capPrice) {
            neutralMarkPrice = capPrice;
        }
        // Solidity zero-initializes oracle fields that are deliberately absent from pre-oracle risk-off cleanup.
        // slither-disable-next-line uninitialized-local
        IOrderRouterExecutionHost.ItemRequest memory request;
        request.orderId = orderId;
        request.action = IOrderRouterExecutionHost.ItemAction.RiskOff;
        request.executor = executor;
        request.observedConfigHash = lifecycleBook.currentExecutionConfigHash();
        request.neutralMarkPrice = neutralMarkPrice;
        request.poolDepthUsdc = housePool.totalAssets();
        request.bountyAccountingPrice = neutralMarkPrice;
        request.bountyAccountingPublishTime = engine.lastMarkTime();
        return IOrderRouterExecutionHost(address(this)).executeOrderItemFromSidecar(request);
    }

    /// @notice Delegates canonical receipt construction for accounting already settled by liquidation.
    function _recordSettledTerminalReceipt(
        IOrderRouterExecutionHost.SettledTerminalInput memory input
    ) internal returns (OrderV3Types.ExecutionResult memory result) {
        return IOrderRouterExecutionHost(address(this)).recordSettledTerminal(input);
    }

}
