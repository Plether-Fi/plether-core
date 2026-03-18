// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../../src/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "../../../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../../../src/perps/CfdTypes.sol";
import {CfdEnginePlanLib} from "../../../../src/perps/libraries/CfdEnginePlanLib.sol";

contract CfdEngineHarness is CfdEngine {

    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams
    ) CfdEngine(_usdc, _clearinghouse, _capPrice, _riskParams) {}

    function exposed_planFunding(
        bytes32 accountId,
        bool isClose,
        bool isFullClose,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEnginePlanTypes.FundingDelta memory) {
        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(accountId, lastMarkPrice, vaultDepthUsdc, 0);
        snap.vaultCashUsdc = vault.totalAssets();
        return CfdEnginePlanLib.planFunding(snap, lastMarkPrice, 0, isClose, isFullClose);
    }

}
