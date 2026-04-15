// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface IOrderRouterAdminHost {

    function setMaxOrderAge(
        uint256 newMaxOrderAge
    ) external;

    function setOrderExecutionStalenessLimit(
        uint256 limit
    ) external;

    function setLiquidationStalenessLimit(
        uint256 limit
    ) external;

    function setPythMaxConfidenceRatioBps(
        uint256 ratioBps
    ) external;
}
