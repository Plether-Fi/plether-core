// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {CfdClosePreviewTestBase} from "../CfdClosePreviewTestBase.sol";

interface ILegacyClosePreview {

    function previewClose(
        address engine,
        CfdTypes.Order calldata order,
        address executor,
        uint256 price,
        uint64 publishTime,
        OrderV3Types.ExecutionBounds calldata bounds
    ) external view;

}

abstract contract CfdClosePreviewTestFixture is CfdClosePreviewTestBase {}
