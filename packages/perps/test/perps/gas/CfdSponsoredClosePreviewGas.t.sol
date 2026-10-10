// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdSponsoredClosePreviewTestFixture} from "../shared/CfdSponsoredClosePreviewFixture.sol";

contract CfdSponsoredClosePreviewGasTest is CfdSponsoredClosePreviewTestFixture {

    function testProductionRuntimeFitsEip170() public view {
        assertLe(address(previewer).code.length, 24_576);
    }

}

