// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";

import {
    TerminalNavBookV2TestFixture,
    TerminalNavEngineDriver,
    TestCurveInput
} from "../../shared/TerminalNavBookV2Fixture.sol";

contract TerminalNavBookV2Test is TerminalNavBookV2TestFixture {

    function test_ConstructorAndEmptyState() public view {
        assertEq(book.ENGINE(), address(driver));
        assertEq(book.CAP_PRICE(), CAP_PRICE);
        assertEq(book.SIZE_QUANTUM(), 1e20);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(0), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), 0);

        ITerminalNavBookV2.BookState memory state = book.bookState();
        assertEq(state.capPrice, CAP_PRICE);
        assertEq(state.activeCurveCount, 0);
        assertEq(state.bookVersion, 0);
        assertEq(state.totalLots, 0);
        assertEq(state.totalEntryCostUsdcAtoms, 0);
        assertEq(state.totalEffectiveCapUsdcAtoms, 0);
        assertEq(state.base.slope, 0);
        assertEq(state.base.intercept, 0);
    }

    function test_ConstructorRejectsZeroEngineAndZeroCap() public {
        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__ZeroEngine.selector);
        new TerminalNavBookV2(address(0), CAP_PRICE);

        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__ZeroCapPrice.selector);
        new TerminalNavBookV2(address(this), 0);
    }

    function test_AuthenticationAndSynchronizationRejectUnauthorizedCaller() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__Unauthorized.selector);
        book.authenticateEngineState(address(1));

        vm.prank(address(0xBEEF));
        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__Unauthorized.selector);
        book.syncFromEngine(address(1), bytes32(0));
    }

    function test_SyncRejectsZeroAccountAndInvalidEntryBasis() public {
        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__ZeroAccount.selector);
        driver.sync(address(0), bytes32(0));

        driver.setPosition(address(1), _curveInput(1, uint144(uint256(CAP_PRICE) + 1), 0, CfdTypes.Side.SHORT));
        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__EntryCostAboveCap.selector,
                uint256(CAP_PRICE) + 1,
                uint256(CAP_PRICE)
            )
        );
        driver.sync(address(1), bytes32(0));
    }

    function test_LongUncappedCurveMatchesExactPricePnl() public {
        address account = address(1);
        uint112 lots = 1000;
        uint144 entryCost = 100_000e6;
        uint144 maximumCollectible = 100_000e6;

        _set(account, _curveInput(lots, entryCost, maximumCollectible, CfdTypes.Side.LONG));

        assertEq(book.terminalLpPriceDeltaUsdcAtoms(0), -int256(uint256(entryCost)));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(1e8), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), int256(uint256(maximumCollectible)));

        ITerminalNavBookV2.BookState memory state = book.bookState();
        assertEq(state.base.slope, int256(uint256(lots)));
        assertEq(state.base.intercept, -int256(uint256(entryCost)));
    }

    function test_LongCappedCurveUsesInclusiveBreakpoint() public {
        address account = address(1);
        uint112 lots = 1000;
        uint144 entryCost = 100_000e6;
        uint144 cap = 20_000e6;
        uint32 breakpoint = 1.2e8;

        _set(account, _curveInput(lots, entryCost, cap, CfdTypes.Side.LONG));

        assertEq(
            book.terminalLpPriceDeltaUsdcAtoms(breakpoint - 1),
            int256(uint256(lots) * uint256(breakpoint - 1)) - int256(uint256(entryCost))
        );
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(breakpoint), int256(uint256(cap)));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), int256(uint256(cap)));

        ITerminalNavBookV2.Coeff memory leaf = book.radixNode(8, breakpoint);
        assertEq(leaf.slope, -int256(uint256(lots)));
        assertEq(leaf.intercept, int256(uint256(entryCost) + uint256(cap)));
    }

    function test_ShortCappedCurveUsesInclusiveBreakpoint() public {
        address account = address(1);
        uint112 lots = 1000;
        uint144 entryCost = 100_000e6;
        uint144 cap = 20_000e6;
        uint32 breakpoint = 0.8e8;

        _set(account, _curveInput(lots, entryCost, cap, CfdTypes.Side.SHORT));

        assertEq(book.terminalLpPriceDeltaUsdcAtoms(0), int256(uint256(cap)));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(breakpoint - 1), int256(uint256(cap)));
        assertEq(
            book.terminalLpPriceDeltaUsdcAtoms(breakpoint),
            int256(uint256(entryCost)) - int256(uint256(lots) * uint256(breakpoint))
        );
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(1e8), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), -int256(100_000e6));
    }

    function test_CeilingBreakpointsAreExactForNonDivisibleNumerators() public {
        address long = address(1);
        address short = address(2);

        _set(long, _curveInput(3, 10, 2, CfdTypes.Side.LONG));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(3), -1);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(4), 2);

        _set(short, _curveInput(3, 10, 2, CfdTypes.Side.SHORT));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(2), -2); // LONG is -4 and SHORT is capped at +2.
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(3), 0); // LONG is -1 and SHORT affine value is +1.
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(4), 0); // LONG is +2 and SHORT is -2.
    }

    function test_LongZeroBreakpointIsIncludedAtMarkZero() public {
        _set(address(1), _curveInput(17, 0, 0, CfdTypes.Side.LONG));

        assertEq(book.terminalLpPriceDeltaUsdcAtoms(0), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), 0);

        ITerminalNavBookV2.Coeff memory leaf = book.radixNode(8, 0);
        assertEq(leaf.slope, -17);
        assertEq(leaf.intercept, 0);
    }

    function test_BreakpointCanEqualCapForEitherSide() public {
        uint144 longEntryCost = uint144(uint256(2) * CAP_PRICE - 2);
        _set(address(1), _curveInput(2, longEntryCost, 1, CfdTypes.Side.LONG));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE - 1), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), 1);

        uint144 shortEntryCost = uint144(uint256(2) * CAP_PRICE);
        _set(address(2), _curveInput(2, shortEntryCost, 1, CfdTypes.Side.SHORT));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE - 1), 1);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), 1); // LONG contributes one; SHORT contributes zero.
    }

    function test_ExcessCollateralIsCanonicalizedAndIdenticalReplacementIsNoOp() public {
        address account = address(1);
        TestCurveInput memory first = _curveInput(10, 500, 500, CfdTypes.Side.SHORT);
        (bytes32 firstHash, uint64 firstVersion) = _set(account, first);
        assertEq(firstVersion, 1);

        ITerminalNavBookV2.CurveRecord memory stored = book.curveOf(account);
        assertEq(stored.effectiveCapUsdcAtoms, 500);

        TestCurveInput memory sameCanonical = _curveInput(10, 500, 5000, CfdTypes.Side.SHORT);
        driver.setPosition(account, sameCanonical);
        (bytes32 secondHash, uint64 secondVersion) = driver.sync(account, firstHash);
        assertEq(secondHash, firstHash);
        assertEq(secondVersion, firstVersion);

        ITerminalNavBookV2.BookState memory state = book.bookState();
        assertEq(state.activeCurveCount, 1);
        assertEq(state.bookVersion, 1);
        assertEq(state.totalEffectiveCapUsdcAtoms, 500);
    }

    function test_CurveHashIsDeploymentAndAccountDomainSeparated() public {
        TestCurveInput memory input = _curveInput(10, 500, 100, CfdTypes.Side.SHORT);
        bytes32 accountOneHash;
        (accountOneHash,) = _set(address(1), input);
        bytes32 accountTwoHash;
        (accountTwoHash,) = _set(address(2), input);

        (TerminalNavEngineDriver otherDriver, TerminalNavBookV2 otherBook) = _deployBook(CAP_PRICE);
        otherDriver.setPosition(address(1), input);
        (bytes32 otherBookHash,) = otherDriver.sync(address(1), bytes32(0));

        assertNotEq(accountOneHash, accountTwoHash);
        assertNotEq(accountOneHash, otherBookHash);
        assertEq(otherBook.curveHashOf(address(1)), otherBookHash);
    }

    function test_StrictExpectedHashRejectsStaleLivePositionSynchronization() public {
        address account = address(1);
        TestCurveInput memory input = _curveInput(10, 500, 100, CfdTypes.Side.SHORT);
        bytes32 currentHash;
        (currentHash,) = _set(account, input);
        bytes32 staleHash = keccak256("stale");
        driver.setPosition(account, _curveInput(11, 550, 100, CfdTypes.Side.SHORT));

        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__CurveHashMismatch.selector, account, staleHash, currentHash
            )
        );
        driver.sync(account, staleHash);
    }

    function test_SyncAuthenticatesStoredHashBeforeReadingEnginePostState() public {
        address account = address(1);
        bytes32 currentHash;
        (currentHash,) = _set(account, _curveInput(10, 500, 100, CfdTypes.Side.SHORT));
        bytes32 staleHash = keccak256("stale before Engine read");
        driver.setRejectPositionReads(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__CurveHashMismatch.selector, account, staleHash, currentHash
            )
        );
        driver.sync(account, staleHash);
    }

    function test_StrictExpectedHashRejectsStalePositionRemoval() public {
        address account = address(1);
        bytes32 currentHash;
        (currentHash,) = _set(account, _curveInput(10, 500, 100, CfdTypes.Side.SHORT));
        driver.clearPosition(account);
        bytes32 staleHash = keccak256("stale removal");

        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__CurveHashMismatch.selector, account, staleHash, currentHash
            )
        );
        driver.sync(account, staleHash);
    }

    function test_OrphanStoredCurveCannotBeSkippedWithZeroExpectedHash() public {
        address account = address(1);
        bytes32 currentHash;
        (currentHash,) = _set(account, _curveInput(10, 500, 100, CfdTypes.Side.SHORT));
        driver.clearPosition(account);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__CurveHashMismatch.selector, account, bytes32(0), currentHash
            )
        );
        driver.sync(account, bytes32(0));
    }

    function test_AbsentPositionAndCurveSyncIsVersionPreservingNoOp() public {
        _set(address(2), _curveInput(10, 500, 100, CfdTypes.Side.SHORT));
        ITerminalNavBookV2.BookState memory beforeState = book.bookState();

        (bytes32 newHash, uint64 newVersion) = driver.sync(address(1), bytes32(0));

        assertEq(newHash, bytes32(0));
        assertEq(newVersion, beforeState.bookVersion);
        assertEq(book.bookState().bookVersion, beforeState.bookVersion);
    }

    function test_ReplacementAndRemovalRestoreEveryAggregate() public {
        address account = address(1);
        bytes32 firstHash;
        (firstHash,) = _set(account, _curveInput(1000, 100_000e6, 20_000e6, CfdTypes.Side.LONG));

        TestCurveInput memory replacement = _curveInput(1500, 150_000e6, 25_000e6, CfdTypes.Side.SHORT);
        driver.setPosition(account, replacement);
        (bytes32 replacementHash, uint64 replacementVersion) = driver.sync(account, firstHash);
        assertEq(replacementVersion, 2);
        _assertAggregateAt(_singleAccount(account), 0);
        _assertAggregateAt(_singleAccount(account), 1e8);
        _assertAggregateAt(_singleAccount(account), CAP_PRICE);

        (, uint64 removalVersion) = _remove(account, replacementHash);
        assertEq(removalVersion, 3);
        assertEq(book.curveHashOf(account), bytes32(0));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(0), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), 0);

        ITerminalNavBookV2.BookState memory state = book.bookState();
        assertEq(state.activeCurveCount, 0);
        assertEq(state.totalLots, 0);
        assertEq(state.totalEntryCostUsdcAtoms, 0);
        assertEq(state.totalEffectiveCapUsdcAtoms, 0);
        assertEq(state.base.slope, 0);
        assertEq(state.base.intercept, 0);
    }

    function test_DuplicateBreakpointsAggregateAndCancelExactly() public {
        TestCurveInput memory input = _curveInput(3, 10, 2, CfdTypes.Side.LONG);
        bytes32 firstHash;
        (firstHash,) = _set(address(1), input);
        _set(address(2), input);

        ITerminalNavBookV2.Coeff memory leaf = book.radixNode(8, 4);
        assertEq(leaf.slope, -6);
        assertEq(leaf.intercept, 24);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(4), 4);

        _remove(address(1), firstHash);
        leaf = book.radixNode(8, 4);
        assertEq(leaf.slope, -3);
        assertEq(leaf.intercept, 12);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(4), 2);
    }

    function test_MarkAboveCapAndInvalidRadixQueriesRevert() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__MarkPriceAboveCap.selector, uint32(CAP_PRICE + 1), CAP_PRICE
            )
        );
        book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE + 1);

        vm.expectRevert(abi.encodeWithSelector(ITerminalNavBookV2.TerminalNavBookV2__InvalidRadixNode.selector, 0, 0));
        book.radixNode(0, 0);

        vm.expectRevert(abi.encodeWithSelector(ITerminalNavBookV2.TerminalNavBookV2__InvalidRadixNode.selector, 1, 16));
        book.radixNode(1, 16);

        book.radixNode(8, type(uint32).max);
    }

    function test_PackedSlopeLimitIsAcceptedAndPlusOneGrossLotIsRejected() public {
        (TerminalNavEngineDriver maxDriver, TerminalNavBookV2 maxBook) = _deployBook(type(uint32).max);
        uint112 maximumLots = uint112(uint256(int256(type(int112).max)));
        TestCurveInput memory maximum = _curveInput(maximumLots, 0, 0, CfdTypes.Side.LONG);
        maxDriver.setPosition(address(1), maximum);
        maxDriver.sync(address(1), bytes32(0));

        maxDriver.setPosition(address(2), _curveInput(1, 0, 0, CfdTypes.Side.LONG));
        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__AggregateBoundsExceeded.selector);
        maxDriver.sync(address(2), bytes32(0));
        assertEq(maxBook.bookState().activeCurveCount, 1);
    }

    function test_PackedInterceptBudgetAcceptsExactLimitAndRejectsPlusOne() public {
        (TerminalNavEngineDriver maxDriver, TerminalNavBookV2 maxBook) = _deployBook(type(uint32).max);
        uint112 maximumLots = uint112(uint256(int256(type(int112).max)));
        uint256 entryCost = uint256(maximumLots) * uint256(type(uint32).max);
        uint256 maximumSignedIntercept = uint256(int256(type(int144).max));
        uint256 cap = maximumSignedIntercept - entryCost;
        TestCurveInput memory exact = _curveInput(maximumLots, uint144(entryCost), uint144(cap), CfdTypes.Side.SHORT);
        maxDriver.setPosition(address(1), exact);
        (bytes32 exactHash,) = maxDriver.sync(address(1), bytes32(0));

        ITerminalNavBookV2.BookState memory state = maxBook.bookState();
        assertEq(
            uint256(state.totalEntryCostUsdcAtoms) + uint256(state.totalEffectiveCapUsdcAtoms), maximumSignedIntercept
        );

        TestCurveInput memory tooLarge =
            _curveInput(maximumLots, uint144(entryCost), uint144(cap + 1), CfdTypes.Side.SHORT);
        maxDriver.setPosition(address(1), tooLarge);
        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__AggregateBoundsExceeded.selector);
        maxDriver.sync(address(1), exactHash);
    }

    function testFuzz_SingleCurveMatchesDirectModel(
        uint112 rawLots,
        uint144 rawEntryCost,
        uint144 rawCap,
        uint32 rawMark,
        bool isShort
    ) public {
        uint112 lots = uint112(bound(rawLots, 1, 1e12));
        uint256 maximumEntryCost = uint256(lots) * CAP_PRICE;
        uint144 entryCost = uint144(bound(rawEntryCost, 0, maximumEntryCost));
        uint144 cap = uint144(bound(rawCap, 0, maximumEntryCost));
        uint32 mark = uint32(bound(rawMark, 0, CAP_PRICE));
        CfdTypes.Side side = isShort ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        address account = address(1);

        _set(account, _curveInput(lots, entryCost, cap, side));

        assertEq(book.terminalLpPriceDeltaUsdcAtoms(mark), _directValue(book.curveOf(account), mark));
        _assertCriticalMarks(account);
    }

    function testFuzz_AggregateReplacementAndRemovalMatchDirectSum(
        uint256 seed,
        uint8 rawCount
    ) public {
        uint256 count = bound(rawCount, 1, 12);
        address[] memory accounts = new address[](count);

        for (uint256 i = 0; i < count; ++i) {
            address account = address(uint160(i + 1));
            accounts[i] = account;
            _set(account, _seededInput(seed, i, false));
        }
        _assertSeededMarks(accounts, seed);

        for (uint256 i = 0; i < count; ++i) {
            address account = accounts[i];
            bytes32 oldHash = book.curveHashOf(account);
            if (i % 3 == 0) {
                _remove(account, oldHash);
            } else if (i % 2 == 0) {
                driver.setPosition(account, _seededInput(seed, i, true));
                driver.sync(account, oldHash);
            }
        }
        _assertSeededMarks(accounts, uint256(keccak256(abi.encode(seed, "after"))));
    }

}
