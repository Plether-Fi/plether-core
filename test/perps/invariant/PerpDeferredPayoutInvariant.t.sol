// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpDeferredPayoutInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.createDeferredTraderPayout.selector;
        selectors[4] = handler.claimDeferredPayout.selector;
        selectors[5] = handler.setVaultAssets.selector;
        selectors[6] = handler.fundVault.selector;
        selectors[7] = handler.liquidate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_DeferredPayoutStatusMatchesEngineAndVaultLiquidity() public view {
        uint256 totalDeferredPayoutUsdc;
        ICfdEngine.DeferredClaim memory headClaim = engine.getDeferredClaimHead();
        bool headHasLiquidity = vault.totalAssets() > 0 && headClaim.remainingUsdc > 0;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            CfdEngine.DeferredPayoutStatus memory status = engine.getDeferredPayoutStatus(accountId, address(handler));
            uint256 deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);
            uint256 deferredClearerBountyUsdc = engine.deferredClearerBountyUsdc(address(handler));

            assertEq(status.deferredTraderPayoutUsdc, deferredPayoutUsdc, "Deferred payout status amount mismatch");
            assertEq(
                status.traderPayoutClaimableNow,
                deferredPayoutUsdc > 0 && headHasLiquidity
                    && uint8(headClaim.claimType) == uint8(ICfdEngine.DeferredClaimType.TraderPayout)
                    && headClaim.accountId == accountId,
                "Deferred payout claimability mismatch"
            );
            assertEq(
                status.liquidationBountyClaimableNow,
                deferredClearerBountyUsdc > 0 && headHasLiquidity
                    && uint8(headClaim.claimType) == uint8(ICfdEngine.DeferredClaimType.ClearerBounty)
                    && headClaim.keeper == address(handler),
                "Deferred clearer bounty claimability mismatch"
            );

            totalDeferredPayoutUsdc += deferredPayoutUsdc;
        }

        assertEq(totalDeferredPayoutUsdc, engine.totalDeferredPayoutUsdc(), "Total deferred payout mismatch");
    }

    function invariant_GhostDeferredTraderPayoutsRemainFullyModelDerived() public view {
        uint256 ghostTotalDeferredPayoutUsdc;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint256 ghostDeferredPayoutUsdc = handler.deferredTraderPayoutSnapshot(accountId);
            uint256 liveDeferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);

            assertEq(
                ghostDeferredPayoutUsdc, liveDeferredPayoutUsdc, "Ghost deferred trader payout must match engine state"
            );
            ghostTotalDeferredPayoutUsdc += ghostDeferredPayoutUsdc;
        }

        assertEq(
            handler.totalDeferredTraderPayoutSnapshot(),
            ghostTotalDeferredPayoutUsdc,
            "Ghost deferred payout total must match tracked account sum"
        );
        assertEq(
            engine.totalDeferredPayoutUsdc(), ghostTotalDeferredPayoutUsdc, "Engine deferred payout total mismatch"
        );
    }

    function invariant_TraderDeferredClaimPointersMatchTrackedTraderPayoutState() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint64 claimId = engine.traderDeferredClaimIdByAccount(accountId);
            uint256 deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);

            if (deferredPayoutUsdc == 0) {
                assertEq(claimId, 0, "Accounts without deferred payout must not retain trader deferred claim pointers");
                continue;
            }

            assertGt(claimId, 0, "Accounts with deferred payout must have a trader deferred claim pointer");
            (ICfdEngine.DeferredClaimType claimType, bytes32 claimAccountId,, uint256 remainingUsdc,,) =
                engine.deferredClaims(claimId);
            assertEq(
                uint8(claimType),
                uint8(ICfdEngine.DeferredClaimType.TraderPayout),
                "Trader deferred claim pointer must point to a trader payout node"
            );
            assertEq(claimAccountId, accountId, "Trader deferred claim pointer must belong to the tracked account");
            assertEq(remainingUsdc, deferredPayoutUsdc, "Coalesced trader deferred node must equal tracked deferred payout");
        }
    }

    function invariant_GlobalDeferredQueueLinksRemainConsistent() public view {
        uint64 claimId = engine.deferredClaimHeadId();
        uint64 prevClaimId;
        uint64 lastClaimId;
        uint256 traversedClaims;
        uint256 traderClaimCount;

        while (claimId != 0) {
            (ICfdEngine.DeferredClaimType claimType, bytes32 claimAccountId,, uint256 remainingUsdc, uint64 storedPrevClaimId, uint64 nextClaimId) = engine.deferredClaims(claimId);

            assertEq(storedPrevClaimId, prevClaimId, "Deferred queue prev-link must match traversal state");
            assertGt(remainingUsdc, 0, "Deferred queue must not retain zero-amount claims");

            if (claimType == ICfdEngine.DeferredClaimType.TraderPayout) {
                traderClaimCount++;
                assertEq(
                    engine.traderDeferredClaimIdByAccount(claimAccountId),
                    claimId,
                    "Each trader account should have exactly one coalesced deferred claim node"
                );
                assertEq(remainingUsdc, engine.deferredPayoutUsdc(claimAccountId), "Trader deferred node amount must match account state");
            } else {
                assertEq(claimAccountId, bytes32(0), "Clearer bounty claims must not carry trader account ids");
            }

            prevClaimId = claimId;
            lastClaimId = claimId;
            claimId = nextClaimId;
            traversedClaims++;

            assertLe(traversedClaims, engine.nextDeferredClaimId(), "Deferred queue traversal must remain acyclic");
        }

        assertEq(engine.deferredClaimTailId(), lastClaimId, "Deferred queue tail must equal the final traversed node");
        if (lastClaimId == 0) {
            assertEq(engine.totalDeferredPayoutUsdc(), 0, "Empty deferred queue cannot retain deferred trader payouts");
            assertEq(
                engine.totalDeferredClearerBountyUsdc(),
                0,
                "Empty deferred queue cannot retain deferred clearer bounties"
            );
        }
        assertLe(traderClaimCount, traversedClaims, "Trader payout claims must be a subset of the global queue");
    }

    function invariant_FullClosePreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, size, oraclePrice);
            if (!preview.valid) {
                continue;
            }

            uint256 totalPayoutUsdc = preview.immediatePayoutUsdc + preview.deferredPayoutUsdc;
            if (totalPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                preview.deferredPayoutUsdc > 0,
                "Close preview must choose immediate or deferred payout"
            );
            if (vault.totalAssets() >= totalPayoutUsdc) {
                assertEq(preview.deferredPayoutUsdc, 0, "Close preview must not defer when vault is liquid");
            } else {
                assertEq(preview.immediatePayoutUsdc, 0, "Close preview must fully defer when vault is illiquid");
            }
        }
    }

    function invariant_LiquidationPreviewUsesAllOrNothingVaultLiquidityGating() public view {
        uint256 oraclePrice = _previewOraclePrice();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, oraclePrice);
            uint256 totalPayoutUsdc = preview.immediatePayoutUsdc + preview.deferredPayoutUsdc;

            if (totalPayoutUsdc == 0) {
                continue;
            }

            assertEq(
                preview.immediatePayoutUsdc == 0,
                preview.deferredPayoutUsdc > 0,
                "Liquidation preview must choose immediate or deferred payout"
            );
            if (vault.totalAssets() >= totalPayoutUsdc) {
                assertEq(preview.deferredPayoutUsdc, 0, "Liquidation preview must not defer when vault is liquid");
            } else {
                assertEq(preview.immediatePayoutUsdc, 0, "Liquidation preview must fully defer when vault is illiquid");
            }
        }
    }

    function _previewOraclePrice() internal view returns (uint256) {
        uint256 price = engine.lastMarkPrice();
        return price == 0 ? 1e8 : price;
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

}
