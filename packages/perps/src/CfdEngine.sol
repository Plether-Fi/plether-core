// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanningReader} from "@plether/perps/CfdEnginePlanningReader.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTreasury} from "@plether/perps/CfdTreasury.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {CfdEngineSettlementTypes} from "@plether/perps/interfaces/CfdEngineSettlementTypes.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import {IWithdrawGuard} from "@plether/perps/interfaces/IWithdrawGuard.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

interface ICfdEngineClearinghouseBinding {

    function settlementAsset() external view returns (address);

}

interface ICfdEnginePoolBinding {

    function settlementToken() external view returns (address);
    function ENGINE() external view returns (address);

}

/// @title CfdEngine
/// @notice Canonical position ledger and execution coordinator for Plether's capped-price CFDs.
/// @dev Orders and liquidations enter through the authorized router. Economic deltas are computed by the planner,
///      then applied through the settlement sidecar while the engine remains the canonical position-state owner.
///      The clearinghouse custodies trader settlement balances and margin; the HousePool supplies counterparty cash.
///      Unless stated otherwise, prices use 8 decimals, position sizes use 18 decimals, settlement amounts use 6
///      decimals, basis-point values use a 10,000 denominator, and timestamps are Unix seconds. Legacy `settlementToken` and
///      `Assets` identifiers denote the configured settlement token, including MockUSDG on the new testnet stack.
/// @custom:security-contact contact@plether.com
contract CfdEngine is ICfdEngineTypes, IWithdrawGuard, ICfdEngineAdminHost, CfdTreasury, ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    /// @notice Fixed read-only adapter that plans from the settlement sidecar's canonical snapshots.
    CfdEnginePlanningReader public immutable planningReader;

    /// @notice Engine-owned fields for an open position.
    /// @dev Active margin is deliberately excluded: the clearinghouse position-margin bucket is its source of truth.
    struct StoredPosition {
        /// @notice Position size in canonical 100-token lots.
        uint112 lots;
        /// @notice Exact remaining entry basis, in 6-decimal settlement token atoms; closes remove their allocated basis.
        uint144 entryCostAssetAtoms;
        /// @notice Capped maximum profit envelope, in 6-decimal settlement token units.
        uint256 maxProfitAssets;
        /// @notice Direction of the position.
        CfdTypes.Side side;
        /// @notice Unix timestamp of the last position mutation.
        uint64 lastUpdateTime;
        /// @notice Unix timestamp of the last position carry checkpoint.
        uint64 lastCarryTimestamp;
        /// @notice Carry basis `max(maxProfitAssets - activeMarginAssets, 0)`, in 6-decimal settlement token units.
        uint256 borrowBaseAssets;
        /// @notice Side carry index stored at the last position carry checkpoint, scaled by 1e18.
        uint256 lastCarryIndex;
        /// @notice Lifetime signed VPI balance in 6-decimal settlement token units; positive is a charge and negative is a rebate.
        int256 vpiAccrued;
    }

    /// @notice Maximum supported oracle price, with 8 decimals; execution and mark-refresh inputs are capped here.
    uint256 public immutable CAP_PRICE;

    /// @notice Settlement token used for margin, fees, carry, recapitalization, and payouts.
    /// @dev Token identity comes from the configured collateral address.
    IERC20 public immutable settlementToken;
    /// @notice Clearinghouse that custodies trader settlement balances and typed margin buckets.
    IMarginClearinghouse public immutable clearinghouse;
    /// @notice One-time-configured HousePool that supplies LP counterparty liquidity.
    IHousePool public pool;
    /// @notice One-time-configured planner used to compute open, close, and liquidation deltas.
    ICfdEnginePlanner public planner;
    /// @notice One-time-configured sidecar authorized to apply planned settlement mutations.
    ICfdEngineSettlementSidecar public settlementSidecar;
    /// @notice One-time-configured admin contract authorized to apply finalized engine configuration.
    address public admin;
    /// @notice Exact account-local price-PnL accumulator used by the canonical LP NAV snapshot.
    ITerminalNavBookV2 public terminalNavBook;
    /// @dev Per-account nesting keeps inner carry collection inside the outer authenticated curve mutation.
    mapping(address => uint256) private _terminalCurveMutationDepth;
    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    /// @notice Aggregate position accounting by `CfdTypes.Side` index: `0` is LONG and `1` is SHORT.
    /// @dev Each entry contains the sum of maximum-profit envelopes, synthetic open interest, raw entry notional, and
    ///      active position margin for that side. Maximum profit and margin use 6-decimal settlement token, open interest uses
    ///      18 decimals, and exact entry cost scaled by `1e20` uses 26 decimals; the display average omits basis dust.
    // Zero is the initial aggregate; _sideState returns a storage alias written by the authenticated sidecar.
    // slither-disable-next-line uninitialized-state
    SideState[2] public sides;
    /// @notice Most recently accepted cached mark price, with 8 decimals and bounded by `CAP_PRICE` on router paths.
    uint256 public lastMarkPrice;
    /// @notice Oracle publish timestamp associated with `lastMarkPrice`, in Unix seconds.
    uint64 public lastMarkTime;
    /// @notice Aggregate carry borrow base by side index (`0` LONG; `1` SHORT), in 6-decimal settlement token units.
    uint256[2] public sideBorrowBaseAssets;
    /// @notice Cumulative utilization-adjusted carry multiplier by side index (`0` LONG; `1` SHORT), scaled by 1e18.
    uint256[2] public sideCarryIndex;
    /// @notice Wall-clock Unix timestamp through which each side carry index (`0` LONG; `1` SHORT) has been advanced.
    uint64[2] public sideCarryTimestamp;

    /// @notice Account carry checkpointed but not yet physically collected, in 6-decimal settlement token units.
    mapping(address => uint256) public unsettledCarryAssets;
    /// @notice Whether terminal settlement detected insolvency and latched risk-increasing operations off.
    bool public degradedMode;

    /// @notice Current VPI, skew, margin, carry, and liquidation-charge parameters.
    /// @dev VPI factor and maximum skew ratio use 1e18 scaling; margin, carry, liquidation-charge, keeper-share, and
    ///      protocol-share rates use basis points; `minBountyAssets` uses 6-decimal settlement token units.
    CfdTypes.RiskParams internal _activeRiskParams;
    mapping(address => StoredPosition) internal _positions;
    /// @notice Senior pool payout liability owed to each account, in 6-decimal settlement token units.
    mapping(address => uint256) public traderClaimBalanceAssets;
    mapping(address => uint64) public positionEpoch;
    /// @notice Aggregate outstanding trader-claim liability, in 6-decimal settlement token units.
    uint256 public totalTraderClaimBalanceAssets;
    /// @notice One-time-configured router authorized to reserve bounties and execute orders and liquidations.
    address public orderRouter;

    /// @notice Whether a Unix day number is configured as an all-day FAD and oracle-frozen override.
    mapping(uint256 => bool) public fadDayOverrides;
    uint256[] private _fadOverrideDays;
    /// @notice Maximum accepted mark age during an oracle-frozen window, in seconds.
    uint256 public fadMaxStaleness = 3 days;
    /// @notice Look-ahead interval before an override day during which FAD restrictions begin, in seconds.
    uint256 public fadRunwaySeconds = 1 hours;
    /// @notice Engine component of the live cached-mark age limit, in seconds.
    /// @dev Live checks use this value when the HousePool bound is zero, otherwise the smaller of the two bounds.
    uint256 public engineMarkStalenessLimit = 60;
    /// @notice Protocol fee charged on executed trade notional, in basis points.
    uint256 public executionFeeBps = 4;
    uint256 internal constant MAX_FROZEN_CLOSE_SPREAD_BPS = 1000;
    /// @notice Fixed LP-owned spread charged on voluntary oracle-frozen close/reduce notional, in basis points.
    uint256 public frozenCloseSpreadBps;
    /// @notice Protected headroom required per unit of maximum directional liability, in basis points.
    /// @dev This affects open/increase admission and LP withdrawals, but not raw insolvency or terminal NAV.
    uint256 public settlementBufferBps = 25;

    function _sideIndex(
        CfdTypes.Side side
    ) internal pure returns (uint256) {
        return uint256(side);
    }

    function _sideState(
        CfdTypes.Side side
    ) internal view returns (SideState storage state) {
        return sides[_sideIndex(side)];
    }

    function _longAndShortStates() internal view returns (SideState storage longState, SideState storage shortState) {
        longState = _sideState(CfdTypes.Side.LONG);
        shortState = _sideState(CfdTypes.Side.SHORT);
    }

    function _requireTerminalNavBook() internal view returns (ITerminalNavBookV2 book) {
        book = terminalNavBook;
        if (address(book) == address(0)) {
            revert CfdEngine__TerminalNavBookNotSet();
        }
    }

    /// @notice Authenticates stable Engine state against the account commitment stored in the terminal NAV book.
    /// @dev This explicitly checks zero-position accounts too, so an unexpected orphan curve cannot be silently kept.
    function _beginTerminalCurveMutation(
        address account
    ) internal returns (bytes32 expectedHash) {
        // Only paired internal calls change depth; transaction gas bounds nesting far below uint256 capacity.
        unchecked {
            if (_terminalCurveMutationDepth[account]++ == 0) {
                expectedHash = _requireTerminalNavBook().authenticateEngineState(account);
            }
        }
    }

    function _endTerminalCurveMutation(
        address account,
        bytes32 expectedOldHash
    ) internal {
        unchecked {
            if (--_terminalCurveMutationDepth[account] == 0) {
                _requireTerminalNavBook().syncFromEngine(account, expectedOldHash);
            }
        }
    }

    function _checkpointBountyRecipient(
        address account,
        uint256 price,
        uint64 publishTime
    ) internal {
        uint256 clampedPrice = price > CAP_PRICE ? CAP_PRICE : price;
        if (publishTime > lastMarkTime) {
            _applyCarryAndMark(clampedPrice, publishTime);
        }

        StoredPosition storage pos = _positions[account];
        if (pos.lots > 0) {
            _realizeCarryFromSettlement(account, pos);
        }
    }

    function _settleTraderClaimBalance(
        uint256 amount,
        address account,
        bool positionRemainsOpen
    ) internal returns (uint256 claimAmountAssets) {
        if (amount == 0 || pool.totalAssets() < totalTraderClaimBalanceAssets) {
            revert CfdEngine__InsufficientPoolLiquidity();
        }

        claimAmountAssets = amount;
        _payTraderClaim(account, claimAmountAssets, positionRemainsOpen);
    }

    /// @dev Caller validates liquidity before this common pool payout and corresponding custody credit.
    function _payTraderClaim(
        address account,
        uint256 amountAssets,
        bool positionRemainsOpen
    ) private {
        pool.payOut(address(clearinghouse), amountAssets);
        if (positionRemainsOpen) {
            clearinghouse.creditPnlPledge(account, amountAssets);
        } else {
            clearinghouse.settleAssets(account, int256(amountAssets));
        }
    }

    modifier onlyRouter() {
        _onlyRouter();
        _;
    }

    modifier onlySettlementSidecar() {
        _onlySettlementSidecar();
        _;
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyRouter() internal view {
        if (msg.sender != orderRouter) {
            revert CfdEngine__Unauthorized();
        }
    }

    function _onlySettlementSidecar() internal view {
        if (msg.sender != address(settlementSidecar)) {
            revert CfdEngine__Unauthorized();
        }
    }

    function _onlyAdmin() internal view {
        if (msg.sender != admin) {
            revert CfdEngine__Unauthorized();
        }
    }

    /// @notice Initializes the immutable settlement dependencies, price cap, and initial risk configuration.
    /// @dev The clearinghouse must use the same settlement token. The deployer becomes the two-step owner and initial
    ///      protocol treasury account. The HousePool, router, planner, sidecar, and admin use one-time setters.
    /// @param _settlementToken Settlement token treated by the protocol as settlement token with 6 decimals.
    /// @param _clearinghouse Margin clearinghouse that custodies trader balances and margin buckets.
    /// @param _capPrice Nonzero maximum supported oracle price, with 8 decimals and no greater than `type(uint32).max`.
    /// @param _riskParams Initial risk parameters: VPI/skew fields use 1e18 scaling, rates use basis points, and the
    ///                    minimum bounty uses 6-decimal settlement token units.
    /// @param _frozenCloseSpreadBps Initial nonzero LP-owned frozen-close spread, in basis points and at most 1,000.
    constructor(
        address _settlementToken,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams,
        uint256 _frozenCloseSpreadBps
    ) CfdTreasury() {
        if (_settlementToken == address(0) || _clearinghouse == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (
            _clearinghouse.code.length == 0
                || ICfdEngineClearinghouseBinding(_clearinghouse).settlementAsset() != _settlementToken
        ) {
            revert CfdEngine__InvalidSettlementAsset();
        }
        if (_capPrice == 0 || _capPrice > type(uint32).max) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.maintMarginBps == 0 || _riskParams.initMarginBps < _riskParams.maintMarginBps) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.fadMarginBps < _riskParams.maintMarginBps) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.initMarginBps > 10_000 || _riskParams.fadMarginBps > 10_000) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.baseCarryBps > 100_000) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.minBountyAssets == 0 || _riskParams.bountyBps == 0) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.keeperShareBps > 10_000 || _riskParams.protocolShareBps > 10_000 - _riskParams.keeperShareBps) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.maxSkewRatio > CfdMath.WAD) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_frozenCloseSpreadBps == 0 || _frozenCloseSpreadBps > MAX_FROZEN_CLOSE_SPREAD_BPS) {
            revert CfdEngine__InvalidRiskParams();
        }
        settlementToken = IERC20(_settlementToken);
        clearinghouse = IMarginClearinghouse(_clearinghouse);
        CAP_PRICE = _capPrice;
        _activeRiskParams = _riskParams;
        frozenCloseSpreadBps = _frozenCloseSpreadBps;
        planningReader = new CfdEnginePlanningReader();
    }

    /// @notice Atomically configures the planner, settlement sidecar, and engine admin exactly once.
    /// @dev Callable only by the owner. The sidecar must be contract code whose `ENGINE()` is this engine, and the
    ///      admin must report this engine from `engine()`. The planner address is stored without an interface probe.
    /// @param planner_ Planner that computes open, close, and liquidation deltas.
    /// @param settlementSidecar_ Settlement sidecar bound to this engine.
    /// @param admin_ Admin authorized to apply finalized configuration and expected to enforce the timelock.
    function setDependencies(
        address planner_,
        address settlementSidecar_,
        address admin_
    ) external onlyOwner {
        if (planner_ == address(0) || settlementSidecar_ == address(0) || admin_ == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (address(planner) != address(0) || address(settlementSidecar) != address(0) || admin != address(0)) {
            revert CfdEngine__DependenciesAlreadySet();
        }
        if (settlementSidecar_.code.length == 0) {
            revert CfdEngine__InvalidSettlementSidecar();
        }
        try ICfdEngineSettlementSidecar(settlementSidecar_).ENGINE() returns (address settlementEngine) {
            if (settlementEngine != address(this)) {
                revert CfdEngine__InvalidSettlementSidecar();
            }
        } catch {
            revert CfdEngine__InvalidSettlementSidecar();
        }
        bool adminBound;
        // Compact staticcall keeps the engine deployable while validating the admin's `engine()` binding.
        assembly ("memory-safe") {
            mstore(0, shl(224, 0xc9d4623f))
            let success := staticcall(gas(), admin_, 0, 4, 0, 32)
            adminBound := and(and(success, eq(returndatasize(), 32)), eq(mload(0), address()))
        }
        if (!adminBound) {
            revert CfdEngine__InvalidAdmin();
        }
        planner = ICfdEnginePlanner(planner_);
        settlementSidecar = ICfdEngineSettlementSidecar(settlementSidecar_);
        admin = admin_;
    }

    /// @notice Configures the HousePool backing all positions exactly once.
    /// @dev Callable only by the owner; the pool must use this engine and its settlement token.
    /// @param _pool HousePool address that provides counterparty liquidity.
    function setPool(
        address _pool
    ) external onlyOwner {
        if (_pool == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (address(pool) != address(0)) {
            revert CfdEngine__PoolAlreadySet();
        }
        if (
            _pool.code.length == 0 || ICfdEnginePoolBinding(_pool).settlementToken() != address(settlementToken)
                || ICfdEnginePoolBinding(_pool).ENGINE() != address(this)
        ) {
            revert CfdEngine__InvalidPool();
        }
        pool = IHousePool(_pool);
    }

    /// @notice Configures the empty exact terminal NAV book exactly once.
    /// @dev The book must be contract code immutably bound to this Engine, the same uint32 price cap, and the canonical
    ///      100-token size quantum. Wiring is rejected after any position exposure exists.
    function setTerminalNavBook(
        address terminalNavBook_
    ) external onlyOwner {
        if (address(terminalNavBook) != address(0)) {
            revert CfdEngine__TerminalNavBookAlreadySet();
        }
        if (terminalNavBook_ == address(0) || terminalNavBook_.code.length == 0) {
            revert CfdEngine__InvalidTerminalNavBook();
        }
        ITerminalNavBookV2 candidate = ITerminalNavBookV2(terminalNavBook_);
        try candidate.validateEngineBinding() returns (bool valid) {
            if (!valid) {
                revert CfdEngine__InvalidTerminalNavBook();
            }
        } catch {
            revert CfdEngine__InvalidTerminalNavBook();
        }

        terminalNavBook = candidate;
        emit TerminalNavBookSet(terminalNavBook_);
    }

    /// @notice Configures the authorized OrderRouter exactly once.
    /// @dev Callable only by the owner; this setter does not probe the supplied address for an interface binding.
    /// @param _router Nonzero router allowed to reserve bounties and process orders and liquidations.
    function setOrderRouter(
        address _router
    ) external onlyOwner {
        if (_router == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (orderRouter != address(0)) {
            revert CfdEngine__RouterAlreadySet();
        }
        orderRouter = _router;
    }

    /// @notice Transfers a forfeited reserved execution bounty into the protocol treasury clearinghouse account.
    /// @dev Callable only by the router. This reclassifies clearinghouse balances without transferring ERC20 tokens;
    ///      a zero amount is a no-op. Emits `BountyCredited` for a nonzero transfer.
    /// @param sourceAccount Account whose reserved settlement bounty is forfeited.
    /// @param amountAssets Reserved amount to transfer, in 6-decimal settlement token units.
    function absorbReservedExecutionBounty(
        address sourceAccount,
        uint256 amountAssets
    ) external onlyRouter {
        if (amountAssets == 0) {
            return;
        }

        address treasury = protocolTreasury();
        clearinghouse.transferReservedSettlement(sourceAccount, treasury, amountAssets);
        emit BountyCredited(sourceAccount, treasury, amountAssets);
    }

    /// @notice Transfers reserved bounty value from a source account into a beneficiary clearinghouse account.
    /// @dev Callable only by the router. For a beneficiary with an open position, carry is checkpointed before the
    ///      settlement credit changes reachable collateral. Available margin and free settlement pay carry, and the
    ///      unpaid remainder stays in `unsettledCarryAssets`. The incoming bounty is not collected in this call.
    ///      A strictly newer mark is capped at `CAP_PRICE` and cached.
    ///      The engine relies on the router to validate the supplied mark. A zero amount is a complete no-op.
    /// @param sourceAccount Account whose reserved settlement bounty funds the credit.
    /// @param beneficiary Account receiving the clearinghouse settlement credit.
    /// @param amountAssets Reserved amount to transfer, in 6-decimal settlement token units.
    /// @param price Router-validated mark price used if `publishTime` is newer, with 8 decimals.
    /// @param publishTime Oracle publish timestamp associated with `price`, in Unix seconds.
    function creditBounty(
        address sourceAccount,
        address beneficiary,
        uint256 amountAssets,
        uint256 price,
        uint64 publishTime
    ) external onlyRouter nonReentrant {
        if (amountAssets == 0) {
            return;
        }

        bytes32 expectedOldHash;
        bool syncCurve = _positions[beneficiary].lots > 0;
        if (syncCurve) {
            expectedOldHash = _beginTerminalCurveMutation(beneficiary);
        }
        _checkpointBountyRecipient(beneficiary, price, publishTime);
        clearinghouse.transferReservedSettlement(sourceAccount, beneficiary, amountAssets);
        if (syncCurve) {
            _endTerminalCurveMutation(beneficiary, expectedOldHash);
        }
        emit BountyCredited(sourceAccount, beneficiary, amountAssets);
    }

    /// @notice Adds isolated margin to an existing open position without changing size.
    /// @dev The caller must equal `account`. Collectible accrued carry is realized first and any uncovered amount
    ///      remains unsettled; then clearinghouse free settlement is locked as active position margin and aggregate
    ///      side margin and borrow-base accounting are refreshed. A zero amount reverts with `CfdEngine__ZeroAmount`.
    /// @param account Position owner and required caller.
    /// @param amount Nonzero amount to move from free settlement into position margin, in 6-decimal settlement token units.
    function addMargin(
        address account,
        uint256 amount
    ) external nonReentrant {
        if (msg.sender != account) {
            revert CfdEngine__NotAccountOwner();
        }
        if (amount == 0) {
            revert CfdEngine__ZeroAmount();
        }

        StoredPosition storage pos = _positions[account];
        if (pos.lots == 0) {
            revert CfdEngine__NoOpenPosition();
        }

        bytes32 expectedOldHash = _beginTerminalCurveMutation(account);
        _realizeCarryFromSettlement(account, pos);

        uint256 marginBefore = _positionMarginBucketAssets(account);
        clearinghouse.lockPositionMargin(account, amount);
        _sideState(pos.side).totalMargin += amount;
        _syncPositionBorrowBaseToMargin(pos, marginBefore + amount);
        pos.lastUpdateTime = uint64(block.timestamp);
        pos.lastCarryTimestamp = uint64(block.timestamp);
        _endTerminalCurveMutation(account, expectedOldHash);

        emit MarginAdded(account, amount);
    }

    /// @notice Collects available backing toward accrued carry when the clearinghouse changes an account's collateral basis.
    /// @dev Callable only by the configured clearinghouse. The clearinghouse invokes this during deposits and before
    ///      withdrawals and other basis-changing bucket operations. Accounts without an open position are no-ops.
    /// @param account Account whose open-position carry should be collected, retaining any unpaid remainder.
    function realizeCarryBeforeMarginChange(
        address account
    ) external nonReentrant {
        if (msg.sender != address(clearinghouse)) {
            revert CfdEngine__NotClearinghouse();
        }

        StoredPosition storage pos = _positions[account];
        if (pos.lots == 0) {
            return;
        }

        bytes32 expectedOldHash = _beginTerminalCurveMutation(account);
        _realizeCarryFromSettlement(account, pos);
        _endTerminalCurveMutation(account, expectedOldHash);
    }

    /// @notice Settles the caller's trader claim balance into the clearinghouse.
    /// @dev The caller must equal `account`. Settlement is all-or-nothing and is available only when HousePool cash
    ///      covers all outstanding trader claims. Side carry indexes and any open-position indexed carry are
    ///      checkpointed before the pool payout and clearinghouse credit change their respective carry bases. Available
    ///      margin and free settlement pay carry first, retaining arrears. The incoming claim payment is not collected
    ///      in this call. When it becomes PnL pledge, aggregate side margin and borrow-base accounting are refreshed.
    /// @param account Claim beneficiary and required caller.
    function settleTraderClaim(
        address account
    ) external nonReentrant {
        if (msg.sender != account) {
            revert CfdEngine__NotAccountOwner();
        }
        bytes32 expectedOldHash = _beginTerminalCurveMutation(account);
        _advanceAllCarryIndexes(block.timestamp);
        StoredPosition storage pos = _positions[account];
        if (pos.lots > 0) {
            _realizeCarryFromSettlement(account, pos);
        }

        uint256 amount = traderClaimBalanceAssets[account];
        if (amount == 0) {
            revert CfdEngine__NoTraderClaim();
        }
        uint256 marginBefore = pos.lots > 0 ? _positionMarginBucketAssets(account) : 0;
        uint256 claimAmountAssets = _settleTraderClaimBalance(amount, account, pos.lots > 0);

        if (pos.lots > 0) {
            uint256 marginAfter = _positionMarginBucketAssets(account);
            _syncTotalSideMargin(pos.side, marginBefore, marginAfter);
            _syncPositionBorrowBaseToMargin(pos, marginAfter);
        }

        traderClaimBalanceAssets[account] -= claimAmountAssets;
        totalTraderClaimBalanceAssets -= claimAmountAssets;
        _endTerminalCurveMutation(account, expectedOldHash);

        emit TraderClaimSettled(account, claimAmountAssets);
    }

    /// @notice Validates a close commitment and realizes collectible carry without reserving a bounty.
    /// @dev Callable only by the router. Close commitments reserve no execution bounty.
    ///      Carry uses position margin first, then free settlement, and any uncovered amount remains unsettled.
    ///      The zero-bounty path still validates close admission and checkpoints carry.
    /// @param account Account committing the close order.
    /// @param sizeDelta Intended close size, with 18 decimals; must be nonzero and no greater than position size.
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta
    ) external onlyRouter nonReentrant returns (CfdEnginePlanTypes.CloseCommitment memory effects) {
        bytes32 expectedOldHash = _beginTerminalCurveMutation(account);
        address target = address(settlementSidecar);
        bytes4 selector = ICfdEngineSettlementSidecar.reserveCloseOrderExecutionBounty.selector;
        bytes4 invalidResult = ICfdEngineTypes.CfdEngine__InvalidRiskParams.selector;
        // Reuse one fixed buffer for the two-word call and six-word response. Do not return from assembly:
        // borrow/terminal synchronization and the nonReentrant epilogue must still run.
        assembly ("memory-safe") {
            effects := mload(0x40)
            mstore(effects, selector)
            mstore(add(effects, 4), account)
            mstore(add(effects, 36), sizeDelta)
            if iszero(call(gas(), target, 0, effects, 68, effects, 192)) {
                returndatacopy(effects, 0, returndatasize())
                revert(effects, returndatasize())
            }
            if iszero(eq(returndatasize(), 192)) {
                mstore(effects, invalidResult)
                revert(effects, 4)
            }
            mstore(0x40, add(effects, 192))
        }
        _syncPositionBorrowBase(account, _positions[account]);
        _endTerminalCurveMutation(account, expectedOldHash);
    }

    /// @notice Funds non-dilutive claimant recapitalization from the engine owner's wallet.
    /// @dev The owner must approve this engine for settlement token. Checkpoints carry before changing pool depth and requires
    ///      exact receipt before queuing recapitalization. Allocation occurs through normal pool reconciliation;
    ///      this call mints no shares and does not clear degraded mode. Funding remains available while paused or frozen.
    /// @param amountAssets Nonzero settlement token amount to transfer directly into the configured pool (6 decimals).
    function recapitalizePool(
        uint256 amountAssets
    ) external onlyOwner nonReentrant {
        if (amountAssets == 0) {
            revert CfdEngine__ZeroAmount();
        }
        if (address(pool) == address(0)) {
            revert CfdEngine__InvalidPool();
        }
        _advanceAllCarryIndexes(block.timestamp);
        uint256 balanceBefore = settlementToken.balanceOf(address(pool));
        settlementToken.safeTransferFrom(msg.sender, address(pool), amountAssets);
        uint256 balanceAfter = settlementToken.balanceOf(address(pool));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amountAssets) {
            revert CfdEngine__UnexpectedTransferAmount(amountAssets, received);
        }
        pool.recordClaimantInflow(
            amountAssets, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        emit PoolRecapitalized(msg.sender, amountAssets);
    }

    /// @notice Clears degraded mode once adjusted solvency has recovered.
    /// @dev Callable only by the owner. Recovery requires HousePool physical assets net of senior trader claims to
    ///      cover the larger side's aggregate maximum-profit liability.
    function clearDegradedMode() external onlyOwner {
        if (!degradedMode) {
            revert CfdEngine__NotDegraded();
        }
        if (_availableCashForFreshPoolPayouts() < _maxLiability()) {
            revert CfdEngine__StillInsolvent();
        }
        degradedMode = false;
        emit DegradedModeCleared();
    }

    /// @notice Applies finalized risk parameters from the timelocked engine admin.
    /// @dev Callable only by `admin`, which is responsible for validation and timelock enforcement. Carry indexes are
    ///      advanced before the carry-rate parameter can change.
    /// @param config Validated configuration: VPI/skew fields use 1e18 scaling, the minimum bounty uses 6-decimal
    ///               settlement token units, and margin, carry, bounty, execution-fee, spread, and buffer rates use basis points.
    function applyRiskConfig(
        ICfdEngineAdminHost.EngineRiskConfig calldata config
    ) external onlyAdmin {
        // CfdEngineAdmin is the sole caller and validates the staged configuration before finalization.
        _advanceAllCarryIndexes(block.timestamp);
        _activeRiskParams = config.riskParams;
        executionFeeBps = config.executionFeeBps;
        frozenCloseSpreadBps = config.frozenCloseSpreadBps;
        settlementBufferBps = config.settlementBufferBps;
    }

    /// @notice Applies finalized FAD calendar overrides from the timelocked engine admin.
    /// @dev Callable only by `admin`. Replaces the complete existing override set, normalizes each timestamp to its
    ///      Unix day number, and ignores duplicate days. The admin is responsible for validation and timelock policy.
    /// @param config Complete FAD day timestamp set and runway duration in seconds.
    function applyCalendarConfig(
        ICfdEngineAdminHost.EngineCalendarConfig calldata config
    ) external onlyAdmin {
        uint256 oldLength = _fadOverrideDays.length;
        for (uint256 i; i < oldLength; i++) {
            uint256 day = _fadOverrideDays[i];
            delete fadDayOverrides[day];
        }
        delete _fadOverrideDays;
        for (uint256 i; i < config.fadDayTimestamps.length; i++) {
            uint256 day = config.fadDayTimestamps[i] / 86_400;
            if (!fadDayOverrides[day]) {
                fadDayOverrides[day] = true;
                _fadOverrideDays.push(day);
            }
        }
        fadRunwaySeconds = config.fadRunwaySeconds;
    }

    /// @notice Applies finalized mark freshness limits from the timelocked engine admin.
    /// @dev Callable only by `admin`, which is responsible for validation and timelock enforcement.
    /// @param config Oracle-frozen and live cached-mark staleness limits, both in seconds.
    function applyFreshnessConfig(
        ICfdEngineAdminHost.EngineFreshnessConfig calldata config
    ) external onlyAdmin {
        fadMaxStaleness = config.fadMaxStaleness;
        engineMarkStalenessLimit = config.engineMarkStalenessLimit;
    }

    // ==========================================
    // WITHDRAW GUARD (IWithdrawGuard)
    // ==========================================

    /// @notice Validates that a clearinghouse withdrawal leaves an open position sufficiently collateralized.
    /// @dev Callable only by the clearinghouse after its provisional balance debit. Flat accounts retain any pending
    ///      open's funded settlement minimum.
    ///      Open positions require non-degraded mode and a fresh cached mark. Collectible carry is then realized, any
    ///      uncovered remainder blocks withdrawal. Negative lifetime VPI must remain fully reserve-backed, and price
    ///      equity must exceed the stricter of initial margin and the active maintenance/FAD requirement. Every
    ///      mutation rolls back if the enclosing withdrawal fails.
    /// @param account Clearinghouse account whose post-withdrawal state is checked.
    function checkWithdraw(
        address account
    ) external override nonReentrant {
        if (msg.sender != address(clearinghouse)) {
            revert CfdEngine__NotClearinghouse();
        }

        bool syncCurve = _positions[account].lots > 0;
        bytes32 expectedOldHash;
        if (syncCurve) {
            expectedOldHash = _beginTerminalCurveMutation(account);
        } else if (orderRouter == address(0)) {
            return;
        }
        settlementSidecar.validateWithdraw(account);
        if (syncCurve) {
            _endTerminalCurveMutation(account, expectedOldHash);
        }
    }

    // ==========================================
    // 1. ORDER PROCESSING & NETTING
    // ==========================================

    /// @notice Router-facing order execution entrypoint with typed business-rule failures.
    /// @dev Callable only by the router. Delegates validation and delta construction to `planner`, then delegates
    ///      clearinghouse, pool, aggregate-side, and position mutations to the settlement sidecar. Expected business
    ///      invalidations are returned to the router as `CfdEngine__TypedOrderFailure`.
    /// @param order Queued open/increase or close/reduce order being executed.
    /// @param currentOraclePrice Execution oracle price, with 8 decimals; planning caps it at `CAP_PRICE`.
    /// @param poolDepthAssets Router-supplied HousePool depth used for planning, in 6-decimal settlement token units.
    /// @param publishTime Oracle publish timestamp for the execution mark, in Unix seconds.
    function processOrderTyped(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 poolDepthAssets,
        uint64 publishTime
    ) external onlyRouter nonReentrant {
        _processOrder(order, currentOraclePrice, poolDepthAssets, publishTime);
    }

    function _processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 poolDepthAssets,
        uint64 publishTime
    ) internal {
        if (order.isClose) {
            CfdEnginePlanTypes.CloseDelta memory delta =
                planningReader.planClose(order, currentOraclePrice, poolDepthAssets);
            _revertIfCloseInvalidTyped(delta.revertCode);
            _applyClose(delta, publishTime);
        } else {
            CfdEnginePlanTypes.OpenDelta memory delta =
                planningReader.planOpen(order, currentOraclePrice, poolDepthAssets);
            _revertIfOpenInvalidTyped(delta.revertCode);
            _applyOpen(delta, publishTime);
        }
    }

    // ==========================================
    // 3. INTERNAL LEDGER UPDATES
    // ==========================================

    function _syncTotalSideMargin(
        CfdTypes.Side side,
        uint256 marginBefore,
        uint256 marginAfter
    ) internal {
        SideState storage selected = _sideState(side);
        selected.totalMargin = selected.totalMargin - marginBefore + marginAfter;
    }

    function _positionBorrowBase(
        uint256 maxProfitAssets,
        uint256 marginAssets
    ) internal pure returns (uint256 borrowBaseAssets) {
        assembly ("memory-safe") {
            if gt(maxProfitAssets, marginAssets) { borrowBaseAssets := sub(maxProfitAssets, marginAssets) }
        }
    }

    function _applySideBorrowBaseDelta(
        CfdTypes.Side side,
        uint256 oldBorrowBaseAssets,
        uint256 newBorrowBaseAssets
    ) internal {
        uint256 index = _sideIndex(side);
        sideBorrowBaseAssets[index] = sideBorrowBaseAssets[index] - oldBorrowBaseAssets + newBorrowBaseAssets;
    }

    function _syncPositionBorrowBase(
        address account,
        StoredPosition storage pos
    ) internal {
        _syncPositionBorrowBaseToMargin(pos, _positionMarginBucketAssets(account));
    }

    function _syncPositionBorrowBaseToMargin(
        StoredPosition storage pos,
        uint256 marginAssets
    ) internal {
        if (pos.lots == 0) {
            return;
        }
        uint256 newBorrowBaseAssets = _positionBorrowBase(pos.maxProfitAssets, marginAssets);
        _applySideBorrowBaseDelta(pos.side, pos.borrowBaseAssets, newBorrowBaseAssets);
        pos.borrowBaseAssets = newBorrowBaseAssets;
    }

    function _payOrRecordTraderClaim(
        address account,
        uint256 amountAssets,
        bool positionRemainsOpen
    ) internal {
        if (amountAssets == 0) {
            return;
        }

        if (_canPayFreshPoolPayout(amountAssets)) {
            _payTraderClaim(account, amountAssets, positionRemainsOpen);
        } else {
            _advanceAllCarryIndexes(block.timestamp);
            traderClaimBalanceAssets[account] += amountAssets;
            totalTraderClaimBalanceAssets += amountAssets;
            emit TraderClaimRecorded(account, amountAssets);
        }
    }

    function _canPayFreshPoolPayout(
        uint256 amountAssets
    ) internal view returns (bool) {
        return amountAssets <= _availableCashForFreshPoolPayouts();
    }

    function _availableCashForFreshPoolPayouts() internal view returns (uint256 availableCashAssets) {
        uint256 physicalAssets = pool.totalAssets();
        uint256 claimsAssets = totalTraderClaimBalanceAssets;
        assembly ("memory-safe") {
            if gt(physicalAssets, claimsAssets) { availableCashAssets := sub(physicalAssets, claimsAssets) }
        }
    }

    // ==========================================
    // LIQUIDATIONS & FAD
    // ==========================================

    /// @notice Reports whether Friday Afternoon Deleverage restrictions are currently active.
    /// @dev The recurring window starts 30 minutes before Friday's 17:00 New York FX close and ends 15 minutes after
    ///      Sunday's 17:00 New York FX open. FAD is also active throughout an admin-configured override day and during
    ///      `fadRunwaySeconds` immediately before an override day.
    /// @return True when the recurring window, an override day, or its configured runway is active.
    function isFadWindow() public view returns (bool) {
        (bool fadWindow,) = _marketStatus();
        return fadWindow;
    }

    /// @notice Reports whether the engine is in the oracle-frozen regime where freshness policy can be relaxed.
    /// @dev The recurring window is Friday 17:00 New York time through Sunday 16:59:59 New York time, following the
    ///      US daylight-saving transition. An admin-configured override freezes its entire UTC day. Unlike FAD, the
    ///      frozen regime does not include the pre-override runway.
    /// @return True during the recurring oracle closure or an override day.
    function isOracleFrozen() public view returns (bool) {
        (, bool oracleFrozen) = _marketStatus();
        return oracleFrozen;
    }

    function _marketStatus() internal view returns (bool fadWindow, bool oracleFrozen) {
        if (address(planner) == address(0)) {
            return (false, false);
        }
        uint256 timestamp = block.timestamp;
        uint256 today = timestamp / 86_400;
        return
            planner.marketCalendarStatus(
                timestamp, fadDayOverrides[today], fadDayOverrides[today + 1], fadRunwaySeconds
            );
    }

    /// @notice Returns the canonical current position tuple for an account.
    /// @dev Margin is read from the clearinghouse position-margin bucket. Entry price is derived from engine-owned
    ///      exact basis and lots; it is a display average, not the basis used for settlement.
    /// @param account Account to inspect.
    /// @return size Synthetic position size, with 18 decimals.
    /// @return margin Current active position margin, in 6-decimal settlement token units.
    /// @return entryPrice Exact remaining entry cost divided by lots, rounded down to an 8-decimal display price.
    /// @return maxProfitAssets Capped maximum profit envelope, in 6-decimal settlement token units.
    /// @return side Position direction; the default enum value is returned when no position exists.
    /// @return lastUpdateTime Unix timestamp of the last position mutation.
    /// @return vpiAccrued Lifetime signed VPI balance in 6-decimal settlement token units; positive is a charge.
    function positions(
        address account
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitAssets,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        )
    {
        CfdTypes.Position memory pos = _loadPosition(account);
        return (pos.size, pos.margin, pos.entryPrice, pos.maxProfitAssets, pos.side, pos.lastUpdateTime, pos.vpiAccrued);
    }

    /// @notice Returns the exact canonical entry cost for an account's live position.
    /// @dev Unlike the display-only average entry price returned by `positions`, this value preserves all basis dust.
    function positionEntryCostAssetAtoms(
        address account
    ) external view returns (uint256) {
        return _positions[account].entryCostAssetAtoms;
    }

    /// @notice Returns one current, authenticated terminal price-PnL snapshot for LP accounting.
    /// @dev The signed delta is read from the Engine-bound book at the cached Engine mark. The call fails closed while
    ///      any multi-contract account mutation is transient or when a required mark/book is unavailable. Mark-age
    ///      freshness is enforced by consuming pool paths, not by this snapshot getter.
    function terminalNavSnapshot() external view returns (TerminalNavSnapshot memory snapshot) {
        if (_reentrancyGuardEntered()) {
            revert CfdEngine__AccountingMutationInProgress();
        }
        return _requireTerminalNavBook().terminalNavSnapshot();
    }

    /// @notice Returns the carry-index basis stored for an account's current position.
    /// @param account Account to inspect.
    /// @return borrowBaseAssets Position borrow base used for carry utilization, in 6-decimal settlement token units.
    /// @return lastCarryIndex Side carry index stored at the position's last checkpoint, scaled by 1e18.
    /// @return lastCarryTimestamp Unix timestamp of the position's last carry checkpoint.
    function positionCarryState(
        address account
    ) external view returns (uint256 borrowBaseAssets, uint256 lastCarryIndex, uint64 lastCarryTimestamp) {
        StoredPosition storage pos = _positions[account];
        return (pos.borrowBaseAssets, pos.lastCarryIndex, pos.lastCarryTimestamp);
    }

    /// @notice Returns the engine's active position-risk, VPI, carry, and liquidation-charge parameters.
    function riskParams()
        external
        view
        returns (
            uint256 vpiFactor,
            uint256 maxSkewRatio,
            uint256 maintMarginBps,
            uint256 initMarginBps,
            uint256 fadMarginBps,
            uint256 baseCarryBps,
            uint256 minBountyAssets,
            uint256 bountyBps,
            uint256 keeperShareBps,
            uint256 protocolShareBps
        )
    {
        // The public struct getter otherwise emits ten separately unrolled loads. Keeping its exact ABI while
        // iterating over the struct's contiguous full-slot fields materially reduces engine runtime bytecode.
        assembly ("memory-safe") {
            let result := mload(0x40)
            let riskParamsSlot := _activeRiskParams.slot
            for { let offset := 0 } lt(offset, 0x140) { offset := add(offset, 0x20) } {
                mstore(add(result, offset), sload(add(riskParamsSlot, shr(5, offset))))
            }
            return(result, 0x140)
        }
    }

    /// @notice Plans and settles liquidation of an undercollateralized position.
    /// @dev Callable only by the router. The planner accounts for pending carry, typed reachable collateral, the keeper
    ///      bounty, any trader residual payout or claim, and diagnostic price-loss write-off. Settlement removes the
    ///      position and its side aggregates and may latch degraded mode if effective pool assets no longer cover
    ///      maximum liability; no write-off is accumulated as protocol debt.
    /// @param account Clearinghouse account that owns the position.
    /// @param currentOraclePrice Liquidation oracle price, with 8 decimals; planning caps it at `CAP_PRICE`.
    /// @param poolDepthAssets Router-supplied HousePool depth used for planning, in 6-decimal settlement token units.
    /// @param publishTime Oracle publish timestamp for the liquidation mark, in Unix seconds.
    /// @param keeper Clearinghouse account credited with any liquidation bounty.
    /// @return keeperBountyAssets Bounty credited to the keeper, in 6-decimal settlement token units.
    function liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 poolDepthAssets,
        uint64 publishTime,
        address keeper
    ) external onlyRouter nonReentrant returns (uint256 keeperBountyAssets) {
        return _liquidatePosition(account, currentOraclePrice, poolDepthAssets, publishTime, keeper);
    }

    function _liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 poolDepthAssets,
        uint64 publishTime,
        address keeper
    ) internal returns (uint256 keeperBountyAssets) {
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }
        if (_positions[account].lots == 0) {
            revert CfdEngine__NoPositionToLiquidate();
        }

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            planningReader.planLiquidation(account, currentOraclePrice, poolDepthAssets);

        if (!delta.liquidatable) {
            revert CfdEngine__PositionIsSolvent();
        }

        return _applyLiquidation(delta, publishTime, keeper);
    }

    function _maxLiability() internal view returns (uint256) {
        (SideState storage longState, SideState storage shortState) = _longAndShortStates();
        return
            longState.maxProfitAssets > shortState.maxProfitAssets
                ? longState.maxProfitAssets
                : shortState.maxProfitAssets;
    }

    // ==========================================
    // PLAN-APPLY: REVERT DISPATCH + APPLY
    // ==========================================

    function _revertIfOpenInvalidTyped(
        CfdEnginePlanTypes.OpenRevertCode code
    ) internal view {
        if (code == CfdEnginePlanTypes.OpenRevertCode.OK) {
            return;
        }

        revert ICfdEngineTypes.CfdEngine__TypedOrderFailure(
            CfdEnginePlanLib.getExecutionFailurePolicyCategory(code), uint8(code), false
        );
    }

    function _revertIfCloseInvalidTyped(
        CfdEnginePlanTypes.CloseRevertCode code
    ) internal view {
        if (code == CfdEnginePlanTypes.CloseRevertCode.OK) {
            return;
        }

        revert ICfdEngineTypes.CfdEngine__TypedOrderFailure(
            CfdEnginePlanLib.getExecutionFailurePolicyCategory(code), uint8(code), true
        );
    }

    function _applyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) internal {
        _advanceAllCarryIndexes(block.timestamp);
        if (newMarkTime < lastMarkTime) {
            return;
        }
        if (newMarkTime == lastMarkTime && newMarkPrice != lastMarkPrice) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }
        lastMarkPrice = newMarkPrice;
        lastMarkTime = newMarkTime;
    }

    /// @notice Permissionlessly advances both side carry indexes to the current wall-clock timestamp.
    /// @dev Accrual uses each side's current borrow base, current HousePool effective assets
    ///      (`min(raw balance, accountedAssets)`) net of outstanding trader claims, and `baseCarryBps`.
    ///      This does not checkpoint a position, collect carry from an account, or update the oracle mark.
    function checkpointCarryIndexes() external {
        _advanceAllCarryIndexes(block.timestamp);
    }

    function _advanceAllCarryIndexes(
        uint256 timestampNow
    ) internal {
        if (timestampNow <= sideCarryTimestamp[0] && timestampNow <= sideCarryTimestamp[1]) {
            return;
        }
        // Neither side update moves pool cash; both indexes must use the same pool observation.
        uint256 poolAssets = _poolAssetsForCarry();
        for (uint256 index; index < 2; ++index) {
            if (timestampNow > sideCarryTimestamp[index]) {
                sideCarryIndex[index] = _currentSideCarryIndex(CfdTypes.Side(index), timestampNow, poolAssets);
                sideCarryTimestamp[index] = uint64(timestampNow);
            }
        }
    }

    function _currentSideCarryIndex(
        CfdTypes.Side side,
        uint256 timestampNow,
        uint256 poolAssets
    ) internal view returns (uint256 index) {
        uint256 sideIndex = _sideIndex(side);
        index = PositionRiskAccountingLib.computeCurrentCarryIndex(
            sideCarryIndex[sideIndex],
            sideCarryTimestamp[sideIndex],
            timestampNow,
            sideBorrowBaseAssets[sideIndex],
            poolAssets,
            _activeRiskParams.baseCarryBps
        );
    }

    function _poolAssetsForCarry() internal view returns (uint256) {
        return address(pool) == address(0)
            ? 0
            : PositionRiskAccountingLib.computeNetPoolDepthAssets(pool.totalAssets(), totalTraderClaimBalanceAssets);
    }

    /// @notice Advances side carry indexes and caches a strictly newer planned mark from the settlement sidecar.
    /// @dev Callable only by the configured settlement sidecar. A mark whose publish time is not strictly newer is a
    ///      no-op. The sidecar is trusted to supply a planner-capped price; this hook does not clamp it independently.
    /// @param newMarkPrice Planner-approved mark price, with 8 decimals.
    /// @param newMarkTime Oracle publish timestamp for the mark, in Unix seconds.
    function settlementApplyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) external onlySettlementSidecar {
        if (newMarkTime <= lastMarkTime) {
            return;
        }
        _applyCarryAndMark(newMarkPrice, newMarkTime);
    }

    /// @notice Realizes collectible carry for an account-action flow delegated to the bound settlement sidecar.
    function settlementRealizeCarry(
        address account
    ) external onlySettlementSidecar {
        StoredPosition storage pos = _positions[account];
        if (pos.lots > 0) {
            _realizeCarryFromSettlement(account, pos);
        }
    }

    /// @notice Synchronizes aggregate side margin after settlement changes a position margin bucket.
    /// @dev Callable only by the configured settlement sidecar. Applies the checked difference between the two values.
    /// @param side Side whose aggregate margin is updated.
    /// @param marginBefore Account position margin before settlement, in 6-decimal settlement token units.
    /// @param marginAfter Account position margin after settlement, in 6-decimal settlement token units.
    function settlementSyncTotalSideMargin(
        CfdTypes.Side side,
        uint256 marginBefore,
        uint256 marginAfter
    ) external onlySettlementSidecar {
        _syncTotalSideMargin(side, marginBefore, marginAfter);
    }

    /// @notice Applies aggregate side-accounting deltas produced by the settlement sidecar.
    /// @dev Callable only by the configured settlement sidecar. Solidity checked arithmetic rejects any negative
    ///      delta whose magnitude exceeds the corresponding aggregate.
    /// @param side Side whose totals are mutated.
    /// @param maxProfitDelta Signed maximum-profit envelope delta, in 6-decimal settlement token units.
    /// @param openInterestDelta Signed synthetic open-interest delta, with 18 decimals.
    /// @param entryNotionalDelta Signed exact entry-cost delta scaled by `1e20`, with 26-decimal precision.
    function settlementApplySideDelta(
        CfdTypes.Side side,
        int256 maxProfitDelta,
        int256 openInterestDelta,
        int256 entryNotionalDelta
    ) external onlySettlementSidecar {
        SideState storage sideState = _sideState(side);
        if (maxProfitDelta >= 0) {
            sideState.maxProfitAssets += uint256(maxProfitDelta);
        } else {
            sideState.maxProfitAssets -= uint256(-maxProfitDelta);
        }
        if (openInterestDelta >= 0) {
            sideState.openInterest += uint256(openInterestDelta);
        } else {
            sideState.openInterest -= uint256(-openInterestDelta);
        }
        if (entryNotionalDelta >= 0) {
            sideState.entryNotional += uint256(entryNotionalDelta);
        } else {
            sideState.entryNotional -= uint256(-entryNotionalDelta);
        }
    }

    /// @notice Consumes previously recorded trader-claim balance during settlement.
    /// @dev Callable only by the configured settlement sidecar. This reduces account and aggregate liabilities but
    ///      does not itself transfer cash. A zero amount is a no-op; an excessive amount reverts by checked arithmetic.
    /// @param account Claim account to debit.
    /// @param amountAssets Claim liability to consume, in 6-decimal settlement token units.
    function settlementConsumeTraderClaim(
        address account,
        uint256 amountAssets
    ) external onlySettlementSidecar {
        _consumeTraderClaim(account, amountAssets);
    }

    /// @notice Pays or records trader-claim value during settlement.
    /// @dev Callable only by the configured settlement sidecar. Value is paid immediately through the clearinghouse
    ///      only from HousePool cash not reserved for existing trader claims; otherwise the full amount is recorded as
    ///      a new senior trader-claim liability. A zero amount is a no-op.
    /// @param account Claim beneficiary.
    /// @param amountAssets Payout or claim amount, in 6-decimal settlement token units.
    /// @param positionRemainsOpen Whether immediate cash is credited to PnL pledge instead of free settlement.
    function settlementRecordTraderClaim(
        address account,
        uint256 amountAssets,
        bool positionRemainsOpen
    ) external onlySettlementSidecar {
        _payOrRecordTraderClaim(account, amountAssets, positionRemainsOpen);
    }

    /// @notice Writes the post-settlement position state and refreshes side borrow-base accounting.
    /// @dev Callable only by the configured settlement sidecar. Removes the prior side borrow-base contribution,
    ///      copies engine-owned fields, recomputes borrow base from the current clearinghouse position-margin bucket,
    ///      stores the current side carry index, and adds the new side contribution. Margin itself is not stored here,
    ///      and deletion uses `settlementDeletePosition`.
    /// @param account Position account to overwrite.
    /// @param position New engine-owned position fields supplied by the settlement sidecar.
    function settlementWritePosition(
        address account,
        CfdEngineSettlementTypes.PositionState calldata position
    ) external onlySettlementSidecar {
        StoredPosition storage pos = _positions[account];
        if (pos.lots > 0 || pos.borrowBaseAssets > 0) {
            _applySideBorrowBaseDelta(pos.side, pos.borrowBaseAssets, 0);
        }
        if (pos.lots == 0) {
            ++positionEpoch[account];
        }
        uint256 newBorrowBaseAssets =
            _positionBorrowBase(position.maxProfitAssets, _positionMarginBucketAssets(account));
        uint256 lots = CfdMath.sizeToLots(position.size);
        if (lots == 0 || lots > type(uint112).max || position.entryCostAssetAtoms > type(uint144).max) {
            revert CfdEngine__InvalidRiskParams();
        }
        pos.lots = uint112(lots);
        pos.entryCostAssetAtoms = uint144(position.entryCostAssetAtoms);
        pos.maxProfitAssets = position.maxProfitAssets;
        pos.side = position.side;
        pos.lastUpdateTime = position.lastUpdateTime;
        pos.lastCarryTimestamp = position.lastCarryTimestamp;
        pos.borrowBaseAssets = newBorrowBaseAssets;
        pos.lastCarryIndex = _currentSideCarryIndex(position.side, block.timestamp, _poolAssetsForCarry());
        pos.vpiAccrued = position.vpiAccrued;
        _applySideBorrowBaseDelta(position.side, 0, newBorrowBaseAssets);
    }

    /// @notice Deletes an account position and removes its side borrow-base contribution.
    /// @dev Callable only by the configured settlement sidecar. Clearinghouse margin must be settled separately.
    /// @param account Position account to delete.
    function settlementDeletePosition(
        address account
    ) external onlySettlementSidecar {
        StoredPosition storage pos = _positions[account];
        if (pos.lots > 0 || pos.borrowBaseAssets > 0) {
            _applySideBorrowBaseDelta(pos.side, pos.borrowBaseAssets, 0);
        }
        delete _positions[account];
    }

    function _applyOpen(
        CfdEnginePlanTypes.OpenDelta memory delta,
        uint64 publishTime
    ) internal {
        bytes32 expectedOldHash = _beginTerminalCurveMutation(delta.account);
        StoredPosition storage pos = _positions[delta.account];
        if (pos.lots > 0) {
            _realizeCarryFromSettlement(delta.account, pos);
        } else {
            // A historical fill can predate the cached mark, so settlement may leave mark state untouched.
            // Checkpoint old aggregate borrowing before the new position changes side bases or pool depth.
            _advanceAllCarryIndexes(block.timestamp);
        }
        CfdTypes.Position memory currentPosition = _loadPosition(delta.account);
        settlementSidecar.executeOpen(delta, currentPosition, publishTime);
        _endTerminalCurveMutation(delta.account, expectedOldHash);

        emit PositionOpened(delta.account, delta.posSide, delta.sizeDelta, delta.price, delta.marginDeltaAssets);
    }

    function _applyClose(
        CfdEnginePlanTypes.CloseDelta memory delta,
        uint64 publishTime
    ) internal {
        bytes32 expectedOldHash = _beginTerminalCurveMutation(delta.account);
        StoredPosition storage pos = _positions[delta.account];
        CfdTypes.Side marginSide = pos.side;
        _realizeCarryFromSettlement(delta.account, pos);
        CfdTypes.Position memory currentPosition = _loadPosition(delta.account);
        settlementSidecar.executeClose(delta, currentPosition, publishTime);
        emit PositionClosed(delta.account, marginSide, delta.sizeDelta, delta.price, delta.realizedPnlAssets);

        unsettledCarryAssets[delta.account] = 0;

        _enterDegradedModeIfInsolvent(delta.account, 0);
        _endTerminalCurveMutation(delta.account, expectedOldHash);
    }

    function _applyLiquidation(
        CfdEnginePlanTypes.LiquidationDelta memory delta,
        uint64 publishTime,
        address keeper
    ) internal returns (uint256 keeperBountyAssets) {
        bytes32 expectedOldHash = _beginTerminalCurveMutation(delta.account);
        _realizeCarryFromSettlement(delta.account, _positions[delta.account]);
        bool syncKeeper = delta.keeperBountyAssets > 0 && keeper != delta.account && _positions[keeper].lots > 0;
        bytes32 keeperExpectedOldHash;
        if (syncKeeper) {
            keeperExpectedOldHash = _beginTerminalCurveMutation(keeper);
        }
        if (delta.keeperBountyAssets > 0 && keeper != delta.account) {
            _checkpointBountyRecipient(keeper, delta.price, publishTime);
        }
        keeperBountyAssets = settlementSidecar.executeLiquidation(delta, publishTime, keeper);
        emit PositionLiquidated(delta.account, delta.side, delta.posSize, delta.price, keeperBountyAssets);

        unsettledCarryAssets[delta.account] = 0;

        _enterDegradedModeIfInsolvent(delta.account, 0);
        _endTerminalCurveMutation(delta.account, expectedOldHash);
        if (syncKeeper) {
            _endTerminalCurveMutation(keeper, keeperExpectedOldHash);
        }
    }

    function _enterDegradedModeIfInsolvent(
        address account,
        uint256 pendingPoolPayoutAssets
    ) internal {
        if (degradedMode) {
            return;
        }
        uint256 effectiveAssetsAfter = _availableCashForFreshPoolPayouts();
        if (effectiveAssetsAfter > pendingPoolPayoutAssets) {
            effectiveAssetsAfter -= pendingPoolPayoutAssets;
        } else {
            effectiveAssetsAfter = 0;
        }
        uint256 maxLiabilityAssets = _maxLiability();
        if (effectiveAssetsAfter < maxLiabilityAssets) {
            degradedMode = true;
            emit DegradedModeEntered(effectiveAssetsAfter, maxLiabilityAssets, account);
        }
    }

    function _positionMarginBucketAssets(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.pnlPledgeAssets(account);
    }

    function _loadPosition(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        StoredPosition storage stored = _positions[account];
        pos.size = uint256(stored.lots) * CfdTypes.SIZE_QUANTUM;
        pos.margin = _positionMarginBucketAssets(account);
        pos.entryPrice = stored.lots == 0 ? 0 : uint256(stored.entryCostAssetAtoms) / uint256(stored.lots);
        pos.maxProfitAssets = stored.maxProfitAssets;
        pos.side = stored.side;
        pos.lastUpdateTime = stored.lastUpdateTime;
        pos.lastCarryTimestamp = stored.lastCarryTimestamp;
        pos.vpiAccrued = stored.vpiAccrued;
    }

    /// @dev Indexes have just advanced, so checkpoint against the stored index without recomputing utilization.
    function _checkpointPositionCarry(
        address account,
        StoredPosition storage pos
    ) private returns (uint256 carryDue) {
        _advanceAllCarryIndexes(block.timestamp);
        uint256 endIndex = sideCarryIndex[_sideIndex(pos.side)];
        carryDue = unsettledCarryAssets[account];
        // Side indexes are monotonic; a flat position has zero borrow base.
        carryDue += PositionRiskAccountingLib.computeIndexedCarryAssets(
            pos.borrowBaseAssets, endIndex - pos.lastCarryIndex
        );
        pos.lastCarryTimestamp = uint64(block.timestamp);
        pos.lastCarryIndex = endIndex;
    }

    function _realizeCarryFromSettlement(
        address account,
        StoredPosition storage pos
    ) internal returns (uint256 realizedCarryAssets) {
        uint256 carryDueAssets = _checkpointPositionCarry(account, pos);
        if (carryDueAssets == 0) {
            return 0;
        }

        uint256 marginBefore = _positionMarginBucketAssets(account);
        bytes32 expectedOldHash;
        if (marginBefore > 0) {
            expectedOldHash = _beginTerminalCurveMutation(account);
        }
        (uint256 marginConsumedAssets, uint256 freeSettlementConsumedAssets, uint256 uncoveredAssets) =
            clearinghouse.consumeSettlementLoss(account, carryDueAssets, address(this));
        realizedCarryAssets = carryDueAssets - uncoveredAssets;
        unsettledCarryAssets[account] = uncoveredAssets;

        if (marginConsumedAssets > 0) {
            _sideState(pos.side).totalMargin -= marginConsumedAssets;
            _syncPositionBorrowBaseToMargin(pos, marginBefore - marginConsumedAssets);
        }

        if (realizedCarryAssets > 0) {
            settlementToken.safeTransfer(address(pool), realizedCarryAssets);
            pool.recordClaimantInflow(
                realizedCarryAssets,
                IHousePool.ClaimantInflowKind.Revenue,
                IHousePool.ClaimantInflowCashMode.CashArrived
            );
        }
        emit CarryRealized(
            account,
            realizedCarryAssets,
            freeSettlementConsumedAssets,
            marginConsumedAssets,
            unsettledCarryAssets[account]
        );
        if (marginBefore > 0) {
            _endTerminalCurveMutation(account, expectedOldHash);
        }
    }

    function _consumeTraderClaim(
        address account,
        uint256 amountAssets
    ) internal {
        if (amountAssets == 0) {
            return;
        }

        _advanceAllCarryIndexes(block.timestamp);
        traderClaimBalanceAssets[account] -= amountAssets;
        totalTraderClaimBalanceAssets -= amountAssets;
    }

    /// @notice Updates the cached mark price without processing a trade or liquidation.
    /// @dev Callable only by the router. An equal timestamp is accepted only for an identical clamped price.
    /// @param price Oracle price, with 8 decimals; values above `CAP_PRICE` are capped.
    /// @param publishTime Oracle publish timestamp, in Unix seconds.
    function updateMarkPrice(
        uint256 price,
        uint64 publishTime
    ) external onlyRouter {
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }
        uint256 clamped = price > CAP_PRICE ? CAP_PRICE : price;
        _applyCarryAndMark(clamped, publishTime);
    }

    // ==========================================
    // MARK-TO-MARKET
    // ==========================================


}
