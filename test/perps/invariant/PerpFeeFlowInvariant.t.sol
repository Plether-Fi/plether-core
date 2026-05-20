// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {ProtocolLensViewTypes} from "../../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpFeeHandler} from "./handlers/PerpFeeHandler.sol";

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

    function invariant_FeeModelTracksTreasuryBalanceAndWithdrawals() public view {
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

    function invariant_ProtocolAccountingSnapshotIncludesTreasuryBalance() public view {
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

    function invariant_FeeBalanceRemainsClearinghouseCustodied() public view {
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

}
