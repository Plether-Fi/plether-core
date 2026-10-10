// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {PerpFeeHandler} from "../handlers/PerpFeeHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract PerpFeeFlowInvariantTest is BasePerpInvariantTest {

    using stdStorage for StdStorage;

    PerpFeeHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpFeeHandler(usdc, mockPyth, engine, clearinghouse, router);
        handler.seedActors();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.openPosition.selector;
        selectors[1] = handler.closePosition.selector;
        selectors[2] = handler.withdrawTreasuryFees.selector;
        selectors[3] = handler.rejectZeroSizeOrder.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 0;
    }

    function _assertInvariant_FeeModelTracksTreasuryBalanceAndWithdrawals() internal view {
        assertEq(
            handler.ghostTrackedFeesUsdc(),
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            "Independent expected fees must match treasury settlement"
        );
        assertEq(
            handler.ghostAccruedFeesUsdc(),
            handler.ghostTrackedFeesUsdc() + handler.ghostWithdrawnFeesUsdc(),
            "Accrued fees must decompose into tracked plus withdrawn fees"
        );
    }

    function _assertInvariant_ProtocolAccountingSnapshotIncludesTreasuryBalance() internal view {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(
            snapshot.protocolTreasuryBalanceUsdc,
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            "Protocol snapshot treasury mismatch"
        );
        assertEq(
            snapshot.protocolTreasuryBalanceUsdc,
            handler.ghostTrackedFeesUsdc(),
            "Fee model and protocol snapshot must agree"
        );
    }

    function _assertInvariant_FeeBalanceRemainsClearinghouseCustodied() internal view {
        assertEq(
            usdc.balanceOf(engine.protocolTreasury()),
            handler.initialTreasuryWalletUsdc() + handler.ghostWithdrawnFeesUsdc(),
            "Only modeled withdrawals may move treasury fees to its wallet"
        );
        uint256 knownSettlement =
            clearinghouse.balanceUsdc(engine.protocolTreasury()) + clearinghouse.balanceUsdc(address(handler)); // The handler is the execution-bounty recipient.
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actorAt(i);
            knownSettlement += clearinghouse.balanceUsdc(actor);
            (uint256 size,,,,,,) = engine.positions(actor);
            assertEq(size, handler.ghostHasPosition(actor) ? handler.POSITION_SIZE() : 0, "Modeled position mismatch");
        }
        assertEq(
            knownSettlement, usdc.balanceOf(address(clearinghouse)), "All settlement credits need physical USDC backing"
        );
    }

    function test_FeeTransitionsAreReachableAcrossRepeatedOrders() public {
        handler.closePosition(0, 1e8); // A skipped precondition is observable, not a successful close.
        handler.openPosition(0, 2000e6);
        handler.openPosition(1, 10_000e6);
        handler.closePosition(0, 0.98e8); // Fee withheld from a gain and funded by pool cash.
        handler.closePosition(1, 1.02e8); // Fee collected from trader cash on a losing close.
        assertEq(handler.ghostAccruedFeesUsdc(), 80e6);
        _assertAllInvariants();

        handler.withdrawTreasuryFees();
        handler.openPosition(0, 2000e6);
        handler.closePosition(0, 1e8); // No price PnL; fees still accrue.
        handler.rejectZeroSizeOrder(1);
        handler.withdrawTreasuryFees();

        assertEq(handler.successfulOpens(), 3);
        assertEq(handler.successfulCloses(), 3);
        assertEq(handler.successfulWithdrawals(), 2);
        assertEq(handler.expectedRejections(), 1);
        assertEq(handler.skippedActions(), 1);
        assertEq(handler.ghostAccruedFeesUsdc(), 120e6);
        assertEq(handler.ghostWithdrawnFeesUsdc(), 120e6);
        _assertAllInvariants();
    }

    function test_FeeRoundingUsesWholeSettlementAtoms() public {
        handler.openPosition(0, 2000e6);
        handler.openPosition(1, 2000e6);
        handler.closePosition(0, 98_000_004);
        assertEq(handler.ghostAccruedFeesUsdc(), 59_600_000);
        _assertAllInvariants();
        handler.closePosition(1, 98_000_005);
        assertEq(handler.ghostAccruedFeesUsdc(), 79_200_001);
        _assertAllInvariants();
    }

    function test_FeeModelDetectsOneAtomOvercredit() public {
        handler.openPosition(0, 2000e6);
        _assertAllInvariants();
        _replaceTreasuryCredit(20e6 + 1);
        assertEq(handler.ghostTrackedFeesUsdc(), 20e6, "Injected credit must not repair the ghost");
        vm.expectRevert();
        this.invariant_IndependentFeeModelMatchesCustodyAndWithdrawals();
    }

    function test_FeeModelDetectsOneAtomUndercredit() public {
        handler.openPosition(0, 2000e6);
        _assertAllInvariants();
        _replaceTreasuryCredit(20e6 - 1);
        assertEq(handler.ghostTrackedFeesUsdc(), 20e6, "Injected debit must not repair the ghost");
        vm.expectRevert();
        this.invariant_IndependentFeeModelMatchesCustodyAndWithdrawals();
    }

    function test_FeeModelDetectsIncorrectWalletPayout() public {
        handler.openPosition(0, 2000e6);
        handler.withdrawTreasuryFees();
        _assertAllInvariants();
        usdc.burn(engine.protocolTreasury(), 1);
        vm.expectRevert();
        this.invariant_IndependentFeeModelMatchesCustodyAndWithdrawals();
    }

    function test_UnexpectedDependencyRevertIsObservable() public {
        bytes4 injectedFailure = bytes4(keccak256("InjectedDepositFailure()"));
        vm.mockCallRevert(
            address(clearinghouse),
            abi.encodeCall(clearinghouse.deposit, (handler.actorAt(0), 25_000e6)),
            abi.encodeWithSelector(injectedFailure)
        );
        handler.openPosition(0, 2000e6);
        assertEq(handler.unexpectedFailures(), 1);
        assertEq(handler.lastUnexpectedSelector(), injectedFailure);
        assertEq(handler.successfulOpens(), 0);
        vm.clearMockedCalls();
        vm.expectRevert();
        this.invariant_IndependentFeeModelMatchesCustodyAndWithdrawals();
    }

    function _replaceTreasuryCredit(
        uint256 amount
    ) internal {
        // Deliberate test-only mutation: prove an incorrect protocol fee credit cannot satisfy the independent model.
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(engine.protocolTreasury())
            .checked_write(amount);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_IndependentFeeModelMatchesCustodyAndWithdrawals() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        assertEq(handler.unexpectedFailures(), 0, "Every attempted fee transition must have a classified outcome");
        assertEq(
            handler.attempts(),
            handler.skippedActions() + handler.successfulOpens() + handler.successfulCloses()
                + handler.successfulWithdrawals() + handler.expectedRejections() + handler.unexpectedFailures(),
            "Handler outcome counters must account for every attempt"
        );
        _assertInvariant_FeeModelTracksTreasuryBalanceAndWithdrawals();
        _assertInvariant_ProtocolAccountingSnapshotIncludesTreasuryBalance();
        _assertInvariant_FeeBalanceRemainsClearinghouseCustodied();
    }

}
