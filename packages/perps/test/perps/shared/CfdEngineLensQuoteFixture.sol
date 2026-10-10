// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

abstract contract CfdEngineLensQuoteTestFixture is BasePerpTest {

    function _quote(
        address account,
        CfdTypes.Side side,
        uint256 marginDelta,
        uint256 price
    ) internal view returns (ICfdEngineLens.MaxOpenQuote memory quote) {
        quote = ICfdEngineLens(address(engineLens))
            .quoteMaxOpen(account, side, marginDelta, price, uint64(block.timestamp));
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(account, side, quote.preview.sizeDelta, marginDelta, price, uint64(block.timestamp));
        assertEq(keccak256(abi.encode(quote.preview)), keccak256(abi.encode(preview)), "complete preview parity");
        assertEq(quote.maxSizeDelta % CfdTypes.SIZE_QUANTUM, 0, "quantum alignment");
        if (quote.maxSizeDelta == 0) {
            assertFalse(quote.preview.valid, "zero capacity must include a rejection");
            assertEq(uint256(quote.limitingReason), uint256(preview.invalidReason));
        } else {
            assertTrue(quote.preview.valid, "maximum is valid");
            assertEq(quote.preview.sizeDelta, quote.maxSizeDelta);
            ICfdEngineTypes.OpenPreview memory next = engineLens.previewOpen(
                account, side, quote.maxSizeDelta + CfdTypes.SIZE_QUANTUM, marginDelta, price, uint64(block.timestamp)
            );
            assertFalse(next.valid, "next quantum is invalid");
            assertEq(uint256(quote.limitingReason), uint256(next.invalidReason));
        }
    }

}
