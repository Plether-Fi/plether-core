// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface IHousePool {

    function seniorPrincipal() external view returns (uint256);
    function juniorPrincipal() external view returns (uint256);

    function depositSenior(
        uint256 amount
    ) external;
    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external;
    function depositJunior(
        uint256 amount
    ) external;
    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external;

    function getMaxSeniorWithdraw() external view returns (uint256);
    function getMaxJuniorWithdraw() external view returns (uint256);

    function reconcile() external;

}
