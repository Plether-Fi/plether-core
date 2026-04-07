// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../CfdEngine.sol";

interface ICfdEngineLens {

    function engine() external view returns (address);

    function previewClose(
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (CfdEngine.ClosePreview memory preview);

    function simulateClose(
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEngine.ClosePreview memory preview);

    function previewLiquidation(
        bytes32 accountId,
        uint256 oraclePrice
    ) external view returns (CfdEngine.LiquidationPreview memory preview);

    function simulateLiquidation(
        bytes32 accountId,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEngine.LiquidationPreview memory preview);

}
