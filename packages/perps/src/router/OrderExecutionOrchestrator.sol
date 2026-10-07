// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderExecutionSettlement} from "@plether/perps/router/OrderExecutionSettlement.sol";

/// @title OrderExecutionOrchestrator
/// @notice Owns execution configuration read by the V2 sidecar through Router getters.
abstract contract OrderExecutionOrchestrator is OrderExecutionSettlement {

    /// @notice Initial maximum deadline horizon at commit time: 60 seconds.
    uint256 internal constant DEFAULT_MAX_ORDER_AGE = 60;
    /// @notice Maximum seconds from a fresh commit to its deadline; finalized configuration requires a nonzero value.
    /// @dev Expiry uses the stored absolute `validUntil`; changing this setting does not rewrite pending deadlines.
    uint256 public maxOrderAge = DEFAULT_MAX_ORDER_AGE;
    /// @notice Minimum EIP-150-forwardable gas required before calling the engine.
    uint256 public minEngineGas;
    /// @notice Maximum expired or configuration-invalid head orders pruned per execution call.
    /// @dev Risk-off refunds use a separate fixed limit of 64 per execution call.
    uint256 public maxPruneOrdersPerCall;

}
