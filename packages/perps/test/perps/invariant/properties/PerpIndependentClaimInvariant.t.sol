// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {PerpClaimModelHandler} from "../handlers/PerpClaimModelHandler.sol";
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
        selectors[0] = model.open.selector;
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

    function _check() internal view {
        model.checkModel();
        assertEq(model.unexpectedFailures(), 0, "Every modeled transition must have its expected outcome");
        assertFalse(model.cashMismatch(), "Claim transitions must reconcile settlement, pledge, and pool cash");
    }

}
