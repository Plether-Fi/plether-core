// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderExecutionSettlement} from "@plether/perps/router/OrderExecutionSettlement.sol";

/// @title OrderExecutionOrchestrator
/// @notice Owns execution configuration read by the V3 sidecar through Router getters.
abstract contract OrderExecutionOrchestrator is OrderExecutionSettlement {

    /// @notice Initial maximum execution window accepted at commit time: 60 seconds.
    uint256 internal constant DEFAULT_MAX_EXECUTION_WINDOW_SECONDS = 60;
    /// @notice Maximum accepted execution duration in seconds; must be nonzero.
    /// @dev Expiry uses the stored absolute execution deadline; changing this setting does not rewrite pending deadlines.
    uint256 public maxExecutionWindowSeconds = DEFAULT_MAX_EXECUTION_WINDOW_SECONDS;
    /// @notice Minimum EIP-150-forwardable gas required before calling the engine.
    uint256 public minEngineGas;
    /// @notice Maximum expired or configuration-invalid head orders pruned per execution call.
    /// @dev Risk-off refunds use a separate fixed limit of 64 per execution call.
    uint256 public maxPruneOrdersPerCall;

}
