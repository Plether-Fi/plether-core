// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;
import {RecordedOrderReceipts} from "../../../utils/RecordedOrderReceipts.sol";

import {NormalizePythHarness} from "../../shared/OrderRouterTestBase.sol";

contract NormalizePythFuzzTest is RecordedOrderReceipts {

    NormalizePythHarness harness;

    function setUp() public {
        harness = new NormalizePythHarness();
    }

    function testFuzz_NormalizePythPrice(
        int64 rawPrice,
        int32 expo
    ) public {
        _startRecordingLogs();
        vm.assume(rawPrice > 0);
        expo = int32(bound(int256(expo), -18, 18));

        uint256 result = harness.normalizePythPrice(rawPrice, expo);

        if (expo == -8) {
            assertEq(result, uint256(uint64(rawPrice)), "Identity at expo=-8");
        }

        if (expo > -8) {
            assertGe(result, uint256(uint64(rawPrice)), "Upscaling must not shrink value");
        }
    }

}
