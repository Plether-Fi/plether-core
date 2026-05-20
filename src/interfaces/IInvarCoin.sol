// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

interface IInvarCoin {

    function donateUsdc(
        uint256 usdcAmount
    ) external;

    function totalAssets() external view returns (uint256);

}
