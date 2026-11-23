// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {MockSettlementToken} from "./MockSettlementToken.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @dev Preserve MockSettlementToken storage while probing the Engine during its carry revenue transfer.
contract CarryNavProbeToken is MockSettlementToken {

    address private immutable ENGINE;
    bool private immutable FAIL_AFTER_READ;
    /// @dev Number of transfer callbacks in which both guarded reads were blocked.
    uint256 public blockedReads;

    constructor(
        address engine_,
        bool failAfterRead_
    ) {
        ENGINE = engine_;
        FAIL_AFTER_READ = failAfterRead_;
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (msg.sender == ENGINE) {
            (bool ok, bytes memory data) = ENGINE.staticcall(abi.encodeWithSignature("terminalNavSnapshot()"));
            require(
                !ok && bytes4(data) == ICfdEngineTypes.CfdEngine__AccountingMutationInProgress.selector,
                "transient accounting was readable"
            );
            (ok, data) = ENGINE.staticcall(abi.encodeCall(ICfdEngineCore.vpiAccountingSnapshot, ()));
            require(
                !ok && bytes4(data) == ICfdEngineTypes.CfdEngine__AccountingMutationInProgress.selector,
                "transient VPI accounting was readable"
            );
            blockedReads++;
            require(!FAIL_AFTER_READ, "downstream revert");
        }
        return super.transfer(to, amount);
    }

}
