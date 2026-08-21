// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

contract TerminalNavBookV2Test is Test {

    uint32 private constant CAP_PRICE = 2e8;

    TerminalNavBookV2 private book;

    function setUp() public {
        book = new TerminalNavBookV2(address(this), CAP_PRICE);
    }

    function test_ConstructorAndEmptyState() public view {
        assertEq(book.ENGINE(), address(this));
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

    function test_SetCurveRejectsUnauthorizedCaller() public {
        ITerminalNavBookV2.CurveInput memory input = _curveInput(1, 1e8, 0, CfdTypes.Side.BULL);

        vm.prank(address(0xBEEF));
        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__Unauthorized.selector);
        book.setCurve(address(1), bytes32(0), input);
    }

    function test_SetCurveRejectsZeroAccountZeroLotsAndInvalidEntryBasis() public {
        ITerminalNavBookV2.CurveInput memory valid = _curveInput(1, 1e8, 0, CfdTypes.Side.BULL);

        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__ZeroAccount.selector);
        book.setCurve(address(0), bytes32(0), valid);

        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__ZeroLots.selector);
        book.setCurve(address(1), bytes32(0), _curveInput(0, 0, 0, CfdTypes.Side.BULL));

        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__EntryCostAboveCap.selector,
                uint256(CAP_PRICE) + 1,
                uint256(CAP_PRICE)
            )
        );
        book.setCurve(address(1), bytes32(0), _curveInput(1, uint144(uint256(CAP_PRICE) + 1), 0, CfdTypes.Side.BEAR));
    }

    function test_BullUncappedCurveMatchesExactPricePnl() public {
        address account = address(1);
        uint112 lots = 1000;
        uint144 entryCost = 100_000e6;
        uint144 maximumCollectible = 100_000e6;

        _set(account, _curveInput(lots, entryCost, maximumCollectible, CfdTypes.Side.BULL));

        assertEq(book.terminalLpPriceDeltaUsdcAtoms(0), -int256(uint256(entryCost)));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(1e8), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), int256(uint256(maximumCollectible)));

        ITerminalNavBookV2.BookState memory state = book.bookState();
        assertEq(state.base.slope, int256(uint256(lots)));
        assertEq(state.base.intercept, -int256(uint256(entryCost)));
    }

    function test_BullCappedCurveUsesInclusiveBreakpoint() public {
        address account = address(1);
        uint112 lots = 1000;
        uint144 entryCost = 100_000e6;
        uint144 cap = 20_000e6;
        uint32 breakpoint = 1.2e8;

        _set(account, _curveInput(lots, entryCost, cap, CfdTypes.Side.BULL));

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

    function test_BearCappedCurveUsesInclusiveBreakpoint() public {
        address account = address(1);
        uint112 lots = 1000;
        uint144 entryCost = 100_000e6;
        uint144 cap = 20_000e6;
        uint32 breakpoint = 0.8e8;

        _set(account, _curveInput(lots, entryCost, cap, CfdTypes.Side.BEAR));

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
        address bull = address(1);
        address bear = address(2);

        _set(bull, _curveInput(3, 10, 2, CfdTypes.Side.BULL));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(3), -1);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(4), 2);

        _set(bear, _curveInput(3, 10, 2, CfdTypes.Side.BEAR));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(2), -2); // BULL is -4 and BEAR is capped at +2.
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(3), 0); // BULL is -1 and BEAR affine value is +1.
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(4), 0); // BULL is +2 and BEAR is -2.
    }

    function test_BullZeroBreakpointIsIncludedAtMarkZero() public {
        _set(address(1), _curveInput(17, 0, 0, CfdTypes.Side.BULL));

        assertEq(book.terminalLpPriceDeltaUsdcAtoms(0), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), 0);

        ITerminalNavBookV2.Coeff memory leaf = book.radixNode(8, 0);
        assertEq(leaf.slope, -17);
        assertEq(leaf.intercept, 0);
    }

    function test_BreakpointCanEqualCapForEitherSide() public {
        uint144 bullEntryCost = uint144(uint256(2) * CAP_PRICE - 2);
        _set(address(1), _curveInput(2, bullEntryCost, 1, CfdTypes.Side.BULL));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE - 1), 0);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), 1);

        uint144 bearEntryCost = uint144(uint256(2) * CAP_PRICE);
        _set(address(2), _curveInput(2, bearEntryCost, 1, CfdTypes.Side.BEAR));
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE - 1), 1);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(CAP_PRICE), 1); // BULL contributes one; BEAR contributes zero.
    }

    function test_ExcessCollateralIsCanonicalizedAndIdenticalReplacementIsNoOp() public {
        address account = address(1);
        ITerminalNavBookV2.CurveInput memory first = _curveInput(10, 500, 500, CfdTypes.Side.BEAR);
        (bytes32 firstHash, uint64 firstVersion) = _set(account, first);
        assertEq(firstVersion, 1);

        ITerminalNavBookV2.CurveRecord memory stored = book.curveOf(account);
        assertEq(stored.effectiveCapUsdcAtoms, 500);

        ITerminalNavBookV2.CurveInput memory sameCanonical = _curveInput(10, 500, 5000, CfdTypes.Side.BEAR);
        (bytes32 secondHash, uint64 secondVersion) = book.setCurve(account, firstHash, sameCanonical);
        assertEq(secondHash, firstHash);
        assertEq(secondVersion, firstVersion);

        ITerminalNavBookV2.BookState memory state = book.bookState();
        assertEq(state.activeCurveCount, 1);
        assertEq(state.bookVersion, 1);
        assertEq(state.totalEffectiveCapUsdcAtoms, 500);
    }

    function test_CurveHashIsDeploymentAndAccountDomainSeparated() public {
        ITerminalNavBookV2.CurveInput memory input = _curveInput(10, 500, 100, CfdTypes.Side.BEAR);
        bytes32 accountOneHash;
        (accountOneHash,) = _set(address(1), input);
        bytes32 accountTwoHash;
        (accountTwoHash,) = _set(address(2), input);

        TerminalNavBookV2 otherBook = new TerminalNavBookV2(address(this), CAP_PRICE);
        (bytes32 otherBookHash,) = otherBook.setCurve(address(1), bytes32(0), input);

        assertNotEq(accountOneHash, accountTwoHash);
        assertNotEq(accountOneHash, otherBookHash);
    }

    function test_StrictExpectedHashRejectsStaleSetAndRemove() public {
        address account = address(1);
        ITerminalNavBookV2.CurveInput memory input = _curveInput(10, 500, 100, CfdTypes.Side.BEAR);
        bytes32 currentHash;
        (currentHash,) = _set(account, input);
        bytes32 staleHash = keccak256("stale");

        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__CurveHashMismatch.selector, account, staleHash, currentHash
            )
        );
        book.setCurve(account, staleHash, input);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITerminalNavBookV2.TerminalNavBookV2__CurveHashMismatch.selector, account, bytes32(0), currentHash
            )
        );
        book.removeCurve(account, bytes32(0));
    }

    function test_RemoveMissingCurveReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ITerminalNavBookV2.TerminalNavBookV2__CurveNotFound.selector, address(1))
        );
        book.removeCurve(address(1), bytes32(0));
    }

    function test_ReplacementAndRemovalRestoreEveryAggregate() public {
        address account = address(1);
        bytes32 firstHash;
        (firstHash,) = _set(account, _curveInput(1000, 100_000e6, 20_000e6, CfdTypes.Side.BULL));

        ITerminalNavBookV2.CurveInput memory replacement = _curveInput(1500, 150_000e6, 25_000e6, CfdTypes.Side.BEAR);
        (bytes32 replacementHash, uint64 replacementVersion) = book.setCurve(account, firstHash, replacement);
        assertEq(replacementVersion, 2);
        _assertAggregateAt(_singleAccount(account), 0);
        _assertAggregateAt(_singleAccount(account), 1e8);
        _assertAggregateAt(_singleAccount(account), CAP_PRICE);

        uint64 removalVersion = book.removeCurve(account, replacementHash);
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
        ITerminalNavBookV2.CurveInput memory input = _curveInput(3, 10, 2, CfdTypes.Side.BULL);
        bytes32 firstHash;
        (firstHash,) = _set(address(1), input);
        _set(address(2), input);

        ITerminalNavBookV2.Coeff memory leaf = book.radixNode(8, 4);
        assertEq(leaf.slope, -6);
        assertEq(leaf.intercept, 24);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(4), 4);

        book.removeCurve(address(1), firstHash);
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
        TerminalNavBookV2 maxBook = new TerminalNavBookV2(address(this), type(uint32).max);
        uint112 maximumLots = uint112(uint256(int256(type(int112).max)));
        ITerminalNavBookV2.CurveInput memory maximum = _curveInput(maximumLots, 0, 0, CfdTypes.Side.BULL);
        maxBook.setCurve(address(1), bytes32(0), maximum);

        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__AggregateBoundsExceeded.selector);
        maxBook.setCurve(address(2), bytes32(0), _curveInput(1, 0, 0, CfdTypes.Side.BULL));
    }

    function test_PackedInterceptBudgetAcceptsExactLimitAndRejectsPlusOne() public {
        TerminalNavBookV2 maxBook = new TerminalNavBookV2(address(this), type(uint32).max);
        uint112 maximumLots = uint112(uint256(int256(type(int112).max)));
        uint256 entryCost = uint256(maximumLots) * uint256(type(uint32).max);
        uint256 maximumSignedIntercept = uint256(int256(type(int144).max));
        uint256 cap = maximumSignedIntercept - entryCost;
        ITerminalNavBookV2.CurveInput memory exact =
            _curveInput(maximumLots, uint144(entryCost), uint144(cap), CfdTypes.Side.BEAR);
        (bytes32 exactHash,) = maxBook.setCurve(address(1), bytes32(0), exact);

        ITerminalNavBookV2.BookState memory state = maxBook.bookState();
        assertEq(
            uint256(state.totalEntryCostUsdcAtoms) + uint256(state.totalEffectiveCapUsdcAtoms), maximumSignedIntercept
        );

        ITerminalNavBookV2.CurveInput memory tooLarge =
            _curveInput(maximumLots, uint144(entryCost), uint144(cap + 1), CfdTypes.Side.BEAR);
        vm.expectRevert(ITerminalNavBookV2.TerminalNavBookV2__AggregateBoundsExceeded.selector);
        maxBook.setCurve(address(1), exactHash, tooLarge);
    }

    function test_Gas_CappedInsertAndRelocationStayWithinBookGate() public {
        address account = address(1);
        uint256 gasBefore = gasleft();
        (bytes32 firstHash,) = _set(account, _curveInput(1000, 100_000e6, 20_000e6, CfdTypes.Side.BULL));
        uint256 insertGas = gasBefore - gasleft();
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLt(insertGas, 500_000);
        }

        gasBefore = gasleft();
        book.setCurve(account, firstHash, _curveInput(1000, 100_000e6, 50_000e6, CfdTypes.Side.BULL));
        uint256 relocationGas = gasBefore - gasleft();
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLt(relocationGas, 500_000);
        }
    }

    function test_Gas_MaximumRadixReadStaysWithinBookGate() public {
        TerminalNavBookV2 maxBook = new TerminalNavBookV2(address(this), type(uint32).max);
        uint256 gasBefore = gasleft();
        maxBook.terminalLpPriceDeltaUsdcAtoms(type(uint32).max);
        uint256 queryGas = gasBefore - gasleft();
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLt(queryGas, 400_000);
        }
    }

    function testFuzz_SingleCurveMatchesDirectModel(
        uint112 rawLots,
        uint144 rawEntryCost,
        uint144 rawCap,
        uint32 rawMark,
        bool isBear
    ) public {
        uint112 lots = uint112(bound(rawLots, 1, 1e12));
        uint256 maximumEntryCost = uint256(lots) * CAP_PRICE;
        uint144 entryCost = uint144(bound(rawEntryCost, 0, maximumEntryCost));
        uint144 cap = uint144(bound(rawCap, 0, maximumEntryCost));
        uint32 mark = uint32(bound(rawMark, 0, CAP_PRICE));
        CfdTypes.Side side = isBear ? CfdTypes.Side.BEAR : CfdTypes.Side.BULL;
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
                book.removeCurve(account, oldHash);
            } else if (i % 2 == 0) {
                book.setCurve(account, oldHash, _seededInput(seed, i, true));
            }
        }
        _assertSeededMarks(accounts, uint256(keccak256(abi.encode(seed, "after"))));
    }

    function _set(
        address account,
        ITerminalNavBookV2.CurveInput memory input
    ) private returns (bytes32 curveHash, uint64 bookVersion) {
        return book.setCurve(account, book.curveHashOf(account), input);
    }

    function _curveInput(
        uint112 lots,
        uint144 entryCost,
        uint144 cap,
        CfdTypes.Side side
    ) private pure returns (ITerminalNavBookV2.CurveInput memory input) {
        input = ITerminalNavBookV2.CurveInput({
            lots: lots, entryCostUsdcAtoms: entryCost, collectibleCapUsdcAtoms: cap, side: side
        });
    }

    function _seededInput(
        uint256 seed,
        uint256 index,
        bool replacement
    ) private pure returns (ITerminalNavBookV2.CurveInput memory input) {
        bytes32 entropy = keccak256(abi.encode(seed, index, replacement));
        uint112 lots = uint112((uint256(entropy) % 1e9) + 1);
        uint256 maximumEntryCost = uint256(lots) * CAP_PRICE;
        uint144 entryCost = uint144(uint256(keccak256(abi.encode(entropy, "entry"))) % (maximumEntryCost + 1));
        uint144 cap = uint144(uint256(keccak256(abi.encode(entropy, "cap"))) % (maximumEntryCost + 1));
        CfdTypes.Side side = (uint256(entropy) & 1) == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;
        return _curveInput(lots, entryCost, cap, side);
    }

    function _assertSeededMarks(
        address[] memory accounts,
        uint256 seed
    ) private view {
        _assertAggregateAt(accounts, 0);
        _assertAggregateAt(accounts, CAP_PRICE);
        for (uint256 i = 0; i < 4; ++i) {
            uint32 mark = uint32(uint256(keccak256(abi.encode(seed, i, "mark"))) % (uint256(CAP_PRICE) + 1));
            _assertAggregateAt(accounts, mark);
        }
    }

    function _assertAggregateAt(
        address[] memory accounts,
        uint32 mark
    ) private view {
        int256 expected;
        for (uint256 i = 0; i < accounts.length; ++i) {
            ITerminalNavBookV2.CurveRecord memory curve = book.curveOf(accounts[i]);
            if (curve.lots > 0) {
                expected += _directValue(curve, mark);
            }
        }
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(mark), expected);
    }

    function _assertCriticalMarks(
        address account
    ) private view {
        ITerminalNavBookV2.CurveRecord memory curve = book.curveOf(account);
        uint32 breakpoint = _breakpoint(curve);
        _assertAccountAt(account, 0);
        _assertAccountAt(account, CAP_PRICE);
        _assertAccountAt(account, breakpoint);
        if (breakpoint > 0) {
            _assertAccountAt(account, breakpoint - 1);
        }
        if (breakpoint < CAP_PRICE) {
            _assertAccountAt(account, breakpoint + 1);
        }
    }

    function _assertAccountAt(
        address account,
        uint32 mark
    ) private view {
        ITerminalNavBookV2.CurveRecord memory curve = book.curveOf(account);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(mark), _directValue(curve, mark));
    }

    function _directValue(
        ITerminalNavBookV2.CurveRecord memory curve,
        uint32 mark
    ) private pure returns (int256 value) {
        int256 markedNotional = int256(uint256(curve.lots) * uint256(mark));
        int256 entryCost = int256(uint256(curve.entryCostUsdcAtoms));
        int256 uncapped = curve.side == CfdTypes.Side.BULL ? markedNotional - entryCost : entryCost - markedNotional;
        int256 cap = int256(uint256(curve.effectiveCapUsdcAtoms));
        return uncapped > cap ? cap : uncapped;
    }

    function _breakpoint(
        ITerminalNavBookV2.CurveRecord memory curve
    ) private pure returns (uint32 breakpoint) {
        uint256 numerator;
        if (curve.side == CfdTypes.Side.BULL) {
            numerator = uint256(curve.entryCostUsdcAtoms) + uint256(curve.effectiveCapUsdcAtoms);
        } else if (curve.effectiveCapUsdcAtoms < curve.entryCostUsdcAtoms) {
            numerator = uint256(curve.entryCostUsdcAtoms) - uint256(curve.effectiveCapUsdcAtoms);
        } else {
            return 0;
        }

        uint256 widenedBreakpoint = numerator / curve.lots;
        if (numerator % curve.lots != 0) {
            ++widenedBreakpoint;
        }
        if (widenedBreakpoint > CAP_PRICE) {
            return CAP_PRICE;
        }
        breakpoint = uint32(widenedBreakpoint);
    }

    function _singleAccount(
        address account
    ) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

}
