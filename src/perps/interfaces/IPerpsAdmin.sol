// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Administrative surface for perps configuration, emergency controls, and one-time setup.
interface IPerpsAdmin {

    function pause() external;

    function unpause() external;
}
