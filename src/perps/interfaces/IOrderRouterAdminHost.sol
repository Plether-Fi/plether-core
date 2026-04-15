// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface IOrderRouterAdminHost {

    struct RouterConfig {
        uint256 maxOrderAge;
        uint256 orderExecutionStalenessLimit;
        uint256 liquidationStalenessLimit;
        uint256 pythMaxConfidenceRatioBps;
    }

    function applyRouterConfig(
        RouterConfig calldata config
    ) external;
}
