// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

/// @title Execution-sidecar host surface
/// @notice Minimal Router callbacks used by the stateless order-execution delegate module.
interface IOrderRouterExecutionHost {

    /// @notice Operation isolated by the Router's self-call rollback boundary.
    enum ItemAction {
        Execute,
        Expire,
        ConfigMismatch,
        RiskOff
    }

    /// @notice Router-owned queue record required by stateless orchestration.
    struct OrderView {
        CfdTypes.Order order;
        uint64 nextGlobalOrderId;
        bool pending;
    }

    /// @notice Complete input for one independently revertible order attempt.
    struct ItemRequest {
        uint64 orderId;
        ItemAction action;
        address executor;
        bytes32 observedConfigHash;
        OrderV3Types.ExecutionMode executionMode;
        OrderV3Types.PriceSource priceSource;
        uint256 executionPrice;
        uint256 neutralMarkPrice;
        uint256 poolDepthAssets;
        uint64 oraclePublishTime;
        uint256 bountyAccountingPrice;
        uint64 bountyAccountingPublishTime;
        bool oracleFrozen;
        bool openExecutionCloseOnly;
    }

    /// @notice Receipt input for an order whose Router accounting was already settled.
    /// @dev Used by risk-off and liquidation paths, which have distinct bounty disposition semantics.
    struct SettledTerminalInput {
        uint64 orderId;
        address executor;
        bytes32 observedConfigHash;
        OrderV3Types.TerminalReason reason;
        OrderV3Types.ExecutionMode executionMode;
        OrderV3Types.PriceSource priceSource;
        uint256 executionPrice;
        uint256 neutralMarkPrice;
        uint256 poolDepthAssets;
        uint64 oraclePublishTime;
        bool priceReachedEngine;
        uint256 bountyAssets;
        uint256 bountyRefundedAssets;
        address bountyRecipient;
        OrderV3Types.BountyDisposition bountyDisposition;
        OrderV3Types.FailureDetails failure;
    }

    /// @notice Canonical execution-bounty outcome returned by Router accounting.
    /// @dev Failed protection attempts may relatch for a fresh zero-bounty close; their terminal bounty is zero.
    struct BountySettlement {
        uint256 bountyAssets;
        uint256 bountyRefundedAssets;
        address bountyRecipient;
        OrderV3Types.BountyDisposition bountyDisposition;
    }

    function expireMismatchedOrderFromSidecar(
        uint64 orderId
    ) external returns (IMarginClearinghouse.BountyRecovery memory);

    function engine() external view returns (address);

    function policyEvaluator() external view returns (address);

    function lifecycleBook() external view returns (address);

    function pletherOracle() external view returns (address);

    function admin() external view returns (address);

    function nextExecuteId() external view returns (uint64);

    function nextCommitId() external view returns (uint64);

    function minEngineGas() external view returns (uint256);

    function maxPruneOrdersPerCall() external view returns (uint256);

    /// @notice Returns the Router's canonical live queue record for `orderId`.
    /// @dev The Router may restrict this callback to `msg.sender == address(this)`.
    function getOrderForSidecar(
        uint64 orderId
    ) external view returns (OrderView memory orderView);

    /// @notice Executes one item in a Router self-call rollback frame.
    /// @dev The Router implementation delegates this exact calldata to the immutable execution sidecar.
    function executeOrderItemFromSidecar(
        ItemRequest calldata request
    ) external returns (OrderV3Types.ExecutionResult memory result);

    /// @notice Releases remaining order margin, settles its bounty, and unlinks its Router record.
    /// @dev `bountyRecipient` is explicit because a Router self-call changes `msg.sender`. Failed protection attempts
    ///      may relatch for a fresh retry, but their zero-bounty order reservation still terminalizes.
    function settleOrderFromSidecar(
        uint64 orderId,
        bool success,
        OrderV3Types.TerminalReason reason,
        address bountyRecipient,
        uint256 executionPrice,
        uint256 accountingPrice,
        uint64 accountingPublishTime
    ) external returns (BountySettlement memory settlement);

    /// @notice Refunds a cutoff-invalid open, including its bounty, and unlinks its Router record.
    function refundRiskOffOrderFromSidecar(
        uint64 orderId,
        uint64 riskOffCutoff
    ) external returns (uint256 refundedBountyAssets);

    /// @notice Finalizes lifecycle evidence after risk-off or liquidation accounting has already settled an order.
    function recordSettledTerminal(
        SettledTerminalInput calldata input
    ) external returns (OrderV3Types.ExecutionResult memory result);

    /// @notice Refunds or defers unused execution-call ETH using the Router's canonical policy.
    function sendEthFromSidecar(
        address recipient,
        uint256 amount
    ) external;

}
