// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface ICurveMinter {

    function mint(
        address gauge
    ) external;

}
