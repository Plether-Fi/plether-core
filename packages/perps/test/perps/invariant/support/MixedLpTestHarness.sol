// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MockSettlementToken} from "../../../utils/MockSettlementToken.sol";
import {PerpMixedAccountingHandler} from "../handlers/PerpMixedAccountingHandler.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

/// @dev Fixed environmental inputs for constrained-liquidity histories; no observed production state feeds the model.
contract MixedLpTestHarness is PerpMixedAccountingHandler {

    constructor(
        MockSettlementToken settlementToken_,
        MockPyth pyth_,
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        HousePool pool_,
        TrancheVault junior_,
        TrancheVault senior_,
        OrderRouter router_,
        address owner_
    )
        PerpMixedAccountingHandler(
            settlementToken_, pyth_, engine_, clearinghouse_, pool_, junior_, senior_, router_, owner_
        )
    {}

    /// @dev Deterministic admission probe, outside the generated positive-size action domain.
    function rejectZeroSizeClose(
        uint256 i
    ) external {
        _commitTrade(i, 0, 0, true);
        assertModel();
    }

    function changeRawPoolCash(
        uint256 nextCash
    ) external {
        engine.checkpointCarryIndexes();
        carry.advance(vm.getBlockTimestamp());
        if (nextCash < expectedPoolCash) {
            uint256 removed = expectedPoolCash - nextCash;
            settlementToken.burn(address(pool), removed);
            externalShockOut += removed;
        } else {
            uint256 added = nextCash - expectedPoolCash;
            settlementToken.mint(address(pool), added);
            externalShockIn += added;
        }
        expectedPoolCash = nextCash;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        assertModel();
    }

    function claimSharesExact(
        uint256 i,
        uint256 shares
    ) external {
        _claimJuniorRedeemShares(i, shares);
        assertModel();
    }

    function withdrawAssetsExact(
        uint256 i,
        uint256 assets
    ) external {
        _claimJuniorWithdraw(i, assets);
        assertModel();
    }

    /// @dev An ordinary share transfer creates a tiny second controller without synthetic epoch storage.
    function transferJuniorShares(
        uint256 from,
        uint256 shares
    ) external {
        uint256 to = 1 - from;
        assertFalse(lps[from].redeemQueued);
        assertFalse(lps[to].redeemQueued);
        assertGe(vm.getBlockTimestamp(), lps[from].lastDepositTime + 1 hours);
        assertLe(shares, lps[from].shares);
        vm.prank(lpAt(from));
        junior.transfer(lpAt(to), shares);
        lps[from].shares -= shares;
        lps[to].shares += shares;
        if (lps[to].lastDepositTime < lps[from].lastDepositTime) {
            lps[to].lastDepositTime = lps[from].lastDepositTime;
        }
        assertModel();
    }

    function redeemEpochState(
        uint256 epoch
    ) external view returns (LpRedeemEpoch memory) {
        return redeemEpochs[epoch];
    }

}

