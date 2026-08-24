// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";

/// @dev Minimal exact-state surface consumed by the immutable terminal-book coordinator.
interface ITerminalNavEngineView {

    function CAP_PRICE() external view returns (uint256);

    function clearinghouse() external view returns (address);

    function positions(
        address account
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

    function positionEntryCostUsdcAtoms(
        address account
    ) external view returns (uint256);

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256);

    function sides(
        uint256 index
    ) external view returns (uint256 maxProfitUsdc, uint256 openInterest, uint256 entryNotional, uint256 totalMargin);

    function lastMarkPrice() external view returns (uint256);

    function lastMarkTime() external view returns (uint64);

    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    function degradedMode() external view returns (bool);

}

/// @title TerminalNavBookV2
/// @notice Aggregates exact, account-local, collateral-capped terminal price PnL without iterating positions.
/// @dev Each active Engine account contributes one piecewise-affine curve over the immutable uint32 price domain. A
///      curve has a global affine base and at most one suffix event. Suffix events are accumulated in an eight-level
///      radix-16 prefix tree, making mutations and reads independent of active-position count. The immutable Engine is
///      the only writer; there is intentionally no owner, repair, migration, or arbitrary update path.
/// @custom:security-contact contact@plether.com
contract TerminalNavBookV2 is ITerminalNavBookV2 {

    /// @inheritdoc ITerminalNavBookV2
    uint256 public constant override SIZE_QUANTUM = 1e20;

    /// @notice Number of radix-16 nibbles in a uint32 breakpoint key.
    uint8 private constant RADIX_LEVELS = 8;

    /// @notice Maximum positive value representable by an `int112` coefficient.
    uint256 private constant MAX_INT112 = uint256(int256(type(int112).max));

    /// @notice Maximum positive value representable by an `int144` coefficient.
    uint256 private constant MAX_INT144 = uint256(int256(type(int144).max));

    /// @inheritdoc ITerminalNavBookV2
    address public immutable override ENGINE;

    /// @inheritdoc ITerminalNavBookV2
    uint32 public immutable override CAP_PRICE;

    /// @notice Canonical account curves, keyed by the Engine account domain.
    mapping(address account => CurveRecord curve) private _curves;

    /// @notice Hash commitments to canonical account curves; zero denotes no stored curve.
    mapping(address account => bytes32 curveHash) private _curveHashes;

    /// @notice Aggregate coefficient that applies over the complete price domain.
    Coeff private _base;

    /// @notice Sparse aggregate suffix events by radix prefix level and right-aligned prefix.
    mapping(uint8 level => mapping(uint32 prefix => Coeff coefficient)) private _radixNodes;

    /// @notice Number of canonical active account curves.
    uint64 private _activeCurveCount;

    /// @notice Monotonic effective-mutation counter.
    uint64 private _bookVersion;

    /// @notice Gross lots budget used to prove every packed aggregate slope remains representable.
    uint112 private _totalLots;

    /// @notice Gross entry-basis budget used to prove every packed aggregate intercept remains representable.
    uint144 private _totalEntryCostUsdcAtoms;

    /// @notice Gross effective collectible-cap budget used in packed-intercept safety checks.
    uint144 private _totalEffectiveCapUsdcAtoms;

    /// @notice Internal piecewise-affine representation of one canonical account curve.
    struct CurveEncoding {
        Coeff base;
        Coeff eventCoefficient;
        uint32 breakpoint;
        bool hasEvent;
    }

    /// @notice Exact Engine state used to derive one canonical account curve.
    struct EngineCurveInput {
        uint112 lots;
        uint144 entryCostUsdcAtoms;
        uint144 collectibleCapUsdcAtoms;
        CfdTypes.Side side;
    }

    /// @notice Restricts every mutation to the immutable Engine.
    modifier onlyEngine() {
        _requireEngine();
        _;
    }

    /// @notice Reverts unless the current caller is the immutable Engine.
    function _requireEngine() private view {
        if (msg.sender != ENGINE) {
            revert TerminalNavBookV2__Unauthorized();
        }
    }

    /// @notice Binds an empty terminal book to one Engine and one uint32 oracle-price domain.
    /// @param engine_ Sole address authorized to insert, replace, and remove curves.
    /// @param capPrice_ Maximum accepted mark and curve-domain endpoint, with 8 decimals.
    constructor(
        address engine_,
        uint32 capPrice_
    ) {
        if (engine_ == address(0)) {
            revert TerminalNavBookV2__ZeroEngine();
        }
        if (capPrice_ == 0) {
            revert TerminalNavBookV2__ZeroCapPrice();
        }

        ENGINE = engine_;
        CAP_PRICE = capPrice_;
    }

    /// @inheritdoc ITerminalNavBookV2
    function validateEngineBinding() external view returns (bool valid) {
        if (msg.sender != ENGINE || _activeCurveCount != 0 || _bookVersion != 0 || _totalLots != 0) {
            return false;
        }

        ITerminalNavEngineView engine = ITerminalNavEngineView(ENGINE);
        (uint256 bullMaxProfit, uint256 bullOpenInterest, uint256 bullEntryNotional, uint256 bullMargin) =
            engine.sides(0);
        (uint256 bearMaxProfit, uint256 bearOpenInterest, uint256 bearEntryNotional, uint256 bearMargin) =
            engine.sides(1);
        return engine.CAP_PRICE() == CAP_PRICE && bullMaxProfit == 0 && bullOpenInterest == 0 && bullEntryNotional == 0
            && bullMargin == 0 && bearMaxProfit == 0 && bearOpenInterest == 0 && bearEntryNotional == 0
            && bearMargin == 0 && _totalEntryCostUsdcAtoms == 0 && _totalEffectiveCapUsdcAtoms == 0 && _base.slope == 0
            && _base.intercept == 0;
    }

    /// @inheritdoc ITerminalNavBookV2
    function authenticateEngineState(
        address account
    ) external view onlyEngine returns (bytes32 expectedHash) {
        (bool hasPosition, EngineCurveInput memory input) = _curveInputFromEngine(account);
        expectedHash = hasPosition ? _curveHash(account, _canonicalize(input)) : bytes32(0);
        bytes32 actualHash = _curveHashes[account];
        if (actualHash != expectedHash) {
            revert ICfdEngineTypes.CfdEngine__TerminalNavBookHashMismatch(account, expectedHash, actualHash);
        }
    }

    /// @inheritdoc ITerminalNavBookV2
    function syncFromEngine(
        address account,
        bytes32 expectedOldHash
    ) external onlyEngine returns (bytes32 newHash, uint64 newBookVersion) {
        if (account == address(0)) {
            revert TerminalNavBookV2__ZeroAccount();
        }

        bytes32 actualOldHash = _curveHashes[account];
        if (expectedOldHash != actualOldHash) {
            revert TerminalNavBookV2__CurveHashMismatch(account, expectedOldHash, actualOldHash);
        }

        (bool hasPosition, EngineCurveInput memory input) = _curveInputFromEngine(account);
        if (!hasPosition) {
            if (actualOldHash == bytes32(0)) {
                return (bytes32(0), _bookVersion);
            }
            return (bytes32(0), _removeCurve(account, actualOldHash, _curves[account]));
        }
        return _setCurve(account, actualOldHash, input);
    }

    /// @inheritdoc ITerminalNavBookV2
    function terminalNavSnapshot() external view returns (ICfdEngineTypes.TerminalNavSnapshot memory snapshot) {
        ITerminalNavEngineView engine = ITerminalNavEngineView(ENGINE);
        (uint256 bullMaxProfit, uint256 bullOpenInterest, uint256 bullEntryNotional,) = engine.sides(0);
        (uint256 bearMaxProfit, uint256 bearOpenInterest, uint256 bearEntryNotional,) = engine.sides(1);
        uint256 totalOpenInterest = bullOpenInterest + bearOpenInterest;
        uint256 totalEntryNotional = bullEntryNotional + bearEntryNotional;
        if (
            uint256(_totalLots) * SIZE_QUANTUM != totalOpenInterest
                || uint256(_totalEntryCostUsdcAtoms) * SIZE_QUANTUM != totalEntryNotional
                || ((_activeCurveCount == 0) != (totalOpenInterest == 0))
        ) {
            revert ICfdEngineTypes.CfdEngine__InvalidTerminalNavBook();
        }

        snapshot.hasOpenPositions = totalOpenInterest != 0;
        uint256 markPrice = engine.lastMarkPrice();
        uint64 markTime = engine.lastMarkTime();
        if (markPrice > CAP_PRICE || (snapshot.hasOpenPositions && (markPrice == 0 || markTime == 0))) {
            revert ICfdEngineTypes.CfdEngine__InvalidTerminalNavBook();
        }
        if (snapshot.hasOpenPositions) {
            snapshot.terminalLpPriceDeltaUsdc = _terminalLpPriceDeltaUsdcAtoms(uint32(markPrice));
        }
        snapshot.markPrice = uint32(markPrice);
        snapshot.markTime = markTime;
        snapshot.totalTraderClaimsUsdc = engine.totalTraderClaimBalanceUsdc();
        snapshot.maxDirectionalLiabilityUsdc = bullMaxProfit > bearMaxProfit ? bullMaxProfit : bearMaxProfit;
        snapshot.bookVersion = _bookVersion;
        snapshot.degradedMode = engine.degradedMode();
    }

    function _setCurve(
        address account,
        bytes32 actualOldHash,
        EngineCurveInput memory next
    ) private returns (bytes32 newHash, uint64 newBookVersion) {
        CurveRecord memory nextRecord = _canonicalize(next);
        newHash = _curveHash(account, nextRecord);
        if (newHash == bytes32(0)) {
            revert TerminalNavBookV2__ZeroCurveHash();
        }
        if (newHash == actualOldHash) {
            return (newHash, _bookVersion);
        }

        CurveRecord memory oldRecord = _curves[account];
        bool replacing = actualOldHash != bytes32(0);
        (uint112 nextTotalLots, uint144 nextTotalEntryCost, uint144 nextTotalCap) =
            _nextTotals(oldRecord, nextRecord, replacing);

        if (replacing) {
            _replaceCurve(oldRecord, nextRecord);
        } else {
            _applyCurve(nextRecord, true);
        }

        _totalLots = nextTotalLots;
        _totalEntryCostUsdcAtoms = nextTotalEntryCost;
        _totalEffectiveCapUsdcAtoms = nextTotalCap;
        if (!replacing) {
            if (_activeCurveCount == type(uint64).max) {
                revert TerminalNavBookV2__AggregateBoundsExceeded();
            }
            unchecked {
                ++_activeCurveCount;
            }
        }

        newBookVersion = _incrementBookVersion();
        _curves[account] = nextRecord;
        _curveHashes[account] = newHash;

        emit CurveSet(
            account,
            actualOldHash,
            newHash,
            newBookVersion,
            nextRecord.lots,
            nextRecord.entryCostUsdcAtoms,
            nextRecord.effectiveCapUsdcAtoms,
            nextRecord.side
        );
    }

    function _removeCurve(
        address account,
        bytes32 actualOldHash,
        CurveRecord memory oldRecord
    ) private returns (uint64 newBookVersion) {
        _applyCurve(oldRecord, false);

        _totalLots -= oldRecord.lots;
        _totalEntryCostUsdcAtoms -= oldRecord.entryCostUsdcAtoms;
        _totalEffectiveCapUsdcAtoms -= oldRecord.effectiveCapUsdcAtoms;
        unchecked {
            --_activeCurveCount;
        }

        newBookVersion = _incrementBookVersion();
        delete _curves[account];
        delete _curveHashes[account];

        emit CurveRemoved(account, actualOldHash, newBookVersion);
    }

    /// @inheritdoc ITerminalNavBookV2
    function terminalLpPriceDeltaUsdcAtoms(
        uint32 markPrice
    ) external view returns (int256 terminalDeltaUsdcAtoms) {
        return _terminalLpPriceDeltaUsdcAtoms(markPrice);
    }

    function _terminalLpPriceDeltaUsdcAtoms(
        uint32 markPrice
    ) private view returns (int256 terminalDeltaUsdcAtoms) {
        if (markPrice > CAP_PRICE) {
            revert TerminalNavBookV2__MarkPriceAboveCap(markPrice, CAP_PRICE);
        }

        int256 aggregateSlope = int256(_base.slope);
        int256 aggregateIntercept = int256(_base.intercept);
        uint32 prefix;

        for (uint8 level = 1; level <= RADIX_LEVELS; ++level) {
            uint8 shift = uint8((RADIX_LEVELS - level) * 4);
            uint8 digit = uint8((markPrice >> shift) & 0x0f);
            uint32 childBase = prefix << 4;

            for (uint8 siblingDigit = 0; siblingDigit < digit; ++siblingDigit) {
                Coeff storage sibling = _radixNodes[level][childBase | uint32(siblingDigit)];
                aggregateSlope += int256(sibling.slope);
                aggregateIntercept += int256(sibling.intercept);
            }

            prefix = childBase | uint32(digit);
        }

        Coeff storage exactLeaf = _radixNodes[RADIX_LEVELS][prefix];
        aggregateSlope += int256(exactLeaf.slope);
        aggregateIntercept += int256(exactLeaf.intercept);

        terminalDeltaUsdcAtoms = aggregateSlope * int256(uint256(markPrice)) + aggregateIntercept;
    }

    /// @inheritdoc ITerminalNavBookV2
    function curveOf(
        address account
    ) external view returns (CurveRecord memory curve) {
        return _curves[account];
    }

    /// @inheritdoc ITerminalNavBookV2
    function curveHashOf(
        address account
    ) external view returns (bytes32 curveHash) {
        return _curveHashes[account];
    }

    /// @inheritdoc ITerminalNavBookV2
    function bookState() external view returns (BookState memory state) {
        state.capPrice = CAP_PRICE;
        state.activeCurveCount = _activeCurveCount;
        state.bookVersion = _bookVersion;
        state.totalLots = _totalLots;
        state.totalEntryCostUsdcAtoms = _totalEntryCostUsdcAtoms;
        state.totalEffectiveCapUsdcAtoms = _totalEffectiveCapUsdcAtoms;
        state.base = _base;
    }

    /// @inheritdoc ITerminalNavBookV2
    function radixNode(
        uint8 level,
        uint32 prefix
    ) external view returns (Coeff memory coefficient) {
        if (level == 0 || level > RADIX_LEVELS || (level < RADIX_LEVELS && prefix >= uint32(1) << (level * 4))) {
            revert TerminalNavBookV2__InvalidRadixNode(level, prefix);
        }
        return _radixNodes[level][prefix];
    }

    /// @notice Validates a candidate curve and removes collateral that can never be collected inside the price domain.
    function _canonicalize(
        EngineCurveInput memory next
    ) private view returns (CurveRecord memory record) {
        if (next.lots == 0) {
            revert TerminalNavBookV2__ZeroLots();
        }

        uint256 maximumEntryCostUsdcAtoms = uint256(next.lots) * uint256(CAP_PRICE);
        if (uint256(next.entryCostUsdcAtoms) > maximumEntryCostUsdcAtoms) {
            revert TerminalNavBookV2__EntryCostAboveCap(next.entryCostUsdcAtoms, maximumEntryCostUsdcAtoms);
        }

        uint256 maximumCollectibleUsdcAtoms = next.side == CfdTypes.Side.BULL
            ? maximumEntryCostUsdcAtoms - uint256(next.entryCostUsdcAtoms)
            : uint256(next.entryCostUsdcAtoms);
        uint144 effectiveCap = next.collectibleCapUsdcAtoms;
        if (uint256(effectiveCap) > maximumCollectibleUsdcAtoms) {
            effectiveCap = uint144(maximumCollectibleUsdcAtoms);
        }

        record = CurveRecord({
            lots: next.lots,
            entryCostUsdcAtoms: next.entryCostUsdcAtoms,
            effectiveCapUsdcAtoms: effectiveCap,
            side: next.side
        });
    }

    /// @notice Reconstructs one exact canonical curve candidate from live Engine and clearinghouse state.
    function _curveInputFromEngine(
        address account
    ) private view returns (bool hasPosition, EngineCurveInput memory input) {
        ITerminalNavEngineView engine = ITerminalNavEngineView(ENGINE);
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return (false, input);
        }
        if (size % SIZE_QUANTUM != 0) {
            revert ICfdEngineTypes.CfdEngine__InvalidTerminalNavBook();
        }

        uint256 lots = size / SIZE_QUANTUM;
        uint256 entryCostUsdcAtoms = engine.positionEntryCostUsdcAtoms(account);
        uint256 candidateCapUsdcAtoms = IMarginClearinghouse(engine.clearinghouse()).pnlPledgeUsdc(account)
            + engine.traderClaimBalanceUsdc(account);
        if (
            lots > type(uint112).max || entryCostUsdcAtoms > type(uint144).max
                || candidateCapUsdcAtoms > type(uint144).max
        ) {
            revert ICfdEngineTypes.CfdEngine__InvalidTerminalNavBook();
        }

        input = EngineCurveInput({
            lots: uint112(lots),
            entryCostUsdcAtoms: uint144(entryCostUsdcAtoms),
            collectibleCapUsdcAtoms: uint144(candidateCapUsdcAtoms),
            side: side
        });
        hasPosition = true;
    }

    /// @notice Computes post-replacement gross budgets before any accumulator writes occur.
    function _nextTotals(
        CurveRecord memory oldRecord,
        CurveRecord memory nextRecord,
        bool replacing
    ) private view returns (uint112 nextLots, uint144 nextEntryCost, uint144 nextCap) {
        uint256 oldLots = replacing ? uint256(oldRecord.lots) : 0;
        uint256 oldEntryCost = replacing ? uint256(oldRecord.entryCostUsdcAtoms) : 0;
        uint256 oldCap = replacing ? uint256(oldRecord.effectiveCapUsdcAtoms) : 0;

        uint256 widenedLots = uint256(_totalLots) - oldLots + uint256(nextRecord.lots);
        uint256 widenedEntryCost =
            uint256(_totalEntryCostUsdcAtoms) - oldEntryCost + uint256(nextRecord.entryCostUsdcAtoms);
        uint256 widenedCap = uint256(_totalEffectiveCapUsdcAtoms) - oldCap + uint256(nextRecord.effectiveCapUsdcAtoms);

        if (widenedLots > MAX_INT112 || widenedEntryCost + widenedCap > MAX_INT144) {
            revert TerminalNavBookV2__AggregateBoundsExceeded();
        }

        nextLots = uint112(widenedLots);
        nextEntryCost = uint144(widenedEntryCost);
        nextCap = uint144(widenedCap);
    }

    /// @notice Adds or subtracts one canonical account curve from the global base and sparse suffix accumulator.
    function _applyCurve(
        CurveRecord memory record,
        bool add
    ) private {
        CurveEncoding memory encoding = _encode(record);
        _base = _updatedCoefficient(_base, encoding.base, add);

        if (encoding.hasEvent) {
            _applyEvent(encoding.breakpoint, encoding.eventCoefficient, add);
        }
    }

    /// @notice Replaces one encoded curve while coalescing every shared radix-prefix write.
    /// @dev An unchanged breakpoint touches eight nodes once each. A relocation touches at most sixteen distinct nodes,
    ///      and fewer when the old and new keys share high-order prefixes.
    function _replaceCurve(
        CurveRecord memory oldRecord,
        CurveRecord memory nextRecord
    ) private {
        CurveEncoding memory oldEncoding = _encode(oldRecord);
        CurveEncoding memory nextEncoding = _encode(nextRecord);

        Coeff memory baseWithoutOld = _updatedCoefficient(_base, oldEncoding.base, false);
        _base = _updatedCoefficient(baseWithoutOld, nextEncoding.base, true);

        if (!oldEncoding.hasEvent) {
            if (nextEncoding.hasEvent) {
                _applyEvent(nextEncoding.breakpoint, nextEncoding.eventCoefficient, true);
            }
            return;
        }
        if (!nextEncoding.hasEvent) {
            _applyEvent(oldEncoding.breakpoint, oldEncoding.eventCoefficient, false);
            return;
        }

        uint32 oldPrefix;
        uint32 nextPrefix;
        for (uint8 level = 1; level <= RADIX_LEVELS; ++level) {
            uint8 shift = uint8((RADIX_LEVELS - level) * 4);
            oldPrefix = (oldPrefix << 4) | uint32((oldEncoding.breakpoint >> shift) & 0x0f);
            nextPrefix = (nextPrefix << 4) | uint32((nextEncoding.breakpoint >> shift) & 0x0f);

            if (oldPrefix == nextPrefix) {
                Coeff storage shared = _radixNodes[level][oldPrefix];
                Coeff memory withoutOld = _updatedCoefficient(shared, oldEncoding.eventCoefficient, false);
                Coeff memory updated = _updatedCoefficient(withoutOld, nextEncoding.eventCoefficient, true);
                _storeRadixNode(level, oldPrefix, updated);
            } else {
                _applyEventNode(level, oldPrefix, oldEncoding.eventCoefficient, false);
                _applyEventNode(level, nextPrefix, nextEncoding.eventCoefficient, true);
            }
        }
    }

    /// @notice Adds or removes one suffix event from its eight radix ancestors.
    function _applyEvent(
        uint32 breakpoint,
        Coeff memory eventCoefficient,
        bool add
    ) private {
        uint32 prefix;
        for (uint8 level = 1; level <= RADIX_LEVELS; ++level) {
            uint8 shift = uint8((RADIX_LEVELS - level) * 4);
            prefix = (prefix << 4) | uint32((breakpoint >> shift) & 0x0f);
            _applyEventNode(level, prefix, eventCoefficient, add);
        }
    }

    /// @notice Applies one event delta to one already-resolved radix node.
    function _applyEventNode(
        uint8 level,
        uint32 prefix,
        Coeff memory eventCoefficient,
        bool add
    ) private {
        Coeff storage stored = _radixNodes[level][prefix];
        Coeff memory updated = _updatedCoefficient(stored, eventCoefficient, add);
        _storeRadixNode(level, prefix, updated);
    }

    /// @notice Writes one packed radix node or deletes an exact zero to preserve storage refunds and sparse reads.
    function _storeRadixNode(
        uint8 level,
        uint32 prefix,
        Coeff memory updated
    ) private {
        if (updated.slope == 0 && updated.intercept == 0) {
            delete _radixNodes[level][prefix];
        } else {
            Coeff storage stored = _radixNodes[level][prefix];
            stored.slope = updated.slope;
            stored.intercept = updated.intercept;
        }
    }

    /// @notice Encodes `min(uncapped LP price PnL, account collectible cap)` as base plus one suffix event.
    function _encode(
        CurveRecord memory record
    ) private view returns (CurveEncoding memory encoding) {
        int112 lots = int112(record.lots);
        int144 entryCost = int144(record.entryCostUsdcAtoms);
        uint256 cap = uint256(record.effectiveCapUsdcAtoms);

        if (record.side == CfdTypes.Side.BULL) {
            encoding.base = Coeff({slope: lots, intercept: -entryCost});

            uint256 maximumCollectible = uint256(record.lots) * uint256(CAP_PRICE) - record.entryCostUsdcAtoms;
            if (cap < maximumCollectible) {
                uint256 eventIntercept = uint256(record.entryCostUsdcAtoms) + cap;
                encoding.hasEvent = true;
                encoding.breakpoint = _checkedBreakpoint(_ceilDiv(eventIntercept, record.lots));
                encoding.eventCoefficient = Coeff({slope: -lots, intercept: int144(int256(eventIntercept))});
            }
        } else if (cap == uint256(record.entryCostUsdcAtoms)) {
            encoding.base = Coeff({slope: -lots, intercept: entryCost});
        } else {
            uint256 eventIntercept = uint256(record.entryCostUsdcAtoms) - cap;
            encoding.base = Coeff({slope: 0, intercept: int144(int256(cap))});
            encoding.hasEvent = true;
            encoding.breakpoint = _checkedBreakpoint(_ceilDiv(eventIntercept, record.lots));
            encoding.eventCoefficient = Coeff({slope: -lots, intercept: int144(int256(eventIntercept))});
        }
    }

    /// @notice Applies a signed coefficient delta after widening and validates the packed result.
    function _updatedCoefficient(
        Coeff memory current,
        Coeff memory delta,
        bool add
    ) private pure returns (Coeff memory updated) {
        int256 slopeDelta = add ? int256(delta.slope) : -int256(delta.slope);
        int256 interceptDelta = add ? int256(delta.intercept) : -int256(delta.intercept);
        int256 widenedSlope = int256(current.slope) + slopeDelta;
        int256 widenedIntercept = int256(current.intercept) + interceptDelta;

        if (
            widenedSlope < type(int112).min || widenedSlope > type(int112).max || widenedIntercept < type(int144).min
                || widenedIntercept > type(int144).max
        ) {
            revert TerminalNavBookV2__CoefficientOverflow();
        }

        updated.slope = int112(widenedSlope);
        updated.intercept = int144(widenedIntercept);
    }

    /// @notice Computes a deployment- and account-domain-separated hash of a canonical curve record.
    function _curveHash(
        address account,
        CurveRecord memory record
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                CAP_PRICE,
                account,
                record.lots,
                record.entryCostUsdcAtoms,
                record.effectiveCapUsdcAtoms,
                record.side
            )
        );
    }

    /// @notice Proves a derived breakpoint is inside the immutable domain before narrowing to uint32.
    function _checkedBreakpoint(
        uint256 breakpoint
    ) private view returns (uint32 checkedBreakpoint) {
        if (breakpoint > CAP_PRICE) {
            revert TerminalNavBookV2__BreakpointAboveCap(breakpoint, CAP_PRICE);
        }
        checkedBreakpoint = uint32(breakpoint);
    }

    /// @notice Increments the monotonic version without allowing wraparound.
    function _incrementBookVersion() private returns (uint64 newBookVersion) {
        if (_bookVersion == type(uint64).max) {
            revert TerminalNavBookV2__BookVersionOverflow();
        }
        unchecked {
            newBookVersion = ++_bookVersion;
        }
    }

    /// @notice Returns `ceil(numerator / denominator)` without an overflow-prone additive round-up.
    function _ceilDiv(
        uint256 numerator,
        uint256 denominator
    ) private pure returns (uint256 quotient) {
        quotient = numerator / denominator;
        if (numerator % denominator != 0) {
            unchecked {
                ++quotient;
            }
        }
    }

    }
