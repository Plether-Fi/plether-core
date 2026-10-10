// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import {Test} from "forge-std/Test.sol";

struct TestCurveInput {
    uint112 lots;
    uint144 entryCostUsdcAtoms;
    uint144 collectibleCapUsdcAtoms;
    CfdTypes.Side side;
}

/// @dev Minimal canonical-state driver used to exercise the book through its production synchronization API.

contract TerminalNavEngineDriver {

    uint256 public constant SIZE_QUANTUM = 1e20;

    uint256 public immutable CAP_PRICE;

    TerminalNavBookV2 public book;

    bool private _rejectPositionReads;

    struct PositionState {
        uint256 size;
        CfdTypes.Side side;
    }

    mapping(address account => PositionState position) private _positions;
    mapping(address account => uint256 entryCostUsdcAtoms) private _entryCosts;
    mapping(address account => uint256 pledgeUsdc) private _pledges;
    mapping(address account => uint256 claimUsdc) private _claims;

    constructor(
        uint32 capPrice
    ) {
        CAP_PRICE = capPrice;
    }

    function bind(
        TerminalNavBookV2 book_
    ) external {
        require(address(book) == address(0), "already bound");
        book = book_;
    }

    function setPosition(
        address account,
        TestCurveInput calldata input
    ) external {
        _positions[account] = PositionState({size: uint256(input.lots) * SIZE_QUANTUM, side: input.side});
        _entryCosts[account] = input.entryCostUsdcAtoms;
        _pledges[account] = input.collectibleCapUsdcAtoms;
        _claims[account] = 0;
    }

    function clearPosition(
        address account
    ) external {
        delete _positions[account];
        delete _entryCosts[account];
        delete _pledges[account];
        delete _claims[account];
    }

    function setRejectPositionReads(
        bool rejectPositionReads
    ) external {
        _rejectPositionReads = rejectPositionReads;
    }

    function sync(
        address account,
        bytes32 expectedOldHash
    ) external returns (bytes32 newHash, uint64 newBookVersion) {
        return book.syncFromEngine(account, expectedOldHash);
    }

    function authenticate(
        address account
    ) external view returns (bytes32 expectedHash) {
        return book.authenticateEngineState(account);
    }

    function clearinghouse() external view returns (address) {
        return address(this);
    }

    function positions(
        address account
    ) external view returns (uint256, uint256, uint256, uint256, CfdTypes.Side, uint64, int256) {
        require(!_rejectPositionReads, "unexpected Engine read");
        PositionState memory position = _positions[account];
        return (position.size, 0, 0, 0, position.side, 0, 0);
    }

    function positionEntryCostUsdcAtoms(
        address account
    ) external view returns (uint256) {
        return _entryCosts[account];
    }

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256) {
        return _claims[account];
    }

    function pnlPledgeUsdc(
        address account
    ) external view returns (uint256) {
        return _pledges[account];
    }

}

abstract contract TerminalNavBookV2TestFixture is Test {

    uint32 internal constant CAP_PRICE = 2e8;

    TerminalNavBookV2 internal book;
    TerminalNavEngineDriver internal driver;

    function setUp() public {
        driver = new TerminalNavEngineDriver(CAP_PRICE);
        book = new TerminalNavBookV2(address(driver), CAP_PRICE);
        driver.bind(book);
    }

    function _set(
        address account,
        TestCurveInput memory input
    ) internal returns (bytes32 curveHash, uint64 bookVersion) {
        driver.setPosition(account, input);
        return driver.sync(account, book.curveHashOf(account));
    }

    function _remove(
        address account,
        bytes32 expectedOldHash
    ) internal returns (bytes32 curveHash, uint64 bookVersion) {
        driver.clearPosition(account);
        return driver.sync(account, expectedOldHash);
    }

    function _curveInput(
        uint112 lots,
        uint144 entryCost,
        uint144 cap,
        CfdTypes.Side side
    ) internal pure returns (TestCurveInput memory input) {
        input = TestCurveInput({lots: lots, entryCostUsdcAtoms: entryCost, collectibleCapUsdcAtoms: cap, side: side});
    }

    function _seededInput(
        uint256 seed,
        uint256 index,
        bool replacement
    ) internal pure returns (TestCurveInput memory input) {
        bytes32 entropy = keccak256(abi.encode(seed, index, replacement));
        uint112 lots = uint112((uint256(entropy) % 1e9) + 1);
        uint256 maximumEntryCost = uint256(lots) * CAP_PRICE;
        uint144 entryCost = uint144(uint256(keccak256(abi.encode(entropy, "entry"))) % (maximumEntryCost + 1));
        uint144 cap = uint144(uint256(keccak256(abi.encode(entropy, "cap"))) % (maximumEntryCost + 1));
        CfdTypes.Side side = (uint256(entropy) & 1) == 0 ? CfdTypes.Side.LONG : CfdTypes.Side.SHORT;
        return _curveInput(lots, entryCost, cap, side);
    }

    function _deployBook(
        uint32 capPrice
    ) internal returns (TerminalNavEngineDriver newDriver, TerminalNavBookV2 newBook) {
        newDriver = new TerminalNavEngineDriver(capPrice);
        newBook = new TerminalNavBookV2(address(newDriver), capPrice);
        newDriver.bind(newBook);
    }

    function _assertSeededMarks(
        address[] memory accounts,
        uint256 seed
    ) internal view {
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
    ) internal view {
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
    ) internal view {
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
    ) internal view {
        ITerminalNavBookV2.CurveRecord memory curve = book.curveOf(account);
        assertEq(book.terminalLpPriceDeltaUsdcAtoms(mark), _directValue(curve, mark));
    }

    function _directValue(
        ITerminalNavBookV2.CurveRecord memory curve,
        uint32 mark
    ) internal pure returns (int256 value) {
        int256 markedNotional = int256(uint256(curve.lots) * uint256(mark));
        int256 entryCost = int256(uint256(curve.entryCostUsdcAtoms));
        int256 uncapped = curve.side == CfdTypes.Side.LONG ? markedNotional - entryCost : entryCost - markedNotional;
        int256 cap = int256(uint256(curve.effectiveCapUsdcAtoms));
        return uncapped > cap ? cap : uncapped;
    }

    function _breakpoint(
        ITerminalNavBookV2.CurveRecord memory curve
    ) internal pure returns (uint32 breakpoint) {
        uint256 numerator;
        if (curve.side == CfdTypes.Side.LONG) {
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
    ) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

}
