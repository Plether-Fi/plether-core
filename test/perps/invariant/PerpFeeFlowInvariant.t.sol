// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
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
        selectors[2] = handler.withdrawFees.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_FeeModelTracksAccumulatedFeesAndWithdrawals() public view {
        assertEq(
            handler.ghostTrackedFeesUsdc(), engine.accumulatedFeesUsdc(), "Ghost tracked fees must match engine fees"
        );
        assertEq(
            handler.ghostAccruedFeesUsdc(),
            handler.ghostTrackedFeesUsdc() + handler.ghostWithdrawnFeesUsdc(),
            "Accrued fees must decompose into tracked plus withdrawn fees"
        );
    }

    function invariant_ProtocolAccountingSnapshotIncludesFeeBucket() public view {
        ICfdEngine.ProtocolAccountingSnapshot memory snapshot = engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(snapshot.accumulatedFeesUsdc, engine.accumulatedFeesUsdc(), "Protocol snapshot fee bucket mismatch");
        assertEq(
            snapshot.accumulatedFeesUsdc, handler.ghostTrackedFeesUsdc(), "Fee model and protocol snapshot must agree"
        );
    }

    function invariant_FeeBucketRemainsVaultCustodied() public view {
        assertLe(engine.accumulatedFeesUsdc(), vault.totalAssets(), "Tracked fees must remain custodied by the vault");
    }

}
