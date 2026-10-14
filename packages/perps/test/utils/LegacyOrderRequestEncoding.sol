// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

/// @dev Test-only static V3 encoder. A fuzz test compares every byte against abi.encodeCall, including maximum
///      narrow-field values. The request has six direct words followed by thirteen inline ExecutionBounds words.
library LegacyOrderRequestEncoding {

    function encode(
        OrderV3Types.OrderRequest memory request
    ) internal pure returns (bytes memory payload) {
        payload = new bytes(4 + 19 * 32);
        bytes4 selector = OrderRouter.commitOrder.selector;
        assembly ("memory-safe") {
            mstore(add(payload, 32), selector)
            mcopy(add(payload, 36), request, 192)
            mcopy(add(payload, 228), mload(add(request, 192)), 416)
        }
    }

}
