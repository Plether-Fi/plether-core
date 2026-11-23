// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdClosePreviewTestFixture} from "../shared/CfdClosePreviewFixture.sol";

contract CfdClosePreviewGasTest is CfdClosePreviewTestFixture {

    function test_Runtime_ClosePreviewFitsEip170() public view {
        assertLe(address(previewer).code.length, 24_576);
    }

}
