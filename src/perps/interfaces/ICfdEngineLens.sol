// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../CfdEngine.sol";
import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";

interface ICfdEngineLens {

    function engine() external view returns (address);

    function previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (CfdEngine.ClosePreview memory preview);

    function previewOpenRevertCode(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code);

    function previewOpenFailurePolicyCategory(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category);

    function simulateClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEngine.ClosePreview memory preview);

    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (CfdEngine.LiquidationPreview memory preview);

    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEngine.LiquidationPreview memory preview);

}
