// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @title Exact terminal price-PnL book for the V2 perps engine
/// @notice Maintains a position-count-independent aggregate of account-local, collateral-capped price PnL.
/// @dev Prices use 8 decimals. `lots` count exact 100-token position quanta and monetary fields use native
///      6-decimal USDC atoms. Positive terminal values are collectible by LPs; negative values are owed to traders.
interface ITerminalNavBookV2 {

    /// @notice Packed affine coefficient used by the base curve and sparse radix accumulator.
    /// @param slope USDC-atom change per one 8-decimal price atom.
    /// @param intercept Constant USDC-atom term.
    struct Coeff {
        int112 slope;
        int144 intercept;
    }

    /// @notice Canonical Engine input for one account's terminal price-PnL curve.
    /// @param lots Number of exact 100-token position quanta.
    /// @param entryCostUsdcAtoms Exact remaining position basis in 6-decimal USDC atoms.
    /// @param collectibleCapUsdcAtoms Dedicated PnL pledge plus same-account nettable claim, in USDC atoms.
    /// @param side Position direction under the protocol's USD-strength oracle convention.
    struct CurveInput {
        uint112 lots;
        uint144 entryCostUsdcAtoms;
        uint144 collectibleCapUsdcAtoms;
        CfdTypes.Side side;
    }

    /// @notice Stored canonical account curve after unreachable collateral has been removed from its cap.
    /// @param lots Number of exact 100-token position quanta.
    /// @param entryCostUsdcAtoms Exact remaining position basis in 6-decimal USDC atoms.
    /// @param effectiveCapUsdcAtoms Reachable collectible cap in 6-decimal USDC atoms.
    /// @param side Position direction under the protocol's USD-strength oracle convention.
    struct CurveRecord {
        uint112 lots;
        uint144 entryCostUsdcAtoms;
        uint144 effectiveCapUsdcAtoms;
        CfdTypes.Side side;
    }

    /// @notice Aggregate state used for Engine wiring, monitoring, and parity checks.
    /// @param capPrice Maximum accepted mark price, with 8 decimals.
    /// @param activeCurveCount Number of accounts with a stored curve.
    /// @param bookVersion Monotonic version incremented by each effective curve mutation.
    /// @param totalLots Gross active 100-token lots across all accounts.
    /// @param totalEntryCostUsdcAtoms Gross exact active entry basis in USDC atoms.
    /// @param totalEffectiveCapUsdcAtoms Gross canonical collectible cap in USDC atoms.
    /// @param base Aggregate affine coefficient applied at every mark before suffix events.
    struct BookState {
        uint32 capPrice;
        uint64 activeCurveCount;
        uint64 bookVersion;
        uint112 totalLots;
        uint144 totalEntryCostUsdcAtoms;
        uint144 totalEffectiveCapUsdcAtoms;
        Coeff base;
    }

    /// @notice The caller is not the immutable Engine.
    error TerminalNavBookV2__Unauthorized();
    /// @notice Deployment supplied a zero Engine address.
    error TerminalNavBookV2__ZeroEngine();
    /// @notice Deployment supplied a zero price cap.
    error TerminalNavBookV2__ZeroCapPrice();
    /// @notice A curve mutation supplied the zero account address.
    error TerminalNavBookV2__ZeroAccount();
    /// @notice A curve mutation supplied zero 100-token lots.
    error TerminalNavBookV2__ZeroLots();
    /// @notice Exact entry basis exceeds the position's notional at the configured price cap.
    /// @param entryCostUsdcAtoms Supplied exact entry basis.
    /// @param maximumEntryCostUsdcAtoms Maximum representable basis for the supplied lots.
    error TerminalNavBookV2__EntryCostAboveCap(uint256 entryCostUsdcAtoms, uint256 maximumEntryCostUsdcAtoms);
    /// @notice The Engine's expected account curve does not match canonical book state.
    /// @param account Account whose curve was checked.
    /// @param expectedHash Hash supplied by the Engine.
    /// @param actualHash Hash stored by the book, or zero when no curve exists.
    error TerminalNavBookV2__CurveHashMismatch(address account, bytes32 expectedHash, bytes32 actualHash);
    /// @notice A canonical curve produced the reserved zero hash sentinel.
    error TerminalNavBookV2__ZeroCurveHash();
    /// @notice Curve removal was requested for an account with no canonical curve.
    /// @param account Account without a curve.
    error TerminalNavBookV2__CurveNotFound(address account);
    /// @notice A terminal query supplied a mark above the immutable price cap.
    /// @param markPrice Supplied 8-decimal mark.
    /// @param capPrice Immutable maximum mark.
    error TerminalNavBookV2__MarkPriceAboveCap(uint32 markPrice, uint32 capPrice);
    /// @notice Gross active lots or entry-plus-cap budgets exceed packed coefficient safety bounds.
    error TerminalNavBookV2__AggregateBoundsExceeded();
    /// @notice An accumulator coefficient could not be represented by its packed signed field.
    error TerminalNavBookV2__CoefficientOverflow();
    /// @notice An internally derived curve breakpoint escaped the immutable price domain.
    error TerminalNavBookV2__BreakpointAboveCap(uint256 breakpoint, uint32 capPrice);
    /// @notice The monotonic mutation version exhausted its uint64 representation.
    error TerminalNavBookV2__BookVersionOverflow();
    /// @notice A diagnostic radix-node query supplied an invalid level or prefix.
    error TerminalNavBookV2__InvalidRadixNode(uint8 level, uint32 prefix);

    /// @notice Emitted after an account's canonical curve is inserted or effectively changed.
    event CurveSet(
        address indexed account,
        bytes32 indexed oldCurveHash,
        bytes32 indexed newCurveHash,
        uint64 bookVersion,
        uint112 lots,
        uint144 entryCostUsdcAtoms,
        uint144 effectiveCapUsdcAtoms,
        CfdTypes.Side side
    );

    /// @notice Emitted after an account's canonical curve is removed.
    event CurveRemoved(address indexed account, bytes32 indexed oldCurveHash, uint64 bookVersion);

    /// @notice Exact synthetic-token size represented by one `lots` unit.
    function SIZE_QUANTUM() external view returns (uint256);

    /// @notice Immutable Engine authorized to mutate the book.
    function ENGINE() external view returns (address);

    /// @notice Immutable maximum accepted 8-decimal mark price.
    function CAP_PRICE() external view returns (uint32);

    /// @notice Returns whether this empty book is correctly bound to its calling Engine and canonical price domain.
    /// @dev Used once by the Engine during wiring. A live or previously mutated book is never a valid candidate.
    function validateEngineBinding() external view returns (bool valid);

    /// @notice Authenticates the stored curve against the Engine's exact pre-mutation account state.
    /// @dev Callable only by the immutable Engine. Reverts with the Engine hash-mismatch error on divergence.
    function authenticateEngineState(
        address account
    ) external view returns (bytes32 expectedHash);

    /// @notice Rebuilds and applies an account curve from exact post-mutation Engine and clearinghouse state.
    /// @dev Callable only by the immutable Engine. Removes the curve when the account no longer has a position.
    function syncFromEngine(
        address account,
        bytes32 expectedOldHash
    ) external returns (bytes32 newHash, uint64 newBookVersion);

    /// @notice Builds the authenticated Engine-level terminal NAV snapshot from the book and bound Engine getters.
    function terminalNavSnapshot() external view returns (ICfdEngineTypes.TerminalNavSnapshot memory snapshot);

    /// @notice Inserts or replaces one account's canonical curve.
    /// @dev Reverts unless `expectedOldHash` equals `curveHashOf(account)`. A canonically identical replacement is a
    ///      no-op and does not increment the version. The book reconstructs and removes old coefficients from storage;
    ///      callers never supply old curve values.
    /// @param account Canonical one-position-per-account Engine account.
    /// @param expectedOldHash Engine-observed pre-mutation curve hash, or zero for a new curve.
    /// @param next Exact lots, basis, candidate collateral cap, and side after the Engine mutation.
    /// @return newHash Hash of the stored canonical curve.
    /// @return newBookVersion Current book version, incremented only when canonical state changed.
    function setCurve(
        address account,
        bytes32 expectedOldHash,
        CurveInput calldata next
    ) external returns (bytes32 newHash, uint64 newBookVersion);

    /// @notice Removes one account's canonical curve.
    /// @dev Reverts for a missing curve or unless `expectedOldHash` equals `curveHashOf(account)`.
    /// @param account Canonical Engine account whose position no longer exists.
    /// @param expectedOldHash Engine-observed pre-mutation curve hash.
    /// @return newBookVersion Book version after removal.
    function removeCurve(
        address account,
        bytes32 expectedOldHash
    ) external returns (uint64 newBookVersion);

    /// @notice Returns aggregate collateral-capped LP price PnL at an exact mark.
    /// @dev Positive output is collectible by LPs; negative output is owed to traders. Runtime is independent of the
    ///      active curve count and performs at most 121 sparse-radix node reads.
    /// @param markPrice Exact cached mark in 8-decimal price atoms, no greater than `CAP_PRICE`.
    /// @return terminalDeltaUsdcAtoms Signed terminal price delta in 6-decimal USDC atoms.
    function terminalLpPriceDeltaUsdcAtoms(
        uint32 markPrice
    ) external view returns (int256 terminalDeltaUsdcAtoms);

    /// @notice Returns one account's stored canonical curve; a missing curve is all zeroes.
    function curveOf(
        address account
    ) external view returns (CurveRecord memory curve);

    /// @notice Returns one account's canonical curve hash, or zero when no curve exists.
    function curveHashOf(
        address account
    ) external view returns (bytes32 curveHash);

    /// @notice Returns aggregate counters, safety budgets, version, cap, and the global base coefficient.
    function bookState() external view returns (BookState memory state);

    /// @notice Returns one packed sparse-radix prefix aggregate for diagnostics and differential tests.
    /// @param level Prefix length in nibbles, from one through eight.
    /// @param prefix High-order `level` nibbles of a uint32 breakpoint key, right-aligned.
    function radixNode(
        uint8 level,
        uint32 prefix
    ) external view returns (Coeff memory coefficient);

}
