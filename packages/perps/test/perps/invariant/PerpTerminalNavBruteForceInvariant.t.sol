// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {
    ITerminalNavBruteForceClearinghouse,
    ITerminalNavBruteForceEngine,
    TerminalNavBruteForceModel
} from "../../utils/TerminalNavBruteForceModel.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";

/// @notice Differential invariant between the radix NAV book and direct canonical-account enumeration.
/// @dev Expected values never consume NAV-book records, hashes, coefficients, radix nodes, or account-lens output.
contract PerpTerminalNavBruteForceInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, housePool);
        handler.seedActors(50_000e6, 100_000e6);

        // Start every campaign with independently priced positions on both sides. This prevents an empty-book
        // campaign from satisfying the differential invariant vacuously before the fuzzer reaches execution.
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 20, 1000e6, 0.8e8);
        handler.executeNextOrderModelled();
        handler.commitOpenOrder(1, uint8(CfdTypes.Side.SHORT), 30, 1500e6, 1.2e8);
        handler.executeNextOrderModelled();

        // Increase at a non-divisible weighted basis, then partially close into an empty HousePool. Every campaign
        // therefore begins with exact-entry dust, a live residual curve, and a same-account deferred trader claim.
        handler.commitOpenOrder(0, uint8(CfdTypes.Side.LONG), 13, 500e6, 1.11e8);
        handler.executeNextOrderModelled();
        handler.setPoolAssets(0);
        handler.commitPartialCloseOrder(0, 13, 0.5e8);
        handler.executeNextOrderModelled();
        handler.restoreSolvencyAndClearDegradedMode();

        _assertSeedPosition(handler.actorAt(0), CfdTypes.Side.LONG);
        _assertSeedPosition(handler.actorAt(1), CfdTypes.Side.SHORT);
        _assertPartialCloseSeed();

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.commitPartialCloseOrder.selector;
        selectors[5] = handler.executeNextOrderBatch.selector;
        selectors[6] = handler.executeNextOrderModelled.selector;
        selectors[7] = handler.restoreSolvencyAndClearDegradedMode.selector;
        selectors[8] = handler.createTraderClaim.selector;
        selectors[9] = handler.settleTraderClaim.selector;
        selectors[10] = handler.fundHousePool.selector;
        selectors[11] = handler.setPoolAssets.selector;
        selectors[12] = handler.drainHousePool.selector;
        selectors[13] = handler.warpForward.selector;
        selectors[14] = handler.syncMarkNow.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_LiquidationRemovalMatchesIndependentEnumeration() public {
        address account = handler.actorAt(2);
        handler.setPoolAssets(1_000_000_000e6);
        handler.commitOpenOrder(2, uint8(CfdTypes.Side.LONG), 1000, 2000e6, 1e8);
        handler.executeNextOrderModelled();
        (uint256 sizeBefore,,,,,,) = engine.positions(account);
        assertGt(sizeBefore, 0, "Liquidation regression position must open");

        handler.liquidate(2, 1.8e8);
        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Liquidation regression position must be removed");
        invariant_TerminalNavBookMatchesIndependentCanonicalEnumeration();
    }

    function invariant_TerminalNavBookMatchesIndependentCanonicalEnumeration() public view {
        address[] memory accounts = _trackedAccounts();
        (
            TerminalNavBruteForceModel.AccountState[] memory accountStates,
            TerminalNavBruteForceModel.PortfolioTotals memory totals
        ) = TerminalNavBruteForceModel.loadPortfolio(
            ITerminalNavBruteForceEngine(address(engine)),
            ITerminalNavBruteForceClearinghouse(address(clearinghouse)),
            accounts
        );

        // These equalities prove that the handler-owned address domain is exhaustive. Without them, a missing
        // position could be absent from both the enumeration and its expected value and silently mask a mismatch.
        _assertSideEnumeration(CfdTypes.Side.LONG, totals.long);
        _assertSideEnumeration(CfdTypes.Side.SHORT, totals.short);
        assertEq(
            totals.totalTraderClaimsUsdc,
            engine.totalTraderClaimBalanceUsdc(),
            "Tracked accounts must exhaust Engine trader claims"
        );

        ITerminalNavBookV2 book = engine.terminalNavBook();
        ITerminalNavBookV2.BookState memory bookState = book.bookState();
        uint256 capPrice = engine.CAP_PRICE();
        assertEq(uint256(bookState.capPrice), capPrice, "Book and Engine price caps must match");
        assertEq(
            uint256(bookState.activeCurveCount),
            totals.activePositionCount,
            "Book curve count must match canonical active accounts"
        );
        assertEq(uint256(bookState.totalLots), totals.totalLots, "Book lots must match canonical Engine size");
        assertEq(
            uint256(bookState.totalEntryCostUsdcAtoms),
            totals.totalEntryCostUsdcAtoms,
            "Book entry basis must match exact canonical basis"
        );
        assertEq(
            uint256(bookState.totalEffectiveCapUsdcAtoms),
            totals.totalEffectiveCapUsdcAtoms,
            "Book cap budget must match canonical pledge-plus-claim caps"
        );

        uint256[] memory marks = new uint256[](10 + accountStates.length * 6);
        uint256 markCount;
        markCount = _appendMark(marks, markCount, 0, capPrice);
        markCount = _appendMark(marks, markCount, capPrice, capPrice);
        markCount = _appendMark(marks, markCount, engine.lastMarkPrice(), capPrice);
        markCount = _appendMark(marks, markCount, 1, capPrice);
        markCount = _appendMark(marks, markCount, capPrice / 3, capPrice);
        markCount = _appendMark(marks, markCount, capPrice / 2, capPrice);
        markCount = _appendMark(marks, markCount, (capPrice * 2) / 3, capPrice);
        markCount = _appendMark(marks, markCount, 0x01000000, capPrice);
        markCount = _appendMark(marks, markCount, 0x04000000, capPrice);
        markCount = _appendMark(marks, markCount, 0x08000000, capPrice);

        for (uint256 i = 0; i < accountStates.length; ++i) {
            if (!accountStates[i].active) {
                continue;
            }

            markCount = _appendNeighborhood(
                marks, markCount, TerminalNavBruteForceModel.breakEvenBoundary(accountStates[i]), capPrice
            );
            (bool hasCapTransition, uint256 capTransition) =
                TerminalNavBruteForceModel.capTransitionBoundary(accountStates[i], capPrice);
            if (hasCapTransition) {
                markCount = _appendNeighborhood(marks, markCount, capTransition, capPrice);
            }
        }

        for (uint256 i = 0; i < markCount; ++i) {
            int256 expected = TerminalNavBruteForceModel.aggregateDeltaAt(accountStates, marks[i], capPrice);
            int256 actual = book.terminalLpPriceDeltaUsdcAtoms(uint32(marks[i]));
            assertEq(actual, expected, "Radix NAV must equal direct account payoff enumeration");
        }

        ICfdEngineTypes.TerminalNavSnapshot memory snapshot = engine.terminalNavSnapshot();
        int256 expectedLiveDelta =
            TerminalNavBruteForceModel.aggregateDeltaAt(accountStates, engine.lastMarkPrice(), capPrice);
        assertEq(snapshot.terminalLpPriceDeltaUsdc, expectedLiveDelta, "Engine snapshot must expose brute-force delta");
        assertEq(uint256(snapshot.markPrice), engine.lastMarkPrice(), "Snapshot mark must be canonical Engine mark");
        assertEq(snapshot.totalTraderClaimsUsdc, totals.totalTraderClaimsUsdc, "Snapshot claims must reconcile");
        assertEq(
            snapshot.hasOpenPositions,
            totals.activePositionCount != 0,
            "Snapshot position flag must match canonical enumeration"
        );
        assertEq(snapshot.bookVersion, bookState.bookVersion, "Snapshot must expose the evaluated book version");
        assertEq(snapshot.degradedMode, engine.degradedMode(), "Snapshot degraded mode must match Engine state");
    }

    function _trackedAccounts() internal view returns (address[] memory accounts) {
        uint256 count = handler.actorCount();
        accounts = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            accounts[i] = handler.actorAt(i);
        }
    }

    function _assertSideEnumeration(
        CfdTypes.Side side,
        TerminalNavBruteForceModel.SideTotals memory expected
    ) internal view {
        (uint256 maxProfitUsdc, uint256 openInterest, uint256 entryNotional, uint256 totalMargin) =
            engine.sides(uint256(side));
        assertEq(expected.size, openInterest, "Tracked positions must exhaust side open interest");
        assertEq(
            expected.entryCostUsdcAtoms * CfdTypes.SIZE_QUANTUM,
            entryNotional,
            "Tracked exact bases must exhaust side entry notional"
        );
        assertEq(expected.maxProfitUsdc, maxProfitUsdc, "Tracked positions must exhaust side max profit");
        assertEq(expected.pnlPledgeUsdc, totalMargin, "Tracked PnL pledges must exhaust side margin");
    }

    function _appendNeighborhood(
        uint256[] memory marks,
        uint256 markCount,
        uint256 boundary,
        uint256 capPrice
    ) internal pure returns (uint256) {
        markCount = _appendMark(marks, markCount, boundary, capPrice);
        if (boundary != 0) {
            markCount = _appendMark(marks, markCount, boundary - 1, capPrice);
        }
        if (boundary < capPrice) {
            markCount = _appendMark(marks, markCount, boundary + 1, capPrice);
        }
        return markCount;
    }

    function _appendMark(
        uint256[] memory marks,
        uint256 markCount,
        uint256 mark,
        uint256 capPrice
    ) internal pure returns (uint256) {
        if (mark > capPrice) {
            return markCount;
        }
        for (uint256 i = 0; i < markCount; ++i) {
            if (marks[i] == mark) {
                return markCount;
            }
        }
        marks[markCount] = mark;
        return markCount + 1;
    }

    function _assertSeedPosition(
        address account,
        CfdTypes.Side expectedSide
    ) internal view {
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        assertGt(size, 0, "Brute-force campaign seed position must execute");
        assertEq(uint256(side), uint256(expectedSide), "Brute-force campaign seed side mismatch");
    }

    function _assertPartialCloseSeed() internal view {
        address account = handler.actorAt(0);
        (uint256 size,, uint256 displayEntryPrice,,,,) = engine.positions(account);
        uint256 lots = size / CfdTypes.SIZE_QUANTUM;
        uint256 exactEntryCostUsdcAtoms = engine.positionEntryCostUsdcAtoms(account);
        assertEq(lots, 20, "Partial-close seed must leave the intended residual lots");
        assertGt(
            exactEntryCostUsdcAtoms, lots * displayEntryPrice, "Partial-close seed must preserve exact entry-cost dust"
        );
        assertGt(
            engine.traderClaimBalanceUsdc(account),
            0,
            "Partial-close seed must leave a same-account claim on a live position"
        );
        assertFalse(engine.degradedMode(), "Campaign recovery must clear degraded mode after claim seeding");
    }

}
