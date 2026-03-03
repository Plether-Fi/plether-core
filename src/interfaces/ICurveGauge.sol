// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface ICurveGauge {

    function deposit(
        uint256 amount
    ) external;
    function withdraw(
        uint256 amount
    ) external;
    function claim_rewards() external;
    function balanceOf(
        address
    ) external view returns (uint256);

}
