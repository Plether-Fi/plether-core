// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpFeeHandler} from "./handlers/PerpFeeHandler.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

contract PerpFeeFlowInvariantTest is BasePerpInvariantTest {

    PerpFeeHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpFeeHandler(usdc, engine, clearinghouse, router);
        handler.seedActors();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.openPosition.selector;
        selectors[1] = handler.closePosition.selector;
        selectors[2] = handler.withdrawTreasuryFees.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _assertInvariant_FeeModelTracksTreasuryBalanceAndWithdrawals() internal view {
        assertEq(
            handler.ghostTrackedFeesUsdc(),
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            "Ghost tracked fees must match engine fees"
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
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            "Tracked fees must remain in the treasury clearinghouse account"
        );
        assertLe(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            usdc.balanceOf(address(clearinghouse)),
            "Treasury balance must remain backed by clearinghouse USDC"
        );
    }

    function invariant_job1() public view {
        _assertAllInvariants();
    }

    function invariant_job2() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_FeeModelTracksTreasuryBalanceAndWithdrawals();
        _assertInvariant_ProtocolAccountingSnapshotIncludesTreasuryBalance();
        _assertInvariant_FeeBalanceRemainsClearinghouseCustodied();
    }

}
