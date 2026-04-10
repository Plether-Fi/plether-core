// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice LP-facing senior/junior tranche action surface.
interface IPerpsLPActions {

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

}
