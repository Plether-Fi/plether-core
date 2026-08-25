// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IHousePoolRedemptionMathSidecar} from "@plether/perps/interfaces/IHousePoolRedemptionMathSidecar.sol";
import {HousePoolRedemptionMathLib} from "@plether/perps/libraries/HousePoolRedemptionMathLib.sol";

/// @title HousePoolRedemptionMathSidecar
/// @notice Stateless exact redemption-pricing helpers extracted from HousePool for deployable runtime size.
/// @dev HousePool validates `implementationId()` once and stores this contract as an immutable dependency. The
///      sidecar has no storage, privileged caller, upgrade path, or ability to mutate protocol state.
contract HousePoolRedemptionMathSidecar is IHousePoolRedemptionMathSidecar {

    bytes32 internal constant IMPLEMENTATION_ID = keccak256("Plether.HousePoolRedemptionMathSidecar.v1");

    /// @inheritdoc IHousePoolRedemptionMathSidecar
    function implementationId() external pure returns (bytes32) {
        return IMPLEMENTATION_ID;
    }

    /// @inheritdoc IHousePoolRedemptionMathSidecar
    function netAssetsForShares(
        uint256 shares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) external pure returns (uint256 netAssets) {
        return
            HousePoolRedemptionMathLib.netAssetsForShares(
                shares, principal, supply, virtualAssets, virtualShares, feeBps
            );
    }

    /// @inheritdoc IHousePoolRedemptionMathSidecar
    function maxSharesForNetBudget(
        uint256 budget,
        uint256 maxShares,
        uint256 principal,
        uint256 supply,
        uint256 virtualAssets,
        uint256 virtualShares,
        uint256 feeBps
    ) external pure returns (uint256 fundedShares, uint256 netAssets) {
        return HousePoolRedemptionMathLib.maxSharesForNetBudget(
            budget, maxShares, principal, supply, virtualAssets, virtualShares, feeBps
        );
    }

}
