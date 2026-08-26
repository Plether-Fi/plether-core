// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {TerminalNavBruteForceModel} from "../utils/TerminalNavBruteForceModel.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {Test} from "forge-std/Test.sol";

contract TerminalNavBruteForceModelTest is Test {

    uint256 private constant CAP_PRICE = 300;

    function test_KnownLongPayoffCapsOnlyPositiveLpRecovery() public pure {
        TerminalNavBruteForceModel.AccountState memory state = _state(CfdTypes.Side.LONG, 2, 200, 30);

        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, 80), -40);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, 100), 0);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, 110), 20);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, 120), 30);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, CAP_PRICE), 30);
    }

    function test_KnownShortPayoffCapsOnlyPositiveLpRecovery() public pure {
        TerminalNavBruteForceModel.AccountState memory state = _state(CfdTypes.Side.SHORT, 2, 200, 30);

        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, 80), 30);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, 100), 0);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, 110), -20);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, 120), -40);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(state, CAP_PRICE), -400);
    }

    function test_KnownAccountCapDistributionChangesAggregateValue() public pure {
        TerminalNavBruteForceModel.AccountState[] memory states = new TerminalNavBruteForceModel.AccountState[](2);
        states[0] = _state(CfdTypes.Side.LONG, 1, 100, 10);
        states[1] = _state(CfdTypes.Side.SHORT, 1, 110, 100);

        assertEq(TerminalNavBruteForceModel.aggregateDeltaAt(states, 200, CAP_PRICE), -80);

        states[0].collectibleCapUsdcAtoms = 100;
        states[0].effectiveCapUsdcAtoms = 100;
        states[1].collectibleCapUsdcAtoms = 10;
        states[1].effectiveCapUsdcAtoms = 10;
        assertEq(TerminalNavBruteForceModel.aggregateDeltaAt(states, 200, CAP_PRICE), 10);
    }

    function test_KnownBoundariesPreserveEntryDust() public pure {
        TerminalNavBruteForceModel.AccountState memory long = _state(CfdTypes.Side.LONG, 3, 10, 2);
        TerminalNavBruteForceModel.AccountState memory short = _state(CfdTypes.Side.SHORT, 3, 10, 2);

        assertEq(TerminalNavBruteForceModel.breakEvenBoundary(long), 4);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(long, 3), -1);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(long, 4), 2);

        (bool longHasTransition, uint256 longBoundary) =
            TerminalNavBruteForceModel.capTransitionBoundary(long, CAP_PRICE);
        assertTrue(longHasTransition);
        assertEq(longBoundary, 4);

        (bool shortHasTransition, uint256 shortBoundary) =
            TerminalNavBruteForceModel.capTransitionBoundary(short, CAP_PRICE);
        assertTrue(shortHasTransition);
        assertEq(shortBoundary, 3);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(short, 2), 2);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(short, 3), 1);
        assertEq(TerminalNavBruteForceModel.accountDeltaAt(short, 4), -2);
    }

    function _state(
        CfdTypes.Side side,
        uint256 lots,
        uint256 entryCostUsdcAtoms,
        uint256 collectibleCapUsdcAtoms
    ) private pure returns (TerminalNavBruteForceModel.AccountState memory state) {
        state.active = true;
        state.side = side;
        state.lots = lots;
        state.size = lots * CfdTypes.SIZE_QUANTUM;
        state.entryCostUsdcAtoms = entryCostUsdcAtoms;
        state.collectibleCapUsdcAtoms = collectibleCapUsdcAtoms;
        state.effectiveCapUsdcAtoms = collectibleCapUsdcAtoms;
    }

}
