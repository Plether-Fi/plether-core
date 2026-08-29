// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";

/// @title V2 execution-sidecar host surface
/// @notice Minimal Router callbacks used by the stateless V2 order-execution delegate module.
interface IOrderRouterV2ExecutionHost {

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

    /// @notice Complete input for one independently revertible V2 order attempt.
    struct ItemRequest {
        uint64 orderId;
        ItemAction action;
        address executor;
        bytes32 observedConfigHash;
        OrderV2Types.ExecutionMode executionMode;
        OrderV2Types.PriceSource priceSource;
        uint256 executionPrice;
        uint256 neutralMarkPrice;
        uint256 poolDepthUsdc;
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
        OrderV2Types.TerminalReason reason;
        OrderV2Types.ExecutionMode executionMode;
        OrderV2Types.PriceSource priceSource;
        uint256 executionPrice;
        uint256 neutralMarkPrice;
        uint256 poolDepthUsdc;
        uint64 oraclePublishTime;
        bool priceReachedEngine;
        uint256 bountyUsdc;
        address bountyRecipient;
        OrderV2Types.BountyDisposition bountyDisposition;
        OrderV2Types.FailureDetails failure;
    }

    /// @notice Canonical execution-bounty outcome returned by Router accounting.
    /// @dev Protection attempts may retain their bounty in the protection Book instead of paying the terminal caller.
    struct BountySettlement {
        uint256 bountyUsdc;
        address bountyRecipient;
        OrderV2Types.BountyDisposition bountyDisposition;
    }

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
    function getV2OrderForSidecar(
        uint64 orderId
    ) external view returns (OrderView memory orderView);

    /// @notice Executes one item in a Router self-call rollback frame.
    /// @dev The Router implementation delegates this exact calldata to the immutable execution sidecar.
    function executeV2OrderItemFromSidecar(
        ItemRequest calldata request
    ) external returns (OrderV2Types.ExecutionResult memory result);

    /// @notice Releases remaining order margin, settles or retains its bounty, and unlinks its Router record.
    /// @dev `bountyRecipient` is explicit because a Router self-call changes `msg.sender`. Failed protection attempts
    ///      return a retained disposition with a zero recipient so their one reserved bounty can fund a fresh retry.
    function settleV2OrderFromSidecar(
        uint64 orderId,
        bool success,
        OrderV2Types.TerminalReason reason,
        address bountyRecipient,
        uint256 executionPrice,
        uint256 accountingPrice,
        uint64 accountingPublishTime
    ) external returns (BountySettlement memory settlement);

    /// @notice Refunds a cutoff-invalid open, including its bounty, and unlinks its Router record.
    function refundRiskOffOrderFromSidecar(
        uint64 orderId,
        uint64 riskOffCutoff
    ) external returns (uint256 refundedBountyUsdc);

    /// @notice Finalizes lifecycle evidence after risk-off or liquidation accounting has already settled an order.
    function recordSettledTerminal(
        SettledTerminalInput calldata input
    ) external returns (OrderV2Types.ExecutionResult memory result);

    /// @notice Refunds or defers unused execution-call ETH using the Router's canonical policy.
    function sendEthFromSidecar(
        address recipient,
        uint256 amount
    ) external;

}
