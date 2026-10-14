// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRequestEncoding} from "../../../utils/LegacyOrderRequestEncoding.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {Test} from "forge-std/Test.sol";

contract LegacyOrderRequestEncodingTest is Test {

    function testFuzz_StaticLegacyEncodingExactlyMatchesCanonicalV3Abi(
        bytes32 clientOrderId,
        bool shortSide,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose,
        OrderV3Types.ExecutionBounds memory bounds
    ) public pure {
        OrderV3Types.OrderRequest memory request = OrderV3Types.OrderRequest({
            clientOrderId: clientOrderId,
            side: shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: targetPrice,
            isClose: isClose,
            bounds: bounds
        });
        _assertEncoding(request);
    }

    function test_StaticLegacyEncodingPreservesZeroAndMaximumNarrowFields() public pure {
        OrderV3Types.OrderRequest memory request;
        _assertEncoding(request);
        request.clientOrderId = bytes32(type(uint256).max);
        request.side = CfdTypes.Side.SHORT;
        request.sizeDelta = type(uint256).max;
        request.marginDelta = type(uint256).max;
        request.targetPrice = type(uint256).max;
        request.isClose = true;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: type(uint64).max,
            executionWindowSeconds: type(uint32).max,
            allowedExecutionModes: type(uint8).max,
            expectedConfigHash: bytes32(type(uint256).max),
            maxExecutionBountyUsdc: type(uint256).max,
            maxExecutionNotionalUsdc: type(uint256).max,
            maxGrossAccountDebitUsdc: type(uint256).max,
            maxActionChargeUsdc: type(uint256).max,
            maxExplicitFeesUsdc: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceUsdc: type(uint256).max,
            minPostPositionEquityUsdc: type(uint256).max,
            maxPostLeverageBps: type(uint32).max
        });
        _assertEncoding(request);
    }

    function _assertEncoding(
        OrderV3Types.OrderRequest memory request
    ) private pure {
        bytes memory canonical = abi.encodeCall(OrderRouter.commitOrder, (request));
        bytes memory encoded = LegacyOrderRequestEncoding.encode(request);
        assertEq(canonical.length, 4 + 19 * 32, "V3 tuple layout changes require updating the fixture encoder");
        assertEq(encoded, canonical, "test-only forwarding preserves the complete canonical public request");
    }

}
