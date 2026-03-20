// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface ITrancheVaultBootstrap {

    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    function bootstrapMint(uint256 shares, address receiver) external;

    function configureSeedPosition(address receiver, uint256 floorShares) external;

}
