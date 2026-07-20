// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {CfdEngineSettlementTypes} from "@plether/perps/interfaces/CfdEngineSettlementTypes.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineSettlementHost} from "@plether/perps/interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IWithdrawGuard} from "@plether/perps/interfaces/IWithdrawGuard.sol";
import {CashPriorityLib} from "@plether/perps/libraries/CashPriorityLib.sol";
import {CfdEngineSnapshotsLib} from "@plether/perps/libraries/CfdEngineSnapshotsLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {MarketCalendarLib} from "@plether/perps/libraries/MarketCalendarLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

/// @title CfdEngine
/// @notice Canonical position ledger and execution coordinator for Plether's capped-price CFDs.
/// @dev Orders and liquidations enter through the authorized router. Economic deltas are computed by the planner,
///      then applied through the settlement sidecar while the engine remains the canonical position-state owner.
///      The clearinghouse custodies trader settlement balances and margin; the HousePool supplies counterparty cash.
///      Unless stated otherwise, prices use 8 decimals, position sizes use 18 decimals, USDC amounts use 6 decimals,
///      basis-point values use a 10,000 denominator, and timestamps are Unix seconds.
/// @custom:security-contact contact@plether.com
contract CfdEngine is ICfdEngineTypes, IWithdrawGuard, ICfdEngineAdminHost, Ownable2Step, ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    /// @notice Engine-owned fields for an open position.
    /// @dev Active margin is deliberately excluded: the clearinghouse position-margin bucket is its source of truth.
    struct StoredPosition {
        /// @notice Synthetic position size, with 18 decimals.
        uint256 size;
        /// @notice Volume-weighted entry price, with 8 decimals.
        uint256 entryPrice;
        /// @notice Capped maximum profit envelope, in 6-decimal USDC units.
        uint256 maxProfitUsdc;
        /// @notice Direction of the position.
        CfdTypes.Side side;
        /// @notice Unix timestamp of the last position mutation.
        uint64 lastUpdateTime;
        /// @notice Unix timestamp of the last position carry checkpoint.
        uint64 lastCarryTimestamp;
        /// @notice Carry basis `max(maxProfitUsdc - activeMarginUsdc, 0)`, in 6-decimal USDC units.
        uint256 borrowBaseUsdc;
        /// @notice Side carry index stored at the last position carry checkpoint, scaled by 1e18.
        uint256 lastCarryIndex;
        /// @notice Lifetime signed VPI balance in 6-decimal USDC units; positive is a charge and negative is a rebate.
        int256 vpiAccrued;
    }

    /// @notice Maximum supported oracle price, with 8 decimals; execution and mark-refresh inputs are capped here.
    uint256 public immutable CAP_PRICE;

    /// @notice Settlement token used for margin, fees, carry, recapitalization, and payouts.
    IERC20 public immutable USDC;
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

    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    /// @notice Aggregate position accounting by `CfdTypes.Side` index: `0` is BULL and `1` is BEAR.
    /// @dev Each entry contains the sum of maximum-profit envelopes, synthetic open interest, raw entry notional, and
    ///      active position margin for that side. Maximum profit and margin use 6-decimal USDC, open interest uses
    ///      18 decimals, and raw `size * entryPrice` entry notional uses 26 decimals.
    SideState[2] public sides;
    /// @notice Most recently accepted cached mark price, with 8 decimals and bounded by `CAP_PRICE` on router paths.
    uint256 public lastMarkPrice;
    /// @notice Oracle publish timestamp associated with `lastMarkPrice`, in Unix seconds.
    uint64 public lastMarkTime;
    /// @notice Aggregate carry borrow base by side index (`0` BULL; `1` BEAR), in 6-decimal USDC units.
    uint256[2] public sideBorrowBaseUsdc;
    /// @notice Cumulative utilization-adjusted carry multiplier by side index (`0` BULL; `1` BEAR), scaled by 1e18.
    uint256[2] public sideCarryIndex;
    /// @notice Wall-clock Unix timestamp through which each side carry index (`0` BULL; `1` BEAR) has been advanced.
    uint64[2] public sideCarryTimestamp;

    /// @notice Realized settlement shortfall not yet recapitalized, in 6-decimal USDC units.
    uint256 public accumulatedBadDebtUsdc;
    /// @notice Account carry checkpointed but not yet physically collected, in 6-decimal USDC units.
    mapping(address => uint256) public unsettledCarryUsdc;
    /// @notice Whether terminal settlement detected insolvency and latched risk-increasing operations off.
    bool public degradedMode;

    /// @notice Current VPI, skew, margin, carry, and liquidation-bounty parameters.
    /// @dev VPI factor and maximum skew ratio use 1e18 scaling; margin, carry, and bounty rates use basis points;
    ///      `minBountyUsdc` uses 6-decimal USDC units.
    CfdTypes.RiskParams public riskParams;
    mapping(address => StoredPosition) internal _positions;
    /// @notice Senior pool payout liability owed to each account, in 6-decimal USDC units.
    mapping(address => uint256) public traderClaimBalanceUsdc;
    /// @notice Aggregate outstanding trader-claim liability, in 6-decimal USDC units.
    uint256 public totalTraderClaimBalanceUsdc;
    /// @notice One-time-configured router authorized to reserve bounties and execute orders and liquidations.
    address public orderRouter;
    /// @notice Clearinghouse account credited with protocol execution fees and forfeited bounties.
    address public protocolTreasury;

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

    /// @notice Emitted when the clearinghouse account designated to receive future protocol fees changes.
    /// @param treasury New protocol treasury clearinghouse account.
    event ProtocolTreasuryUpdated(address indexed treasury);

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

    function _oppositeSide(
        CfdTypes.Side side
    ) internal pure returns (CfdTypes.Side) {
        return side == CfdTypes.Side.BULL ? CfdTypes.Side.BEAR : CfdTypes.Side.BULL;
    }

    function _sideAndOppositeStates(
        CfdTypes.Side side
    ) internal view returns (SideState storage selected, SideState storage opposite) {
        selected = _sideState(side);
        opposite = _sideState(_oppositeSide(side));
    }

    function _bullAndBearStates() internal view returns (SideState storage bullState, SideState storage bearState) {
        bullState = _sideState(CfdTypes.Side.BULL);
        bearState = _sideState(CfdTypes.Side.BEAR);
    }

    function _checkpointTraderClaimCarryIfPossible(
        address account,
        StoredPosition storage pos
    ) internal {
        if (pos.size == 0) {
            return;
        }

        _checkpointCarryBeforeBasisChange(account, pos);
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
        if (pos.size > 0) {
            _checkpointCarryBeforeBasisChange(account, pos);
        }
    }

    function _settleTraderClaimBalance(
        uint256 amount,
        address account
    ) internal returns (uint256 claimAmountUsdc) {
        claimAmountUsdc =
            CashPriorityLib.availableCashForClaimService(pool.totalAssets(), totalTraderClaimBalanceUsdc, amount);
        if (claimAmountUsdc == 0) {
            revert CfdEngine__InsufficientPoolLiquidity();
        }

        pool.payOut(address(clearinghouse), claimAmountUsdc);
        clearinghouse.settleUsdc(account, int256(claimAmountUsdc));
    }

    function _increaseClaimLiability(
        uint256 currentAmountUsdc,
        uint256 currentTotalUsdc,
        uint256 amountUsdc
    ) internal pure returns (uint256 updatedAmountUsdc, uint256 updatedTotalUsdc) {
        updatedAmountUsdc = currentAmountUsdc + amountUsdc;
        updatedTotalUsdc = currentTotalUsdc + amountUsdc;
    }

    function _decreaseClaimLiability(
        uint256 currentAmountUsdc,
        uint256 currentTotalUsdc,
        uint256 amountUsdc
    ) internal pure returns (uint256 updatedAmountUsdc, uint256 updatedTotalUsdc) {
        updatedAmountUsdc = currentAmountUsdc - amountUsdc;
        updatedTotalUsdc = currentTotalUsdc - amountUsdc;
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
    /// @dev The deployer becomes the two-step owner and initial protocol treasury account. The HousePool, router,
    ///      planner, settlement sidecar, and admin must be wired separately through their one-time setters.
    /// @param _usdc Settlement token treated by the protocol as USDC with 6 decimals.
    /// @param _clearinghouse Margin clearinghouse that custodies trader balances and margin buckets.
    /// @param _capPrice Nonzero maximum supported oracle price, with 8 decimals.
    /// @param _riskParams Initial risk parameters: VPI/skew fields use 1e18 scaling, rates use basis points, and the
    ///                    minimum bounty uses 6-decimal USDC units.
    /// @param _frozenCloseSpreadBps Initial nonzero LP-owned frozen-close spread, in basis points and at most 1,000.
    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams,
        uint256 _frozenCloseSpreadBps
    ) Ownable(msg.sender) {
        if (_usdc == address(0) || _clearinghouse == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (_capPrice == 0) {
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
        if (_riskParams.minBountyUsdc == 0 || _riskParams.bountyBps == 0) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.maxSkewRatio > CfdMath.WAD) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_frozenCloseSpreadBps == 0 || _frozenCloseSpreadBps > MAX_FROZEN_CLOSE_SPREAD_BPS) {
            revert CfdEngine__InvalidRiskParams();
        }
        USDC = IERC20(_usdc);
        clearinghouse = IMarginClearinghouse(_clearinghouse);
        CAP_PRICE = _capPrice;
        riskParams = _riskParams;
        frozenCloseSpreadBps = _frozenCloseSpreadBps;
        protocolTreasury = msg.sender;
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
    /// @dev Callable only by the owner; this setter does not probe the supplied address for an interface binding.
    /// @param _pool Nonzero HousePool address that provides counterparty liquidity.
    function setPool(
        address _pool
    ) external onlyOwner {
        if (_pool == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (address(pool) != address(0)) {
            revert CfdEngine__PoolAlreadySet();
        }
        pool = IHousePool(_pool);
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

    /// @notice Updates the clearinghouse account receiving protocol fees.
    /// @dev Callable only by the owner. For a change, the current treasury must have a zero clearinghouse balance;
    ///      no existing balance is migrated. Supplying the current treasury is a no-op.
    /// @param treasury Nonzero clearinghouse account that will receive future protocol fee credits.
    function setProtocolTreasury(
        address treasury
    ) external onlyOwner {
        if (treasury == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        address currentTreasury = protocolTreasury;
        if (treasury == currentTreasury) {
            return;
        }
        if (clearinghouse.balanceUsdc(currentTreasury) != 0) {
            revert CfdEngine__ProtocolTreasuryBalanceNotEmpty();
        }
        protocolTreasury = treasury;
        emit ProtocolTreasuryUpdated(treasury);
    }

    /// @notice Transfers a forfeited reserved execution bounty into the protocol treasury clearinghouse account.
    /// @dev Callable only by the router. This reclassifies clearinghouse balances without transferring ERC20 tokens;
    ///      a zero amount is a no-op. Emits `BountyCredited` for a nonzero transfer.
    /// @param sourceAccount Account whose reserved settlement bounty is forfeited.
    /// @param amountUsdc Reserved amount to transfer, in 6-decimal USDC units.
    function absorbReservedExecutionBounty(
        address sourceAccount,
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }

        address treasury = protocolTreasury;
        clearinghouse.transferReservedSettlement(sourceAccount, treasury, amountUsdc);
        emit BountyCredited(sourceAccount, treasury, amountUsdc);
    }

    /// @notice Transfers reserved bounty value from a source account into a beneficiary clearinghouse account.
    /// @dev Callable only by the router. For a beneficiary with an open position, carry is checkpointed before the
    ///      settlement credit changes reachable collateral; covered carry is physically realized and any uncovered
    ///      elapsed carry is added to `unsettledCarryUsdc`. A strictly newer mark is capped at `CAP_PRICE` and cached.
    ///      The engine relies on the router to validate the supplied mark. A zero amount is a complete no-op.
    /// @param sourceAccount Account whose reserved settlement bounty funds the credit.
    /// @param beneficiary Account receiving the clearinghouse settlement credit.
    /// @param amountUsdc Reserved amount to transfer, in 6-decimal USDC units.
    /// @param price Router-validated mark price used if `publishTime` is newer, with 8 decimals.
    /// @param publishTime Oracle publish timestamp associated with `price`, in Unix seconds.
    function creditBounty(
        address sourceAccount,
        address beneficiary,
        uint256 amountUsdc,
        uint256 price,
        uint64 publishTime
    ) external onlyRouter nonReentrant {
        if (amountUsdc == 0) {
            return;
        }

        _checkpointBountyRecipient(beneficiary, price, publishTime);
        clearinghouse.transferReservedSettlement(sourceAccount, beneficiary, amountUsdc);
        emit BountyCredited(sourceAccount, beneficiary, amountUsdc);
    }

    /// @notice Adds isolated margin to an existing open position without changing size.
    /// @dev The caller must equal `account`. Collectible accrued carry is realized first and any uncovered amount
    ///      remains unsettled; then clearinghouse free settlement is locked as active position margin and aggregate
    ///      side margin and borrow-base accounting are refreshed.
    /// @param account Position owner and required caller.
    /// @param amount Nonzero amount to move from free settlement into position margin, in 6-decimal USDC units.
    function addMargin(
        address account,
        uint256 amount
    ) external nonReentrant {
        if (msg.sender != account) {
            revert CfdEngine__NotAccountOwner();
        }
        if (amount == 0) {
            revert CfdEngine__PositionTooSmall();
        }

        StoredPosition storage pos = _positions[account];
        if (pos.size == 0) {
            revert CfdEngine__NoOpenPosition();
        }

        _realizeCarryFromSettlement(account, pos);

        uint256 marginBefore = _positionMarginBucketUsdc(account);
        clearinghouse.lockPositionMargin(account, amount);
        _syncTotalSideMargin(pos.side, marginBefore, _positionMarginBucketUsdc(account));
        _syncPositionBorrowBase(account, pos);
        pos.lastUpdateTime = uint64(block.timestamp);
        pos.lastCarryTimestamp = uint64(block.timestamp);

        emit MarginAdded(account, amount);
    }

    /// @notice Realizes or checkpoints accrued carry when the clearinghouse changes an account's collateral basis.
    /// @dev Callable only by the configured clearinghouse. The clearinghouse invokes this during deposits and before
    ///      withdrawals and other basis-changing bucket operations. Accounts without an open position are no-ops.
    /// @param account Account whose open-position carry should be realized or checkpointed.
    function realizeCarryBeforeMarginChange(
        address account
    ) external nonReentrant {
        if (msg.sender != address(clearinghouse)) {
            revert CfdEngine__NotClearinghouse();
        }

        StoredPosition storage pos = _positions[account];
        if (pos.size == 0) {
            return;
        }

        _realizeCarryFromSettlement(account, pos);
    }

    /// @notice Settles the caller's trader claim balance into the clearinghouse.
    /// @dev The caller must equal `account`. Settlement is all-or-nothing and is available only when HousePool cash
    ///      covers all outstanding trader claims. Side carry indexes and any open-position indexed carry are
    ///      checkpointed before the pool payout and clearinghouse credit change their respective carry bases.
    /// @param account Claim beneficiary and required caller.
    function settleTraderClaim(
        address account
    ) external nonReentrant {
        if (msg.sender != account) {
            revert CfdEngine__NotAccountOwner();
        }
        _advanceAllCarryIndexes(block.timestamp);
        StoredPosition storage pos = _positions[account];
        _checkpointTraderClaimCarryIfPossible(account, pos);

        uint256 amount = traderClaimBalanceUsdc[account];
        if (amount == 0) {
            revert CfdEngine__NoTraderClaim();
        }
        uint256 claimAmountUsdc = _settleTraderClaimBalance(amount, account);

        traderClaimBalanceUsdc[account] -= claimAmountUsdc;
        totalTraderClaimBalanceUsdc -= claimAmountUsdc;

        emit TraderClaimSettled(account, claimAmountUsdc);
    }

    /// @notice Reserves a close-order execution bounty from free settlement, then active position margin if needed.
    /// @dev Callable only by the router. Carry collection is attempted first, with any uncovered amount left unsettled.
    ///      The post-reservation position must retain sufficient risk backing at a cached mark; a stale mark is
    ///      accepted for this path. Any margin-backed share reduces aggregate side margin and the position carry
    ///      borrow base. A zero amount is a complete no-op.
    /// @param account Account committing the close order.
    /// @param sizeDelta Intended close size, with 18 decimals; must be nonzero and no greater than position size.
    /// @param amountUsdc Execution bounty to reserve, in 6-decimal USDC units.
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }

        StoredPosition storage pos = _positions[account];
        if (pos.size == 0) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }
        if (sizeDelta == 0 || sizeDelta > pos.size) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        bool isFullClose = sizeDelta == pos.size;
        (bool priceFresh, uint256 price) = _tryGetFreshLiveMarkPrice();
        if (price == 0) {
            price = lastMarkPrice;
        }
        if (price == 0) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }
        OracleFreshnessPolicyLib.Policy memory closeCommitPolicy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.CloseCommitFallback,
            isOracleFrozen(),
            isFadWindow(),
            engineMarkStalenessLimit,
            address(pool) == address(0) ? 0 : pool.markStalenessLimit(),
            0,
            0,
            fadMaxStaleness
        );
        if (closeCommitPolicy.requireStoredMark && lastMarkTime == 0) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        _realizeCarryFromSettlement(account, pos);

        uint256 positionMarginUsdc = _positionMarginBucketUsdc(account);
        uint256 freeSettlementUsdc = clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc;
        uint256 freeBackedBountyUsdc = freeSettlementUsdc > amountUsdc ? amountUsdc : freeSettlementUsdc;
        uint256 marginBackedBountyUsdc = amountUsdc - freeBackedBountyUsdc;
        if (positionMarginUsdc < marginBackedBountyUsdc) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        uint256 reachableUsdc = _genericReachableCollateralUsdc(account);
        if (reachableUsdc < amountUsdc) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        uint256 postReservationReachableUsdc = reachableUsdc - amountUsdc;
        _validateCloseBountyReservationRisk(
            account, price, positionMarginUsdc, marginBackedBountyUsdc, postReservationReachableUsdc, isFullClose
        );

        _syncTotalSideMargin(pos.side, positionMarginUsdc, positionMarginUsdc - marginBackedBountyUsdc);
        _syncPositionBorrowBaseToMargin(pos, positionMarginUsdc - marginBackedBountyUsdc);
        if (freeBackedBountyUsdc > 0) {
            if (priceFresh) {
                clearinghouse.reserveCloseExecutionBountyFromSettlement(account, freeBackedBountyUsdc);
            } else {
                clearinghouse.reserveStaleCloseExecutionBountyFromSettlement(account, freeBackedBountyUsdc);
            }
        }
        if (marginBackedBountyUsdc == 0) {
            return;
        }
        if (priceFresh) {
            clearinghouse.reserveCloseExecutionBountyFromPositionMargin(account, marginBackedBountyUsdc);
        } else {
            clearinghouse.reserveStaleCloseExecutionBountyFromPositionMargin(account, marginBackedBountyUsdc);
        }
    }

    /// @notice Recapitalizes the HousePool and reduces the engine's accumulated bad-debt balance.
    /// @dev Callable only by the owner. Side carry indexes are advanced before the pool-asset denominator changes.
    ///      Transfers USDC from the owner to the HousePool and records it as claimant-owned recapitalization inflow.
    /// @param amount Nonzero bad debt to clear, in 6-decimal USDC units; cannot exceed the outstanding balance.
    function clearBadDebt(
        uint256 amount
    ) external onlyOwner {
        if (amount == 0) {
            revert CfdEngine__ZeroAmount();
        }
        uint256 badDebt = accumulatedBadDebtUsdc;
        if (amount > badDebt) {
            revert CfdEngine__BadDebtTooLarge();
        }
        _advanceAllCarryIndexes(block.timestamp);
        USDC.safeTransferFrom(msg.sender, address(pool), amount);
        pool.recordClaimantInflow(
            amount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        accumulatedBadDebtUsdc = badDebt - amount;
        emit BadDebtCleared(amount, accumulatedBadDebtUsdc);
    }

    /// @notice Sweeps an arbitrary ERC20 accidentally sent to the engine.
    /// @dev Callable only by the owner. This can transfer only tokens held by the engine itself, not assets held by
    ///      the clearinghouse or HousePool.
    /// @param token Nonzero ERC20 token address to transfer.
    /// @param to Nonzero recipient of the swept tokens.
    /// @param amount Amount to sweep, in the token's native decimals.
    function sweepToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0) || token == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Clears degraded mode once adjusted solvency has recovered.
    /// @dev Callable only by the owner. Recovery requires HousePool physical assets net of senior trader claims to
    ///      cover the larger side's aggregate maximum-profit liability.
    function clearDegradedMode() external onlyOwner {
        if (!degradedMode) {
            revert CfdEngine__NotDegraded();
        }
        CfdEngineSnapshotsLib.SolvencySnapshot memory snapshot = _buildAdjustedSolvencySnapshot();
        if (snapshot.effectiveSolvencyAssets < snapshot.maxLiability) {
            revert CfdEngine__StillInsolvent();
        }
        degradedMode = false;
        emit DegradedModeCleared();
    }

    /// @notice Applies finalized risk parameters from the timelocked engine admin.
    /// @dev Callable only by `admin`, which is responsible for validation and timelock enforcement. Carry indexes are
    ///      advanced before the carry-rate parameter can change.
    /// @param config Validated configuration: VPI/skew fields use 1e18 scaling, the minimum bounty uses 6-decimal
    ///               USDC units, and margin, carry, bounty, execution-fee, and spread rates use basis points.
    function applyRiskConfig(
        ICfdEngineAdminHost.EngineRiskConfig calldata config
    ) external onlyAdmin {
        // CfdEngineAdmin is the sole caller and validates the staged configuration before finalization.
        _advanceAllCarryIndexes(block.timestamp);
        riskParams = config.riskParams;
        executionFeeBps = config.executionFeeBps;
        frozenCloseSpreadBps = config.frozenCloseSpreadBps;
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
    /// @dev Callable only by the clearinghouse after its provisional balance debit. Accounts without positions pass.
    ///      Open positions require non-degraded mode and a fresh cached mark. Collectible carry is then realized, any
    ///      remainder stays in pending carry, and position equity must exceed the stricter of initial margin and the
    ///      active maintenance/FAD margin requirement. Although stateful, every mutation rolls back if the enclosing
    ///      withdrawal fails.
    /// @param account Clearinghouse account whose post-withdrawal state is checked.
    function checkWithdraw(
        address account
    ) external override nonReentrant {
        if (msg.sender != address(clearinghouse)) {
            revert CfdEngine__NotClearinghouse();
        }

        CfdTypes.Position memory pos = _loadPosition(account);
        if (pos.size == 0) {
            return;
        }
        if (degradedMode) {
            revert CfdEngine__DegradedMode();
        }

        (bool priceFresh, uint256 price) = _tryGetFreshLiveMarkPrice();
        if (!priceFresh) {
            revert CfdEngine__MarkPriceStale();
        }

        uint256 reachableUsdc = _genericReachableCollateralUsdc(account);
        StoredPosition storage storedPos = _positions[account];
        _realizeCarryFromSettlement(account, storedPos);
        pos = _loadPosition(account);
        reachableUsdc = _genericReachableCollateralUsdc(account);
        uint256 pendingCarryUsdc = _totalPendingCarryUsdc(account, pos, block.timestamp);
        uint256 currentMarginBps = isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps;
        uint256 effectiveMarginBps =
            riskParams.initMarginBps > currentMarginBps ? riskParams.initMarginBps : currentMarginBps;
        PositionRiskAccountingLib.PositionRiskState memory riskState =
            PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
                pos, price, CAP_PRICE, pendingCarryUsdc, reachableUsdc, effectiveMarginBps
            );

        if (riskState.liquidatable) {
            revert CfdEngine__WithdrawBlockedByOpenPosition();
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
    /// @param poolDepthUsdc Router-supplied HousePool depth used for planning, in 6-decimal USDC units.
    /// @param publishTime Oracle publish timestamp for the execution mark, in Unix seconds.
    function processOrderTyped(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime
    ) external onlyRouter nonReentrant {
        _processOrder(order, currentOraclePrice, poolDepthUsdc, publishTime);
    }

    function _processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime
    ) internal {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(order.account, currentOraclePrice, poolDepthUsdc, publishTime);
        snap.poolCashUsdc = pool.totalAssets();

        if (order.isClose) {
            CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snap, order, currentOraclePrice, publishTime);
            _revertIfCloseInvalidTyped(delta.revertCode);
            _applyClose(delta, publishTime);
        } else {
            CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, currentOraclePrice, publishTime);
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
        if (marginAfter > marginBefore) {
            uint256 delta = marginAfter - marginBefore;
            _sideState(side).totalMargin += delta;
        } else if (marginBefore > marginAfter) {
            uint256 delta = marginBefore - marginAfter;
            _sideState(side).totalMargin -= delta;
        }
    }

    function _positionBorrowBase(
        uint256 maxProfitUsdc,
        uint256 marginUsdc
    ) internal pure returns (uint256) {
        return PositionRiskAccountingLib.computeBorrowBaseUsdc(maxProfitUsdc, marginUsdc);
    }

    function _applySideBorrowBaseDelta(
        CfdTypes.Side side,
        uint256 oldBorrowBaseUsdc,
        uint256 newBorrowBaseUsdc
    ) internal {
        uint256 index = _sideIndex(side);
        if (newBorrowBaseUsdc > oldBorrowBaseUsdc) {
            sideBorrowBaseUsdc[index] += newBorrowBaseUsdc - oldBorrowBaseUsdc;
        } else if (oldBorrowBaseUsdc > newBorrowBaseUsdc) {
            sideBorrowBaseUsdc[index] -= oldBorrowBaseUsdc - newBorrowBaseUsdc;
        }
    }

    function _syncPositionBorrowBase(
        address account,
        StoredPosition storage pos
    ) internal {
        _syncPositionBorrowBaseToMargin(pos, _positionMarginBucketUsdc(account));
    }

    function _syncPositionBorrowBaseToMargin(
        StoredPosition storage pos,
        uint256 marginUsdc
    ) internal {
        if (pos.size == 0) {
            return;
        }
        uint256 newBorrowBaseUsdc = _positionBorrowBase(pos.maxProfitUsdc, marginUsdc);
        _applySideBorrowBaseDelta(pos.side, pos.borrowBaseUsdc, newBorrowBaseUsdc);
        pos.borrowBaseUsdc = newBorrowBaseUsdc;
    }

    function _syncMarginQueue(
        address account,
        uint256 consumedCommittedReservationUsdc
    ) internal {
        if (consumedCommittedReservationUsdc == 0 || orderRouter == address(0)) {
            return;
        }
        IOrderRouterAccounting(orderRouter).syncMarginQueue(account);
    }

    function _payOrRecordTraderClaim(
        address account,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        if (_canPayFreshPoolPayout(amountUsdc)) {
            pool.payOut(address(clearinghouse), amountUsdc);
            clearinghouse.settleUsdc(account, int256(amountUsdc));
        } else {
            _recordTraderClaim(account, amountUsdc);
            emit TraderClaimRecorded(account, amountUsdc);
        }
    }

    function _recordTraderClaim(
        address account,
        uint256 amountUsdc
    ) internal {
        (traderClaimBalanceUsdc[account], totalTraderClaimBalanceUsdc) =
            _increaseClaimLiability(traderClaimBalanceUsdc[account], totalTraderClaimBalanceUsdc, amountUsdc);
    }

    function _canPayFreshPoolPayout(
        uint256 amountUsdc
    ) internal view returns (bool) {
        return amountUsdc <= _freshPoolReservation().freeCashUsdc;
    }

    function _availableCashForFreshPoolPayouts() internal view returns (uint256) {
        return _freshPoolReservation().freeCashUsdc;
    }

    function _freshPoolReservation() internal view returns (CashPriorityLib.SeniorCashReservation memory reservation) {
        return CashPriorityLib.reserveFreshPayouts(pool.totalAssets(), totalTraderClaimBalanceUsdc);
    }

    // ==========================================
    // LIQUIDATIONS & FAD
    // ==========================================

    /// @notice Reports whether Friday Afternoon Deleverage restrictions are currently active.
    /// @dev The recurring window is Friday 19:00 UTC through Sunday 21:59:59 UTC. FAD is also active throughout an
    ///      admin-configured override day and during `fadRunwaySeconds` immediately before an override day.
    /// @return True when the recurring window, an override day, or its configured runway is active.
    function isFadWindow() public view returns (bool) {
        (bool fadWindow,) = _marketStatus();
        return fadWindow;
    }

    /// @notice Reports whether the engine is in the oracle-frozen regime where freshness policy can be relaxed.
    /// @dev The recurring window is Friday 22:00 UTC through Sunday 20:59:59 UTC. An admin-configured override freezes
    ///      its entire day. Unlike FAD, the frozen regime does not include the pre-override runway.
    /// @return True during the recurring oracle closure or an override day.
    function isOracleFrozen() public view returns (bool) {
        (, bool oracleFrozen) = _marketStatus();
        return oracleFrozen;
    }

    function _marketStatus() internal view returns (bool fadWindow, bool oracleFrozen) {
        uint256 timestamp = block.timestamp;
        uint256 today = timestamp / 86_400;
        bool todayOverride = fadDayOverrides[today];
        fadWindow =
            MarketCalendarLib.isFadWindow(timestamp, todayOverride, fadDayOverrides[today + 1], fadRunwaySeconds);
        oracleFrozen = MarketCalendarLib.isOracleFrozen(timestamp, todayOverride);
    }

    /// @notice Returns the canonical current position tuple for an account.
    /// @dev Margin is read from the clearinghouse position-margin bucket; all other fields are engine-owned.
    /// @param account Account to inspect.
    /// @return size Synthetic position size, with 18 decimals.
    /// @return margin Current active position margin, in 6-decimal USDC units.
    /// @return entryPrice Volume-weighted entry price, with 8 decimals.
    /// @return maxProfitUsdc Capped maximum profit envelope, in 6-decimal USDC units.
    /// @return side Position direction; the default enum value is returned when no position exists.
    /// @return lastUpdateTime Unix timestamp of the last position mutation.
    /// @return vpiAccrued Lifetime signed VPI balance in 6-decimal USDC units; positive is a charge.
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
        )
    {
        CfdTypes.Position memory pos = _loadPosition(account);
        return (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued);
    }

    /// @notice Returns the carry-index basis stored for an account's current position.
    /// @param account Account to inspect.
    /// @return borrowBaseUsdc Position borrow base used for carry utilization, in 6-decimal USDC units.
    /// @return lastCarryIndex Side carry index stored at the position's last checkpoint, scaled by 1e18.
    /// @return lastCarryTimestamp Unix timestamp of the position's last carry checkpoint.
    function positionCarryState(
        address account
    ) external view returns (uint256 borrowBaseUsdc, uint256 lastCarryIndex, uint64 lastCarryTimestamp) {
        StoredPosition storage pos = _positions[account];
        return (pos.borrowBaseUsdc, pos.lastCarryIndex, pos.lastCarryTimestamp);
    }

    /// @notice Plans and settles liquidation of an undercollateralized position.
    /// @dev Callable only by the router. The planner accounts for pending carry, reachable collateral, the keeper
    ///      bounty, any trader residual payout or claim, and bad debt. Settlement removes the position and its side
    ///      aggregates and may latch degraded mode if effective pool assets no longer cover maximum liability.
    /// @param account Clearinghouse account that owns the position.
    /// @param currentOraclePrice Liquidation oracle price, with 8 decimals; planning caps it at `CAP_PRICE`.
    /// @param poolDepthUsdc Router-supplied HousePool depth used for planning, in 6-decimal USDC units.
    /// @param publishTime Oracle publish timestamp for the liquidation mark, in Unix seconds.
    /// @param keeper Clearinghouse account credited with any liquidation bounty.
    /// @return keeperBountyUsdc Bounty credited to the keeper, in 6-decimal USDC units.
    function liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime,
        address keeper
    ) external onlyRouter nonReentrant returns (uint256 keeperBountyUsdc) {
        return _liquidatePosition(account, currentOraclePrice, poolDepthUsdc, publishTime, keeper);
    }

    function _liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime,
        address keeper
    ) internal returns (uint256 keeperBountyUsdc) {
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }
        if (_positions[account].size == 0) {
            revert CfdEngine__NoPositionToLiquidate();
        }

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(account, currentOraclePrice, poolDepthUsdc, publishTime);
        snap.poolCashUsdc = pool.totalAssets();
        CfdEnginePlanTypes.LiquidationDelta memory delta =
            planner.planLiquidation(snap, currentOraclePrice, publishTime);

        if (!delta.liquidatable) {
            revert CfdEngine__PositionIsSolvent();
        }

        return _applyLiquidation(delta, publishTime, keeper);
    }

    function _assertPostSolvency() internal view {
        SolvencyAccountingLib.SolvencyState memory state = _buildAdjustedSolvencyState();
        if (SolvencyAccountingLib.isInsolvent(state)) {
            revert CfdEngine__PostOpSolvencyBreach();
        }
    }

    function _maxLiability() internal view returns (uint256) {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        return SolvencyAccountingLib.getMaxLiability(bullState.maxProfitUsdc, bearState.maxProfitUsdc);
    }

    function _getWithdrawalReservedUsdc() internal view returns (uint256 reservedUsdc) {
        return _buildAdjustedSolvencyState().withdrawalReservedUsdc;
    }

    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        return
            SolvencyAccountingLib.buildSolvencyState(pool.totalAssets(), _maxLiability(), totalTraderClaimBalanceUsdc);
    }

    function _buildAdjustedSolvencySnapshot()
        internal
        view
        returns (CfdEngineSnapshotsLib.SolvencySnapshot memory snapshot)
    {
        SolvencyAccountingLib.SolvencyState memory state = _buildAdjustedSolvencyState();
        snapshot.physicalAssets = state.physicalAssetsUsdc;
        snapshot.netPhysicalAssets = state.netPhysicalAssetsUsdc;
        snapshot.maxLiability = state.maxLiabilityUsdc;
        snapshot.effectiveSolvencyAssets = state.effectiveAssetsUsdc;
    }

    // ==========================================
    // PLAN-APPLY: RAW SNAPSHOT BUILDER
    // ==========================================

    function _buildRawSnapshot(
        address account,
        uint256,
        uint256 poolDepthUsdc,
        uint64
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap.account = account;
        snap.position = _loadPosition(account);

        snap.currentTimestamp = block.timestamp;
        snap.lastMarkPrice = lastMarkPrice;
        snap.lastMarkTime = lastMarkTime;
        snap.positionBorrowBaseUsdc = _positions[account].borrowBaseUsdc;
        snap.positionLastCarryIndex = _positions[account].lastCarryIndex;

        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        snap.bullSide = _copySideSnapshot(CfdTypes.Side.BULL, poolDepthUsdc, bullState);
        snap.bearSide = _copySideSnapshot(CfdTypes.Side.BEAR, poolDepthUsdc, bearState);

        snap.poolAssetsUsdc = poolDepthUsdc;
        snap.poolCashUsdc = poolDepthUsdc;

        snap.accountBuckets = clearinghouse.getAccountUsdcBuckets(account);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        snap.position.margin = snap.lockedBuckets.positionMarginUsdc;

        snap.accumulatedBadDebtUsdc = accumulatedBadDebtUsdc;
        snap.unsettledCarryUsdc = unsettledCarryUsdc[account];
        snap.totalTraderClaimBalanceUsdc = totalTraderClaimBalanceUsdc;
        snap.traderClaimBalanceForAccount = traderClaimBalanceUsdc[account];
        snap.degradedMode = degradedMode;

        snap.capPrice = CAP_PRICE;
        snap.riskParams = riskParams;
        snap.executionFeeBps = executionFeeBps;
        (snap.isFadWindow, snap.oracleFrozen) = _marketStatus();
        snap.frozenCloseSpreadBps = frozenCloseSpreadBps;
    }

    function _copySideSnapshot(
        CfdTypes.Side side,
        uint256 poolAssetsUsdc,
        SideState storage state
    ) internal view returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        snap.maxProfitUsdc = state.maxProfitUsdc;
        snap.openInterest = state.openInterest;
        snap.entryNotional = state.entryNotional;
        snap.totalMargin = state.totalMargin;
        snap.borrowBaseUsdc = sideBorrowBaseUsdc[_sideIndex(side)];
        snap.carryIndex = _currentSideCarryIndex(side, block.timestamp, poolAssetsUsdc);
    }

    function _tryGetFreshLiveMarkPrice() internal view returns (bool fresh, uint256 price) {
        price = lastMarkPrice;
        if (price == 0) {
            return (false, 0);
        }

        uint256 age = block.timestamp > lastMarkTime ? block.timestamp - lastMarkTime : 0;
        if (age > _liveMarkStalenessLimit()) {
            return (false, 0);
        }

        return (true, price);
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
            planner.getExecutionFailurePolicyCategory(code), uint8(code), false
        );
    }

    function _revertIfCloseInvalidTyped(
        CfdEnginePlanTypes.CloseRevertCode code
    ) internal view {
        if (code == CfdEnginePlanTypes.CloseRevertCode.OK) {
            return;
        }

        revert ICfdEngineTypes.CfdEngine__TypedOrderFailure(
            planner.getCloseExecutionFailurePolicyCategory(code), uint8(code), true
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
        lastMarkPrice = newMarkPrice;
        lastMarkTime = newMarkTime;
    }

    /// @notice Permissionlessly advances both side carry indexes to the current wall-clock timestamp.
    /// @dev Accrual uses each side's current borrow base, current HousePool effective assets
    ///      (`min(raw balance, accountedAssets)`), and `baseCarryBps`.
    ///      This does not checkpoint a position, collect carry from an account, or update the oracle mark.
    function checkpointCarryIndexes() external {
        _advanceAllCarryIndexes(block.timestamp);
    }

    function _advanceAllCarryIndexes(
        uint256 timestampNow
    ) internal {
        _advanceSideCarryIndex(CfdTypes.Side.BULL, timestampNow);
        _advanceSideCarryIndex(CfdTypes.Side.BEAR, timestampNow);
    }

    function _advanceSideCarryIndex(
        CfdTypes.Side side,
        uint256 timestampNow
    ) internal {
        uint256 index = _sideIndex(side);
        uint64 previousTimestamp = sideCarryTimestamp[index];
        if (timestampNow <= previousTimestamp) {
            return;
        }
        uint256 poolAssetsUsdc = address(pool) == address(0) ? 0 : pool.totalAssets();
        sideCarryIndex[index] = _currentSideCarryIndex(side, timestampNow, poolAssetsUsdc);
        sideCarryTimestamp[index] = uint64(timestampNow);
    }

    function _currentSideCarryIndex(
        CfdTypes.Side side,
        uint256 timestampNow,
        uint256 poolAssetsUsdc
    ) internal view returns (uint256 index) {
        uint256 sideIndex = _sideIndex(side);
        index = PositionRiskAccountingLib.computeCurrentCarryIndex(
            sideCarryIndex[sideIndex],
            sideCarryTimestamp[sideIndex],
            timestampNow,
            sideBorrowBaseUsdc[sideIndex],
            poolAssetsUsdc,
            riskParams.baseCarryBps
        );
    }

    function _poolAssetsForCarry() internal view returns (uint256) {
        return address(pool) == address(0) ? 0 : pool.totalAssets();
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

    /// @notice Synchronizes aggregate side margin after settlement changes a position margin bucket.
    /// @dev Callable only by the configured settlement sidecar. Applies the checked difference between the two values.
    /// @param side Side whose aggregate margin is updated.
    /// @param marginBefore Account position margin before settlement, in 6-decimal USDC units.
    /// @param marginAfter Account position margin after settlement, in 6-decimal USDC units.
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
    /// @param maxProfitDelta Signed maximum-profit envelope delta, in 6-decimal USDC units.
    /// @param openInterestDelta Signed synthetic open-interest delta, with 18 decimals.
    /// @param entryNotionalDelta Signed raw `size * entryPrice` delta, with 26 decimals.
    function settlementApplySideDelta(
        CfdTypes.Side side,
        int256 maxProfitDelta,
        int256 openInterestDelta,
        int256 entryNotionalDelta
    ) external onlySettlementSidecar {
        SideState storage sideState = _sideState(side);
        if (maxProfitDelta >= 0) {
            sideState.maxProfitUsdc += uint256(maxProfitDelta);
        } else {
            sideState.maxProfitUsdc -= uint256(-maxProfitDelta);
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
    /// @param amountUsdc Claim liability to consume, in 6-decimal USDC units.
    function settlementConsumeTraderClaim(
        address account,
        uint256 amountUsdc
    ) external onlySettlementSidecar {
        _consumeTraderClaim(account, amountUsdc);
    }

    /// @notice Pays or records trader-claim value during settlement.
    /// @dev Callable only by the configured settlement sidecar. Value is paid immediately through the clearinghouse
    ///      only from HousePool cash not reserved for existing trader claims; otherwise the full amount is recorded as
    ///      a new senior trader-claim liability. A zero amount is a no-op.
    /// @param account Claim beneficiary.
    /// @param amountUsdc Payout or claim amount, in 6-decimal USDC units.
    function settlementRecordTraderClaim(
        address account,
        uint256 amountUsdc
    ) external onlySettlementSidecar {
        _payOrRecordTraderClaim(account, amountUsdc);
    }

    /// @notice Increases accumulated bad debt during settlement.
    /// @dev Callable only by the configured settlement sidecar.
    /// @param amountUsdc Bad debt to add, in 6-decimal USDC units.
    function settlementAccumulateBadDebt(
        uint256 amountUsdc
    ) external onlySettlementSidecar {
        accumulatedBadDebtUsdc += amountUsdc;
    }

    /// @notice Writes the post-settlement position state and refreshes side borrow-base accounting.
    /// @dev Callable only by the configured settlement sidecar. Removes the prior side borrow-base contribution,
    ///      copies engine-owned fields, recomputes borrow base from the current clearinghouse position-margin bucket,
    ///      stores the current side carry index, and adds the new side contribution. Margin itself is not stored here,
    ///      and `position.deletePosition` is ignored; deletion uses `settlementDeletePosition`.
    /// @param account Position account to overwrite.
    /// @param position New engine-owned position fields supplied by the settlement sidecar.
    function settlementWritePosition(
        address account,
        CfdEngineSettlementTypes.PositionState calldata position
    ) external onlySettlementSidecar {
        StoredPosition storage pos = _positions[account];
        if (pos.size > 0 || pos.borrowBaseUsdc > 0) {
            _applySideBorrowBaseDelta(pos.side, pos.borrowBaseUsdc, 0);
        }
        uint256 newBorrowBaseUsdc = _positionBorrowBase(position.maxProfitUsdc, _positionMarginBucketUsdc(account));
        pos.size = position.size;
        pos.entryPrice = position.entryPrice;
        pos.maxProfitUsdc = position.maxProfitUsdc;
        pos.side = position.side;
        pos.lastUpdateTime = position.lastUpdateTime;
        pos.lastCarryTimestamp = position.lastCarryTimestamp;
        pos.borrowBaseUsdc = newBorrowBaseUsdc;
        pos.lastCarryIndex = _currentSideCarryIndex(position.side, block.timestamp, _poolAssetsForCarry());
        pos.vpiAccrued = position.vpiAccrued;
        _applySideBorrowBaseDelta(position.side, 0, newBorrowBaseUsdc);
    }

    /// @notice Deletes an account position and removes its side borrow-base contribution.
    /// @dev Callable only by the configured settlement sidecar. Clearinghouse margin must be settled separately.
    /// @param account Position account to delete.
    function settlementDeletePosition(
        address account
    ) external onlySettlementSidecar {
        StoredPosition storage pos = _positions[account];
        if (pos.size > 0 || pos.borrowBaseUsdc > 0) {
            _applySideBorrowBaseDelta(pos.side, pos.borrowBaseUsdc, 0);
        }
        delete _positions[account];
    }

    function _applyOpen(
        CfdEnginePlanTypes.OpenDelta memory delta,
        uint64 publishTime
    ) internal {
        StoredPosition storage pos = _positions[delta.account];
        CfdTypes.Position memory currentPosition = _loadPosition(delta.account);
        if (pos.size > 0) {
            _realizeCarryFromSettlement(delta.account, pos);
            currentPosition = _loadPosition(delta.account);
        }
        settlementSidecar.executeOpen(ICfdEngineSettlementHost(address(this)), delta, currentPosition, publishTime);
        _assertPostSolvency();

        emit PositionOpened(delta.account, delta.posSide, delta.sizeDelta, delta.price, delta.marginDeltaUsdc);
    }

    function _applyClose(
        CfdEnginePlanTypes.CloseDelta memory delta,
        uint64 publishTime
    ) internal {
        StoredPosition storage pos = _positions[delta.account];
        CfdTypes.Side marginSide = pos.side;
        CfdTypes.Position memory currentPosition = _loadPosition(delta.account);
        settlementSidecar.executeClose(ICfdEngineSettlementHost(address(this)), delta, currentPosition, publishTime);
        emit PositionClosed(delta.account, marginSide, delta.sizeDelta, delta.price, delta.realizedPnlUsdc);

        unsettledCarryUsdc[delta.account] = 0;

        _enterDegradedModeIfInsolvent(delta.account, 0);
    }

    function _applyLiquidation(
        CfdEnginePlanTypes.LiquidationDelta memory delta,
        uint64 publishTime,
        address keeper
    ) internal returns (uint256 keeperBountyUsdc) {
        if (delta.keeperBountyUsdc > 0 && keeper != delta.account) {
            _checkpointBountyRecipient(keeper, delta.price, publishTime);
        }
        keeperBountyUsdc =
            settlementSidecar.executeLiquidation(ICfdEngineSettlementHost(address(this)), delta, publishTime, keeper);
        emit PositionLiquidated(delta.account, delta.side, delta.posSize, delta.price, keeperBountyUsdc);

        unsettledCarryUsdc[delta.account] = 0;

        _enterDegradedModeIfInsolvent(delta.account, 0);
    }

    function _enterDegradedModeIfInsolvent(
        address account,
        uint256 pendingPoolPayoutUsdc
    ) internal {
        if (degradedMode) {
            return;
        }
        SolvencyAccountingLib.SolvencyState memory state = _buildAdjustedSolvencyState();
        uint256 effectiveAssetsAfter =
            SolvencyAccountingLib.effectiveAssetsAfterPendingPayout(state, pendingPoolPayoutUsdc);
        if (effectiveAssetsAfter < state.maxLiabilityUsdc) {
            degradedMode = true;
            emit DegradedModeEntered(effectiveAssetsAfter, state.maxLiabilityUsdc, account);
        }
    }

    function _genericReachableCollateralUsdc(
        address account
    ) internal view returns (uint256) {
        return MarginClearinghouseAccountingLib.getGenericReachableUsdc(clearinghouse.getAccountUsdcBuckets(account));
    }

    function _terminalReachableCollateralUsdc(
        address account
    ) internal view returns (uint256) {
        return MarginClearinghouseAccountingLib.getTerminalReachableUsdc(clearinghouse.getAccountUsdcBuckets(account));
    }

    function _positionMarginBucketUsdc(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.getLockedMarginBuckets(account).positionMarginUsdc;
    }

    function _loadPosition(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        StoredPosition storage stored = _positions[account];
        pos.size = stored.size;
        pos.margin = _positionMarginBucketUsdc(account);
        pos.entryPrice = stored.entryPrice;
        pos.maxProfitUsdc = stored.maxProfitUsdc;
        pos.side = stored.side;
        pos.lastUpdateTime = stored.lastUpdateTime;
        pos.lastCarryTimestamp = stored.lastCarryTimestamp;
        pos.vpiAccrued = stored.vpiAccrued;
    }

    function _elapsedCarryUsdc(
        address account,
        CfdTypes.Position memory pos,
        uint256 timestampNow
    ) internal view returns (uint256) {
        StoredPosition storage stored = _positions[account];
        if (pos.size == 0 || stored.borrowBaseUsdc == 0) {
            return 0;
        }
        uint256 endIndex = _currentSideCarryIndex(pos.side, timestampNow, _poolAssetsForCarry());
        uint256 startIndex = stored.lastCarryIndex;
        if (endIndex <= startIndex) {
            return 0;
        }
        return PositionRiskAccountingLib.computeIndexedCarryUsdc(stored.borrowBaseUsdc, endIndex - startIndex);
    }

    function _totalPendingCarryUsdc(
        address account,
        CfdTypes.Position memory pos,
        uint256 timestampNow
    ) internal view returns (uint256) {
        return unsettledCarryUsdc[account] + _elapsedCarryUsdc(account, pos, timestampNow);
    }

    function _validateCloseBountyReservationRisk(
        address account,
        uint256 price,
        uint256 positionMarginUsdc,
        uint256 marginBackedBountyUsdc,
        uint256 postReservationReachableUsdc,
        bool isFullClose
    ) internal view {
        CfdTypes.Position memory positionAfter = _loadPosition(account);
        positionAfter.margin = positionMarginUsdc - marginBackedBountyUsdc;

        uint256 pendingCarryUsdc = _totalPendingCarryUsdc(account, positionAfter, block.timestamp);
        PositionRiskAccountingLib.PositionRiskState memory riskState =
            PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
                positionAfter,
                price,
                CAP_PRICE,
                pendingCarryUsdc,
                postReservationReachableUsdc,
                isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps
            );

        if (riskState.liquidatable && (!isFullClose || marginBackedBountyUsdc > 0)) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }
    }

    function _canFullyRealizeCarryFromSettlement(
        address account,
        CfdTypes.Position memory pos
    ) internal view returns (bool) {
        uint256 pendingCarryUsdc = _totalPendingCarryUsdc(account, pos, block.timestamp);
        if (pendingCarryUsdc == 0) {
            return true;
        }

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        return MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, pendingCarryUsdc).uncoveredUsdc == 0;
    }

    function _checkpointCarryBeforeBasisChange(
        address account,
        StoredPosition storage pos
    ) internal {
        if (_canFullyRealizeCarryFromSettlement(account, _loadPosition(account))) {
            _realizeCarryFromSettlement(account, pos);
            return;
        }

        uint256 elapsedCarryUsdc = _elapsedCarryUsdc(account, _loadPosition(account), block.timestamp);
        if (elapsedCarryUsdc > 0) {
            unsettledCarryUsdc[account] += elapsedCarryUsdc;
            emit CarryCheckpointed(account, elapsedCarryUsdc, unsettledCarryUsdc[account]);
        }
        _advanceAllCarryIndexes(block.timestamp);
        pos.lastCarryTimestamp = uint64(block.timestamp);
        pos.lastCarryIndex = _currentSideCarryIndex(pos.side, block.timestamp, _poolAssetsForCarry());
    }

    function _realizeCarryFromSettlement(
        address account,
        StoredPosition storage pos
    ) internal returns (uint256 realizedCarryUsdc) {
        _advanceAllCarryIndexes(block.timestamp);
        CfdTypes.Position memory loaded = _loadPosition(account);
        uint256 carryDueUsdc = _totalPendingCarryUsdc(account, loaded, block.timestamp);
        if (carryDueUsdc == 0) {
            pos.lastCarryTimestamp = uint64(block.timestamp);
            pos.lastCarryIndex = _currentSideCarryIndex(pos.side, block.timestamp, _poolAssetsForCarry());
            return 0;
        }

        uint256 marginBefore = _positionMarginBucketUsdc(account);
        (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc) =
            clearinghouse.consumeSettlementLoss(account, marginBefore, carryDueUsdc, address(this));
        freeSettlementConsumedUsdc;
        realizedCarryUsdc = carryDueUsdc - uncoveredUsdc;
        unsettledCarryUsdc[account] = uncoveredUsdc;

        if (marginConsumedUsdc > 0) {
            _syncTotalSideMargin(pos.side, marginBefore, marginBefore - marginConsumedUsdc);
            _syncPositionBorrowBaseToMargin(pos, marginBefore - marginConsumedUsdc);
        }

        if (realizedCarryUsdc > 0) {
            USDC.safeTransfer(address(pool), realizedCarryUsdc);
            pool.recordClaimantInflow(
                realizedCarryUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
            );
        }
        emit CarryRealized(
            account, realizedCarryUsdc, freeSettlementConsumedUsdc, marginConsumedUsdc, unsettledCarryUsdc[account]
        );
        pos.lastCarryTimestamp = uint64(block.timestamp);
        pos.lastCarryIndex = _currentSideCarryIndex(pos.side, block.timestamp, _poolAssetsForCarry());
    }

    function _liveMarkStalenessLimit() internal view returns (uint256) {
        return OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.PoolReconcile,
            isOracleFrozen(),
            isFadWindow(),
            engineMarkStalenessLimit,
            address(pool) == address(0) ? 0 : pool.markStalenessLimit(),
            0,
            0,
            fadMaxStaleness
        )
        .maxStaleness;
    }

    function _consumeTraderClaim(
        address account,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        traderClaimBalanceUsdc[account] -= amountUsdc;
        totalTraderClaimBalanceUsdc -= amountUsdc;
    }

    /// @notice Updates the cached mark price without processing a trade or liquidation.
    /// @dev Callable only by the router. Reverts for a publish time older than `lastMarkTime`; an equal timestamp is
    ///      accepted. Advances both side carry indexes before caching the price, but does not collect position carry.
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

    function _getVaultMtmLiability() internal view returns (uint256) {
        if (lastMarkTime == 0) {
            return 0;
        }

        uint256 price = lastMarkPrice;
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        return CfdMath.conservativeMtmLiability(bullState.maxProfitUsdc, CfdTypes.Side.BULL, price, CAP_PRICE)
            + CfdMath.conservativeMtmLiability(bearState.maxProfitUsdc, CfdTypes.Side.BEAR, price, CAP_PRICE);
    }

}
