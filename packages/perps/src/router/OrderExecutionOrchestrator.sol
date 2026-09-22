// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderExecutionSettlement} from "@plether/perps/router/OrderExecutionSettlement.sol";

/// @title OrderExecutionOrchestrator
/// @notice Owns execution configuration read by the V3 sidecar through Router getters.
abstract contract OrderExecutionOrchestrator is OrderExecutionSettlement {

    /// @notice Initial maximum pending lifetime: 60 seconds.
    uint256 internal constant DEFAULT_MAX_EXECUTION_WINDOW_SECONDS = 60;
    /// @notice Maximum accepted execution duration in seconds; must be nonzero.
    uint256 public maxExecutionWindowSeconds = DEFAULT_MAX_EXECUTION_WINDOW_SECONDS;
    /// @notice Minimum EIP-150-forwardable gas required before calling the engine.
    uint256 public minEngineGas;
    /// @notice Maximum number of expired head orders that one execution call may prune.
    uint256 public maxPruneOrdersPerCall;

}
