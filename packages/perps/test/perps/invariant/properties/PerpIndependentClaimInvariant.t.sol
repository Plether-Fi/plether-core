// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {PerpClaimModelHandler} from "../handlers/PerpClaimModelHandler.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract PerpIndependentClaimInvariantTest is BasePerpInvariantTest {

    using stdStorage for StdStorage;

    PerpClaimModelHandler internal model;

    function setUp() public override {
        super.setUp();
        model = new PerpClaimModelHandler(engine, clearinghouse, housePool, usdc, address(router));
        // Seed each economic transition so invariant campaigns cannot pass solely through skipped calls.
        model.open(0, false);
        model.close(0, true, false);
        model.open(1, true);
        model.close(1, true, false);
        model.settle(0, 1); // Own-claim cash is insufficient while another account has a claim.
        model.open(0, false);
        model.close(0, false, true); // Loss consumes this account's claim before pledge.
        model.open(1, true);
        model.settle(1, 3); // Claim payment to a live position becomes PnL pledge.
        model.close(1, true, true);
        model.open(2, false);
        model.close(2, true, false);
        _check();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = model.openAt.selector;
        selectors[1] = model.close.selector;
        selectors[2] = model.settle.selector;
        targetSelector(FuzzSelector({addr: address(model), selectors: selectors}));
        targetContract(address(model));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_IndependentClaimsMatchPersistentEngineState() public view {
        _check();
    }

    function test_ClaimCreationConsumptionAndSettlementAreReachable() public view {
        assertGt(model.deferredCloses(), 0);
        assertGt(model.immediateCloses(), 0);
        assertGt(model.lossCloses(), 0);
        assertGt(model.claimConsumptionUsdc(), 0);
        assertGt(model.livePositionSettlements(), 0);
        assertGt(model.expectedRejections(), 0);
        _check();
    }

    function test_GlobalLiquidityBoundaryAndDuplicateSettlement() public {
        model.settle(2, 2);
        model.settle(2, 3);
        model.settle(2, 4);
        assertEq(model.expectedClaim(model.accountAt(2)), 0);
        assertEq(model.expectedRejections(), 3);
        _check();
    }

    function test_ModelDetectsIncorrectAccountClaimWithoutResynchronizing() public {
        address account = model.accountAt(2);
        uint256 expected = model.expectedClaim(account);
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account)
            .checked_write(expected + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PerpClaimModelHandler.ClaimModelMismatch.selector, account, expected, expected + 1)
        );
        model.checkModel();
        assertEq(model.expectedClaim(account), expected);
    }

    function test_ModelDetectsIncorrectAggregateClaim() public {
        uint256 expected = model.expectedTotalClaims();
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(expected + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PerpClaimModelHandler.ClaimTotalMismatch.selector, expected, expected + 1)
        );
        model.checkModel();
    }

    function test_WithdrawalReserveUsesIndependentPositionsClaimsAndBuffer() public {
        model.open(0, false);
        model.open(1, true);
        model.checkWithdrawalReserveModel();
        uint256 expected = model.expectedWithdrawalReserve();
        uint256 claims = model.expectedTotalClaims();
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(claims + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PerpClaimModelHandler.WithdrawalReserveMismatch.selector, expected, expected + 1)
        );
        model.checkWithdrawalReserveModel();
    }

    function test_ReserveTracksAsymmetricEntriesAndChangingDominantSide() public {
        // The setup ends flat with one independently generated claim. Removing it isolates position liabilities.
        assertEq(model.expectedWithdrawalReserve(), 4998e6);
        _check();
        model.settle(2, 3);
        assertEq(model.expectedWithdrawalReserve(), 0);
        _check();

        model.openAt(0, false, 31, 80_000_001);
        model.openAt(1, true, 17, 120_000_003);
        assertEq(model.expectedEntryCostUsdc(model.accountAt(0)), 2_480_000_031);
        assertEq(model.expectedEntryCostUsdc(model.accountAt(1)), 2_040_000_051);
        assertEq(model.expectedWithdrawalReserve(), 2_486_200_032, "Long endpoint plus rounded buffer dominates");
        _check();

        model.close(0, true, true);
        assertEq(model.expectedWithdrawalReserve(), 1_363_399_949, "Short endpoint now dominates");
        _check();
        model.close(1, true, false);
        assertEq(model.expectedTotalClaims(), 848_844_000, "Dust-price fee is deducted from deferred profit");
        assertEq(model.expectedWithdrawalReserve(), 848_844_000, "Flat portfolio still reserves every claim atom");
        _check();
        model.settle(1, 3);
        assertEq(model.expectedWithdrawalReserve(), 0);
        _check();
    }

    function test_ReserveRoundsBufferBelowAtAndAboveWholeAtomBoundary() public {
        model.settle(2, 3);
        assertEq(model.bufferBps(), 25, "Known answers use the configured 25-bps buffer");
        uint256[3] memory prices = [uint256(80_000_047), 80_000_400, 80_000_353];
        uint256[3] memory reserves = [uint256(1_363_400_801), 1_363_406_817, 1_363_406_017];
        // For 17 lots the liability residues modulo 400 are 399, 0, 1; a 25-bps buffer must round up.
        for (uint256 i; i < prices.length; ++i) {
            model.openAt(0, false, 17, prices[i]);
            assertEq(model.expectedWithdrawalReserve(), reserves[i]);
            _check();
            model.close(0, true, true);
            _check();
        }
    }

    function testFuzz_ReserveReconcilesGeneratedEntriesAndClaimTransitions(
        uint256 lots,
        uint256 entryPrice,
        bool shortSide
    ) public {
        model.openAt(0, shortSide, lots, entryPrice);
        uint256 actualLots = model.expectedLots(model.accountAt(0));
        assertGe(actualLots, 17);
        assertLe(actualLots, 251);
        _check();
        model.close(0, true, false);
        _check();
        model.openAt(0, !shortSide, lots, entryPrice);
        _check();
        model.close(0, false, true);
        _check();
        model.settle(0, 3);
        _check();
    }

    function test_InvariantDetectsReserveOnlyOneAtomOverstatement() public {
        _assertReserveOnlyFault(1);
    }

    function test_InvariantDetectsReserveOnlyOneAtomUnderstatement() public {
        _assertReserveOnlyFault(-1);
    }

    function _assertReserveOnlyFault(
        int256 delta
    ) private {
        model.openAt(0, false, 31, 80_000_001);
        model.openAt(1, true, 17, 120_000_003);
        _check();
        uint256 expected = model.expectedWithdrawalReserve();
        CfdEngineProtocolLens lens = model.protocolLens();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot = lens.getProtocolAccountingSnapshot();
        uint256 corrupted = delta > 0 ? expected + 1 : expected - 1;
        snapshot.withdrawalReservedUsdc = corrupted;
        vm.mockCall(address(lens), abi.encodeCall(lens.getProtocolAccountingSnapshot, ()), abi.encode(snapshot));

        // Every claim/position assertion still passes: only the reserve response has changed.
        model.checkModel();
        assertEq(model.unexpectedFailures(), 0);
        assertFalse(model.cashMismatch());
        vm.expectRevert(
            abi.encodeWithSelector(PerpClaimModelHandler.WithdrawalReserveMismatch.selector, expected, corrupted)
        );
        this.invariant_IndependentClaimsMatchPersistentEngineState();
        vm.clearMockedCalls();
        _check();
    }

    function _check() internal view {
        model.checkModel();
        model.checkWithdrawalReserveModel();
        assertEq(model.unexpectedFailures(), 0, "Every modeled transition must have its expected outcome");
        assertFalse(model.cashMismatch(), "Claim transitions must reconcile settlement, pledge, and pool cash");
    }

}
