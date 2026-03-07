// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface ICfdVault {

    function totalAssets() external view returns (uint256);
    function payOut(
        address recipient,
        uint256 amount
    ) external;

}
