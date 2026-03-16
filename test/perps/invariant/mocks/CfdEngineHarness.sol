// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../../src/perps/CfdTypes.sol";

contract CfdEngineHarness is CfdEngine {

    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams
    ) CfdEngine(_usdc, _clearinghouse, _capPrice, _riskParams) {}

    function exposed_previewFundingSettlement(
        bytes32 accountId,
        bool fullClose,
        uint256 vaultDepthUsdc
    ) external view returns (PreviewFundingSettlement memory) {
        CfdTypes.Position memory pos = positions[accountId];
        return _previewFundingSettlement(accountId, pos, fullClose, vaultDepthUsdc);
    }

}
