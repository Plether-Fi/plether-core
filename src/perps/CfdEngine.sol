// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {CfdEngineSettlementTypes} from "./interfaces/CfdEngineSettlementTypes.sol";
import {ICfdEngineAdminHost} from "./interfaces/ICfdEngineAdminHost.sol";
import {ICfdEnginePlanner} from "./interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineSettlementHost} from "./interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineSettlementSidecar} from "./interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "./interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "./interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
import {CashPriorityLib} from "./libraries/CashPriorityLib.sol";
import {CfdEngineSnapshotsLib} from "./libraries/CfdEngineSnapshotsLib.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {MarketCalendarLib} from "./libraries/MarketCalendarLib.sol";
import {OracleFreshnessPolicyLib} from "./libraries/OracleFreshnessPolicyLib.sol";
import {PositionRiskAccountingLib} from "./libraries/PositionRiskAccountingLib.sol";
import {SolvencyAccountingLib} from "./libraries/SolvencyAccountingLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title CfdEngine
/// @notice The core mathematical ledger for Plether CFDs.
/// @dev Settles all funds through the MarginClearinghouse and HousePool.
/// @custom:security-contact contact@plether.com
contract CfdEngine is ICfdEngineTypes, IWithdrawGuard, ICfdEngineAdminHost, Ownable2Step, ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    struct StoredPosition {
        uint256 size;
        uint256 entryPrice;
        uint256 maxProfitUsdc;
        CfdTypes.Side side;
        uint64 lastUpdateTime;
        uint64 lastCarryTimestamp;
        uint256 borrowBaseUsdc;
        uint256 lastCarryIndex;
        int256 vpiAccrued;
    }

    uint256 public immutable CAP_PRICE;

    IERC20 public immutable USDC;
    IMarginClearinghouse public immutable clearinghouse;
    IHousePool public pool;
    ICfdEnginePlanner public planner;
    ICfdEngineSettlementSidecar public settlementSidecar;
    address public admin;

    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    SideState[2] public sides;
    uint256 public lastMarkPrice;
    uint64 public lastMarkTime;
    uint256[2] public sideBorrowBaseUsdc;
    uint256[2] public sideCarryIndex;
    uint64[2] public sideCarryTimestamp;

    uint256 public accumulatedBadDebtUsdc;
    mapping(address => uint256) public unsettledCarryUsdc;
    bool public degradedMode;

    CfdTypes.RiskParams public riskParams;
    mapping(address => StoredPosition) internal _positions;
    mapping(address => uint256) public traderClaimBalanceUsdc;
    uint256 public totalTraderClaimBalanceUsdc;
    address public orderRouter;
    address public protocolTreasury;

    mapping(uint256 => bool) public fadDayOverrides;
    uint256[] private _fadOverrideDays;
    uint256 public fadMaxStaleness = 3 days;
    uint256 public fadRunwaySeconds = 3 hours;
    uint256 public engineMarkStalenessLimit = 60;
    uint256 public executionFeeBps = 4;

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

    /// @param _usdc USDC token used as margin and settlement currency
    /// @param _clearinghouse Margin clearinghouse that custodies trader balances
    /// @param _capPrice Maximum oracle price — positions are clamped here (also determines BULL max profit)
    /// @param _riskParams Initial risk parameters (margin requirements, carry rate, bounty config)
    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams
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
        USDC = IERC20(_usdc);
        clearinghouse = IMarginClearinghouse(_clearinghouse);
        CAP_PRICE = _capPrice;
        riskParams = _riskParams;
        protocolTreasury = msg.sender;
    }

    /// @notice One-time setter for planner, settlement sidecar, and admin sidecars.
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
        planner = ICfdEnginePlanner(planner_);
        settlementSidecar = ICfdEngineSettlementSidecar(settlementSidecar_);
        admin = admin_;
    }

    /// @notice One-time setter for the HousePool backing all positions
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

    /// @notice One-time setter for the authorized OrderRouter
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

    /// @notice Transfers forfeited reserved execution-bounty reservation into the protocol treasury account.
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
    /// @dev Realizes carry first when the beneficiary currently has an open position because the
    ///      clearinghouse settlement credit changes the carry basis.
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

    /// @notice Realizes accrued carry before a user-level clearinghouse balance mutation changes the carry basis.
    /// @dev Called only by the clearinghouse before user deposits and withdrawals.
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
    /// @dev Settlement is gated by aggregate trader-claim coverage. Funds are credited to the clearinghouse
    ///      first, so beneficiaries access them through the normal account-balance path. Carry is checkpointed
    ///      before the settlement-basis change using a fresh mark when available; otherwise the cached stored
    ///      mark is used.
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

    /// @notice Reduces accumulated bad debt after governance-confirmed recapitalization
    /// @param amount USDC amount of bad debt to clear (6 decimals)
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

    function applyRiskConfig(
        ICfdEngineAdminHost.EngineRiskConfig calldata config
    ) external onlyAdmin {
        if (config.executionFeeBps == 0 || config.executionFeeBps > 10_000) {
            revert CfdEngine__InvalidRiskParams();
        }
        _advanceAllCarryIndexes(block.timestamp);
        riskParams = config.riskParams;
        executionFeeBps = config.executionFeeBps;
    }

    function applyCalendarConfig(
        ICfdEngineAdminHost.EngineCalendarConfig calldata config
    ) external onlyAdmin {
        if (config.fadRunwaySeconds > 24 hours) {
            revert CfdEngine__RunwayTooLong();
        }
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

    function applyFreshnessConfig(
        ICfdEngineAdminHost.EngineFreshnessConfig calldata config
    ) external onlyAdmin {
        if (config.fadMaxStaleness == 0 || config.engineMarkStalenessLimit == 0) {
            revert CfdEngine__ZeroStaleness();
        }
        fadMaxStaleness = config.fadMaxStaleness;
        engineMarkStalenessLimit = config.engineMarkStalenessLimit;
    }

    // ==========================================
    // WITHDRAW GUARD (IWithdrawGuard)
    // ==========================================

    /// @notice Reverts if the account has an open position that would be undercollateralized after withdrawal
    /// @param account Clearinghouse account to check
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

        uint256 initialMarginRequirementUsdc = (riskState.currentNotionalUsdc * effectiveMarginBps) / 10_000;
        if (riskState.equityUsdc < int256(initialMarginRequirementUsdc) || riskState.liquidatable) {
            revert CfdEngine__WithdrawBlockedByOpenPosition();
        }
    }

    // ==========================================
    // 1. ORDER PROCESSING & NETTING
    // ==========================================

    /// @notice Router-facing order execution entrypoint with typed business-rule failures.
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

    /// @notice Returns true during the Friday Afternoon Deleverage (FAD) window
    ///         (Friday 19:00 UTC → Sunday 22:00 UTC), on admin-configured FAD days,
    ///         or within fadRunwaySeconds before an admin FAD day (deleverage runway).
    function isFadWindow() public view returns (bool) {
        uint256 today = block.timestamp / 86_400;
        return MarketCalendarLib.isFadWindow(
            block.timestamp, fadDayOverrides[today], fadDayOverrides[today + 1], fadRunwaySeconds
        );
    }

    /// @notice Returns true only when FX markets are closed and oracle freshness can be relaxed.
    ///         Distinct from FAD, which starts earlier for deleveraging risk controls.
    function isOracleFrozen() public view returns (bool) {
        return MarketCalendarLib.isOracleFrozen(block.timestamp, fadDayOverrides[block.timestamp / 86_400]);
    }

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

    function positionCarryState(
        address account
    ) external view returns (uint256 borrowBaseUsdc, uint256 lastCarryIndex, uint64 lastCarryTimestamp) {
        StoredPosition storage pos = _positions[account];
        return (pos.borrowBaseUsdc, pos.lastCarryIndex, pos.lastCarryTimestamp);
    }

    /// @notice Liquidates an undercollateralized position.
    ///         Surplus equity (after bounty) is returned to the user.
    ///         In bad-debt cases (equity < bounty), all remaining margin is seized by the pool.
    /// @param account Clearinghouse account that owns the position
    /// @param currentOraclePrice Pyth oracle price (8 decimals), clamped to CAP_PRICE
    /// @param poolDepthUsdc HousePool total assets used for post-op solvency checks and payout affordability
    /// @param publishTime Pyth publish timestamp, stored as lastMarkTime
    /// @param keeper Keeper that receives any liquidation bounty as clearinghouse credit
    /// @return keeperBountyUsdc Bounty paid to the liquidation keeper (USDC, 6 decimals)
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
        snap.isFadWindow = isFadWindow();
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

    function settlementApplyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) external onlySettlementSidecar {
        if (newMarkTime <= lastMarkTime) {
            return;
        }
        _applyCarryAndMark(newMarkPrice, newMarkTime);
    }

    function settlementSyncTotalSideMargin(
        CfdTypes.Side side,
        uint256 marginBefore,
        uint256 marginAfter
    ) external onlySettlementSidecar {
        _syncTotalSideMargin(side, marginBefore, marginAfter);
    }

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

    function settlementConsumeTraderClaim(
        address account,
        uint256 amountUsdc
    ) external onlySettlementSidecar {
        _consumeTraderClaim(account, amountUsdc);
    }

    function settlementRecordTraderClaim(
        address account,
        uint256 amountUsdc
    ) external onlySettlementSidecar {
        _payOrRecordTraderClaim(account, amountUsdc);
    }

    function settlementAccumulateBadDebt(
        uint256 amountUsdc
    ) external onlySettlementSidecar {
        accumulatedBadDebtUsdc += amountUsdc;
    }

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
    /// @dev This does not itself realize carry; carry realization happens on execution and margin-mutating paths.
    /// @param price Oracle price (8 decimals), clamped to CAP_PRICE
    /// @param publishTime Pyth publish timestamp
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
