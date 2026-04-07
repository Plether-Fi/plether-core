// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "./CfdEnginePlanner.sol";
import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdEnginePlanner} from "./interfaces/ICfdEnginePlanner.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
import {CashPriorityLib} from "./libraries/CashPriorityLib.sol";
import {CfdEnginePlanLib} from "./libraries/CfdEnginePlanLib.sol";
import {CfdEngineSnapshotsLib} from "./libraries/CfdEngineSnapshotsLib.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {MarketCalendarLib} from "./libraries/MarketCalendarLib.sol";
import {PositionRiskAccountingLib} from "./libraries/PositionRiskAccountingLib.sol";
import {SolvencyAccountingLib} from "./libraries/SolvencyAccountingLib.sol";
import {WithdrawalAccountingLib} from "./libraries/WithdrawalAccountingLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title CfdEngine
/// @notice The core mathematical ledger for Plether CFDs.
/// @dev Settles all funds through the MarginClearinghouse and CfdVault.
/// @custom:security-contact contact@plether.com
contract CfdEngine is IWithdrawGuard, Ownable2Step, ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    struct AccountCollateralView {
        uint256 settlementBalanceUsdc;
        uint256 lockedMarginUsdc;
        // Clearinghouse custody bucket for currently locked live position backing.
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
        // Current UI helper only; this does not include terminally reachable queued committed margin.
        uint256 closeReachableUsdc;
        uint256 terminalReachableUsdc;
        uint256 accountEquityUsdc;
        uint256 freeBuyingPowerUsdc;
        uint256 deferredPayoutUsdc;
    }

    struct PositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        uint256 entryNotionalUsdc;
        uint256 physicalReachableCollateralUsdc;
        uint256 nettableDeferredPayoutUsdc;
        int256 unrealizedPnlUsdc;
        int256 pendingFundingUsdc;
        int256 netEquityUsdc;
        uint256 maxProfitUsdc;
        bool liquidatable;
    }

    struct ProtocolAccountingView {
        uint256 vaultAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeUsdc;
        uint256 accumulatedFeesUsdc;
        int256 cappedFundingPnlUsdc;
        uint256 liabilityOnlyFundingPnlUsdc;
        uint256 totalDeferredPayoutUsdc;
        uint256 totalDeferredClearerBountyUsdc;
        bool degradedMode;
        bool hasLiveLiability;
    }

    struct ClosePreview {
        bool valid;
        CfdTypes.CloseInvalidReason invalidReason;
        uint256 executionPrice;
        uint256 sizeDelta;
        int256 realizedPnlUsdc;
        int256 fundingUsdc;
        int256 vpiDeltaUsdc;
        uint256 vpiUsdc;
        uint256 executionFeeUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 existingDeferredConsumedUsdc;
        uint256 existingDeferredRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 deferredPayoutUsdc;
        uint256 seizedCollateralUsdc;
        uint256 badDebtUsdc;
        uint256 remainingSize;
        uint256 remainingMargin;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
        int256 solvencyFundingPnlUsdc;
    }

    struct LiquidationPreview {
        bool liquidatable;
        uint256 oraclePrice;
        int256 equityUsdc;
        int256 pnlUsdc;
        int256 fundingUsdc;
        uint256 reachableCollateralUsdc;
        uint256 keeperBountyUsdc;
        uint256 seizedCollateralUsdc;
        uint256 settlementRetainedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 existingDeferredConsumedUsdc;
        uint256 existingDeferredRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 deferredPayoutUsdc;
        uint256 badDebtUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
        int256 solvencyFundingPnlUsdc;
    }

    struct DeferredPayoutStatus {
        uint256 deferredTraderPayoutUsdc;
        bool traderPayoutClaimableNow;
        uint256 deferredClearerBountyUsdc;
        bool liquidationBountyClaimableNow;
    }

    struct SideState {
        uint256 maxProfitUsdc;
        uint256 openInterest;
        uint256 entryNotional;
        // Cached aggregate of engine economic position margins for this side; not a custody bucket.
        uint256 totalMargin;
        int256 fundingIndex;
        int256 entryFunding;
    }

    struct VaultCashInflow {
        uint256 physicalCashReceivedUsdc;
        uint256 protocolOwnedUsdc;
        uint256 lpOwnedUsdc;
    }

    struct StoredPosition {
        uint256 size;
        uint256 entryPrice;
        uint256 maxProfitUsdc;
        int256 entryFundingIndex;
        CfdTypes.Side side;
        uint64 lastUpdateTime;
        int256 vpiAccrued;
    }

    uint256 public immutable CAP_PRICE;

    IERC20 public immutable USDC;
    IMarginClearinghouse public immutable clearinghouse;
    ICfdVault public vault;
    ICfdEnginePlanner public immutable planner;

    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    SideState[2] public sides;
    uint256 public lastMarkPrice;
    uint64 public lastMarkTime;

    uint256 public accumulatedFeesUsdc;
    uint256 public accumulatedBadDebtUsdc;
    bool public degradedMode;

    // ==========================================
    // FUNDING ACCUMULATORS
    // ==========================================

    uint64 public lastFundingTime;

    CfdTypes.RiskParams public riskParams;
    mapping(bytes32 => StoredPosition) internal _positions;
    mapping(bytes32 => uint256) public deferredPayoutUsdc;
    uint256 public totalDeferredPayoutUsdc;
    mapping(address => uint256) public deferredClearerBountyUsdc;
    uint256 public totalDeferredClearerBountyUsdc;
    mapping(uint64 => ICfdEngine.DeferredClaim) public deferredClaims;
    uint64 public nextDeferredClaimId = 1;
    uint64 public deferredClaimHeadId;
    uint64 public deferredClaimTailId;
    mapping(bytes32 => uint64) public traderDeferredClaimIdByAccount;
    mapping(address => uint64) public clearerDeferredClaimIdByKeeper;

    address public orderRouter;

    mapping(uint256 => bool) public fadDayOverrides;
    uint256 public fadMaxStaleness = 3 days;
    uint256 public fadRunwaySeconds = 3 hours;
    uint256 public engineMarkStalenessLimit = 60;

    uint256 public constant EXECUTION_FEE_BPS = 4;
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    CfdTypes.RiskParams public pendingRiskParams;
    uint256 public riskParamsActivationTime;

    uint256[] private _pendingAddFadDays;
    uint256 public addFadDaysActivationTime;

    uint256[] private _pendingRemoveFadDays;
    uint256 public removeFadDaysActivationTime;

    uint256 public pendingFadMaxStaleness;
    uint256 public fadMaxStalenessActivationTime;

    uint256 public pendingFadRunway;
    uint256 public fadRunwayActivationTime;

    uint256 public pendingEngineMarkStalenessLimit;
    uint256 public engineMarkStalenessActivationTime;

    error CfdEngine__Unauthorized();
    error CfdEngine__VaultAlreadySet();
    error CfdEngine__RouterAlreadySet();
    error CfdEngine__NoFeesToWithdraw();
    error CfdEngine__NoDeferredPayout();
    error CfdEngine__InsufficientVaultLiquidity();
    error CfdEngine__NoDeferredClearerBounty();
    error CfdEngine__DeferredClaimNotAtHead();
    error CfdEngine__MustCloseOpposingPosition();
    error CfdEngine__FundingExceedsMargin();
    error CfdEngine__VaultSolvencyExceeded();
    error CfdEngine__MarginDrainedByFees();
    error CfdEngine__CloseSizeExceedsPosition();
    error CfdEngine__NoPositionToLiquidate();
    error CfdEngine__PositionIsSolvent();
    error CfdEngine__PostOpSolvencyBreach();
    error CfdEngine__InsufficientInitialMargin();
    error CfdEngine__PositionTooSmall();
    error CfdEngine__WithdrawBlockedByOpenPosition();
    error CfdEngine__EmptyDays();
    error CfdEngine__ZeroStaleness();
    error CfdEngine__RunwayTooLong();
    error CfdEngine__PartialCloseUnderwaterFunding();
    error CfdEngine__DustPosition();
    error CfdEngine__MarkPriceStale();
    error CfdEngine__MarkPriceOutOfOrder();
    error CfdEngine__NotAccountOwner();
    error CfdEngine__NoOpenPosition();
    error CfdEngine__TimelockNotReady();
    error CfdEngine__NoProposal();
    error CfdEngine__BadDebtTooLarge();
    error CfdEngine__InvalidRiskParams();
    error CfdEngine__SkewTooHigh();
    error CfdEngine__DegradedMode();
    error CfdEngine__NotDegraded();
    error CfdEngine__StillInsolvent();
    error CfdEngine__ZeroAddress();
    error CfdEngine__InsufficientCloseOrderBountyBacking();
    error CfdEngine__InvalidVaultCashInflow();

    event FundingUpdated(int256 bullIndex, int256 bearIndex, uint256 absSkewUsdc);
    event PositionOpened(
        bytes32 indexed accountId, CfdTypes.Side side, uint256 sizeDelta, uint256 price, uint256 marginDelta
    );
    event PositionClosed(bytes32 indexed accountId, CfdTypes.Side side, uint256 sizeDelta, uint256 price, int256 pnl);
    event PositionLiquidated(
        bytes32 indexed accountId, CfdTypes.Side side, uint256 size, uint256 price, uint256 keeperBounty
    );
    event MarginAdded(bytes32 indexed accountId, uint256 amount);
    event FadDaysAdded(uint256[] timestamps);
    event FadDaysRemoved(uint256[] timestamps);
    event FadMaxStalenessUpdated(uint256 newStaleness);
    event FadRunwayUpdated(uint256 newRunway);
    event EngineMarkStalenessLimitProposed(uint256 newStaleness, uint256 activationTime);
    event EngineMarkStalenessLimitUpdated(uint256 newStaleness);
    event RiskParamsProposed(uint256 activationTime);
    event RiskParamsFinalized();
    event AddFadDaysProposed(uint256[] timestamps, uint256 activationTime);
    event AddFadDaysFinalized();
    event RemoveFadDaysProposed(uint256[] timestamps, uint256 activationTime);
    event RemoveFadDaysFinalized();
    event FadMaxStalenessProposed(uint256 newStaleness, uint256 activationTime);
    event FadMaxStalenessFinalized();
    event FadRunwayProposed(uint256 newRunway, uint256 activationTime);
    event FadRunwayFinalized();
    event BadDebtCleared(uint256 amount, uint256 remaining);
    event DegradedModeEntered(uint256 effectiveAssets, uint256 maxLiability, bytes32 indexed triggeringAccount);
    event DegradedModeCleared();
    event DeferredPayoutRecorded(bytes32 indexed accountId, uint256 amountUsdc);
    event DeferredPayoutClaimed(bytes32 indexed accountId, uint256 amountUsdc);
    event DeferredClearerBountyRecorded(address indexed keeper, uint256 amountUsdc);
    event DeferredClearerBountyClaimed(address indexed keeper, uint256 amountUsdc);

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

    function getSideState(
        CfdTypes.Side side
    ) public view returns (ICfdEngine.SideState memory state) {
        SideState storage stored = sides[_sideIndex(side)];
        state.maxProfitUsdc = stored.maxProfitUsdc;
        state.openInterest = stored.openInterest;
        state.entryNotional = stored.entryNotional;
        state.totalMargin = stored.totalMargin;
        state.fundingIndex = stored.fundingIndex;
        state.entryFunding = stored.entryFunding;
    }

    function _requireTimelockReady(
        uint256 activationTime
    ) internal view {
        if (activationTime == 0) {
            revert CfdEngine__NoProposal();
        }
        if (block.timestamp < activationTime) {
            revert CfdEngine__TimelockNotReady();
        }
    }

    modifier onlyRouter() {
        if (msg.sender != orderRouter) {
            revert CfdEngine__Unauthorized();
        }
        _;
    }

    /// @param _usdc USDC token used as margin and settlement currency
    /// @param _clearinghouse Margin clearinghouse that custodies trader balances
    /// @param _capPrice Maximum oracle price — positions are clamped here (also determines BULL max profit)
    /// @param _riskParams Initial risk parameters (margin requirements, funding curve, bounty config)
    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams
    ) Ownable(msg.sender) {
        _validateRiskParams(_riskParams);
        planner = new CfdEnginePlanner();
        USDC = IERC20(_usdc);
        clearinghouse = IMarginClearinghouse(_clearinghouse);
        CAP_PRICE = _capPrice;
        riskParams = _riskParams;
        lastFundingTime = uint64(block.timestamp);
    }

    /// @notice One-time setter for the HousePool vault backing all positions
    function setVault(
        address _vault
    ) external onlyOwner {
        if (_vault == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (address(vault) != address(0)) {
            revert CfdEngine__VaultAlreadySet();
        }
        vault = ICfdVault(_vault);
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

    /// @notice Proposes new risk parameters (margin BPS, funding curve, bounty config) subject to timelock
    function proposeRiskParams(
        CfdTypes.RiskParams memory _riskParams
    ) external onlyOwner {
        _validateRiskParams(_riskParams);
        pendingRiskParams = _riskParams;
        riskParamsActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RiskParamsProposed(riskParamsActivationTime);
    }

    /// @notice Applies proposed risk parameters after timelock expires; settles funding first
    function finalizeRiskParams() external onlyOwner {
        _requireTimelockReady(riskParamsActivationTime);
        riskParams = pendingRiskParams;
        delete pendingRiskParams;
        riskParamsActivationTime = 0;
        emit RiskParamsFinalized();
    }

    /// @notice Cancels a pending risk parameters proposal
    function cancelRiskParamsProposal() external onlyOwner {
        delete pendingRiskParams;
        riskParamsActivationTime = 0;
    }

    /// @notice Proposes adding FAD (Friday Afternoon Deleverage) override days — elevated margin on those dates
    function proposeAddFadDays(
        uint256[] calldata timestamps
    ) external onlyOwner {
        if (timestamps.length == 0) {
            revert CfdEngine__EmptyDays();
        }
        _pendingAddFadDays = timestamps;
        addFadDaysActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit AddFadDaysProposed(timestamps, addFadDaysActivationTime);
    }

    /// @notice Applies proposed FAD day additions after timelock expires
    function finalizeAddFadDays() external onlyOwner {
        _requireTimelockReady(addFadDaysActivationTime);
        uint256[] memory timestamps = _pendingAddFadDays;
        for (uint256 i; i < timestamps.length; i++) {
            fadDayOverrides[timestamps[i] / 86_400] = true;
        }
        delete _pendingAddFadDays;
        addFadDaysActivationTime = 0;
        emit FadDaysAdded(timestamps);
        emit AddFadDaysFinalized();
    }

    /// @notice Cancels a pending add-FAD-days proposal
    function cancelAddFadDaysProposal() external onlyOwner {
        delete _pendingAddFadDays;
        addFadDaysActivationTime = 0;
    }

    /// @notice Proposes removing FAD override days (restores normal margin on those dates)
    function proposeRemoveFadDays(
        uint256[] calldata timestamps
    ) external onlyOwner {
        if (timestamps.length == 0) {
            revert CfdEngine__EmptyDays();
        }
        _pendingRemoveFadDays = timestamps;
        removeFadDaysActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RemoveFadDaysProposed(timestamps, removeFadDaysActivationTime);
    }

    /// @notice Applies proposed FAD day removals after timelock expires
    function finalizeRemoveFadDays() external onlyOwner {
        _requireTimelockReady(removeFadDaysActivationTime);
        uint256[] memory timestamps = _pendingRemoveFadDays;
        for (uint256 i; i < timestamps.length; i++) {
            delete fadDayOverrides[timestamps[i] / 86_400];
        }
        delete _pendingRemoveFadDays;
        removeFadDaysActivationTime = 0;
        emit FadDaysRemoved(timestamps);
        emit RemoveFadDaysFinalized();
    }

    /// @notice Cancels a pending remove-FAD-days proposal
    function cancelRemoveFadDaysProposal() external onlyOwner {
        delete _pendingRemoveFadDays;
        removeFadDaysActivationTime = 0;
    }

    /// @notice Proposes a new fadMaxStaleness — max age of the last mark price before FAD kicks in
    function proposeFadMaxStaleness(
        uint256 _seconds
    ) external onlyOwner {
        if (_seconds == 0) {
            revert CfdEngine__ZeroStaleness();
        }
        pendingFadMaxStaleness = _seconds;
        fadMaxStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FadMaxStalenessProposed(_seconds, fadMaxStalenessActivationTime);
    }

    /// @notice Applies proposed fadMaxStaleness after timelock expires
    function finalizeFadMaxStaleness() external onlyOwner {
        _requireTimelockReady(fadMaxStalenessActivationTime);
        fadMaxStaleness = pendingFadMaxStaleness;
        pendingFadMaxStaleness = 0;
        fadMaxStalenessActivationTime = 0;
        emit FadMaxStalenessUpdated(fadMaxStaleness);
        emit FadMaxStalenessFinalized();
    }

    /// @notice Cancels a pending fadMaxStaleness proposal
    function cancelFadMaxStalenessProposal() external onlyOwner {
        pendingFadMaxStaleness = 0;
        fadMaxStalenessActivationTime = 0;
    }

    /// @notice Proposes a new fadRunway — how many seconds before an FAD day the elevated margin activates
    function proposeFadRunway(
        uint256 _seconds
    ) external onlyOwner {
        if (_seconds > 24 hours) {
            revert CfdEngine__RunwayTooLong();
        }
        pendingFadRunway = _seconds;
        fadRunwayActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FadRunwayProposed(_seconds, fadRunwayActivationTime);
    }

    /// @notice Applies proposed fadRunway after timelock expires
    function finalizeFadRunway() external onlyOwner {
        _requireTimelockReady(fadRunwayActivationTime);
        fadRunwaySeconds = pendingFadRunway;
        pendingFadRunway = 0;
        fadRunwayActivationTime = 0;
        emit FadRunwayUpdated(fadRunwaySeconds);
        emit FadRunwayFinalized();
    }

    /// @notice Cancels a pending fadRunway proposal
    function cancelFadRunwayProposal() external onlyOwner {
        pendingFadRunway = 0;
        fadRunwayActivationTime = 0;
    }

    function proposeEngineMarkStalenessLimit(
        uint256 newStaleness
    ) external onlyOwner {
        if (newStaleness == 0) {
            revert CfdEngine__ZeroStaleness();
        }
        pendingEngineMarkStalenessLimit = newStaleness;
        engineMarkStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit EngineMarkStalenessLimitProposed(newStaleness, engineMarkStalenessActivationTime);
    }

    function finalizeEngineMarkStalenessLimit() external onlyOwner {
        if (engineMarkStalenessActivationTime == 0) {
            revert CfdEngine__NoProposal();
        }
        if (block.timestamp < engineMarkStalenessActivationTime) {
            revert CfdEngine__TimelockNotReady();
        }
        engineMarkStalenessLimit = pendingEngineMarkStalenessLimit;
        pendingEngineMarkStalenessLimit = 0;
        engineMarkStalenessActivationTime = 0;
        emit EngineMarkStalenessLimitUpdated(engineMarkStalenessLimit);
    }

    function cancelEngineMarkStalenessLimitProposal() external onlyOwner {
        pendingEngineMarkStalenessLimit = 0;
        engineMarkStalenessActivationTime = 0;
    }

    /// @notice Withdraws accumulated execution fees from the vault to a recipient
    function withdrawFees(
        address recipient
    ) external onlyOwner {
        uint256 fees = accumulatedFeesUsdc;
        if (fees == 0) {
            revert CfdEngine__NoFeesToWithdraw();
        }
        if (!_canWithdrawProtocolFees(fees)) {
            revert CfdEngine__InsufficientVaultLiquidity();
        }
        accumulatedFeesUsdc = 0;
        vault.payOut(recipient, fees);
        _assertPostSolvency();
    }

    /// @notice Pulls router-custodied cancellation fees into the vault and books them as protocol revenue.
    function absorbRouterCancellationFee(
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }

        USDC.safeTransferFrom(msg.sender, address(vault), amountUsdc);
        vault.recordProtocolInflow(amountUsdc);
        accumulatedFeesUsdc += amountUsdc;
    }

    /// @notice Books router-delivered protocol-owned inflow as protocol fees after the router has already synced funding and funded the vault.
    function recordRouterProtocolFee(
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }

        accumulatedFeesUsdc += amountUsdc;
    }

    /// @notice Adds isolated margin to an existing open position without changing size.
    function addMargin(
        bytes32 accountId,
        uint256 amount
    ) external nonReentrant {
        if (bytes32(uint256(uint160(msg.sender))) != accountId) {
            revert CfdEngine__NotAccountOwner();
        }
        if (amount == 0) {
            revert CfdEngine__PositionTooSmall();
        }

        StoredPosition storage pos = _positions[accountId];
        if (pos.size == 0) {
            revert CfdEngine__NoOpenPosition();
        }

        uint256 marginBefore = _positionMarginBucketUsdc(accountId);
        clearinghouse.lockPositionMargin(accountId, amount);
        _syncTotalSideMargin(pos.side, marginBefore, _positionMarginBucketUsdc(accountId));
        pos.lastUpdateTime = uint64(block.timestamp);

        emit MarginAdded(accountId, amount);
    }

    /// @notice Claims a previously deferred profitable close payout into the clearinghouse.
    /// @dev The payout remains subject to current vault cash availability. Funds are credited to the
    ///      clearinghouse first, so traders access them through the normal account-balance path.
    function claimDeferredPayout(
        bytes32 accountId
    ) external nonReentrant {
        uint256 amount = deferredPayoutUsdc[accountId];
        if (amount == 0) {
            revert CfdEngine__NoDeferredPayout();
        }
        uint64 claimId = deferredClaimHeadId;
        ICfdEngine.DeferredClaim storage claim = deferredClaims[claimId];
        if (claim.claimType != ICfdEngine.DeferredClaimType.TraderPayout || claim.accountId != accountId) {
            revert CfdEngine__DeferredClaimNotAtHead();
        }

        uint256 claimAmountUsdc = _claimableHeadAmountUsdc();
        if (claimAmountUsdc == 0) {
            revert CfdEngine__InsufficientVaultLiquidity();
        }

        deferredPayoutUsdc[accountId] -= claimAmountUsdc;
        totalDeferredPayoutUsdc -= claimAmountUsdc;
        claim.remainingUsdc -= claimAmountUsdc;
        vault.payOut(address(clearinghouse), claimAmountUsdc);
        clearinghouse.settleUsdc(accountId, int256(claimAmountUsdc));
        if (claim.remainingUsdc == 0) {
            _popDeferredClaimHead();
        }

        emit DeferredPayoutClaimed(accountId, claimAmountUsdc);
    }

    /// @notice Claims a previously deferred clearer bounty when the vault has replenished cash.
    /// @dev Deferred keeper bounties settle to clearinghouse credit for the recorded keeper address-derived account,
    ///      rather than attempting a direct USDC wallet transfer.
    function claimDeferredClearerBounty() external nonReentrant {
        uint64 claimId = deferredClaimHeadId;
        ICfdEngine.DeferredClaim storage claim = deferredClaims[claimId];
        if (claim.claimType != ICfdEngine.DeferredClaimType.ClearerBounty) {
            revert CfdEngine__DeferredClaimNotAtHead();
        }
        address beneficiary = claim.keeper;
        if (clearerDeferredClaimIdByKeeper[beneficiary] != claimId) {
            revert CfdEngine__DeferredClaimNotAtHead();
        }
        uint256 amount = deferredClearerBountyUsdc[beneficiary];
        if (amount == 0) {
            revert CfdEngine__NoDeferredClearerBounty();
        }

        uint256 claimAmountUsdc = _claimableHeadAmountUsdc();
        if (claimAmountUsdc == 0) {
            revert CfdEngine__InsufficientVaultLiquidity();
        }

        deferredClearerBountyUsdc[beneficiary] -= claimAmountUsdc;
        totalDeferredClearerBountyUsdc -= claimAmountUsdc;
        claim.remainingUsdc -= claimAmountUsdc;
        vault.payOut(address(clearinghouse), claimAmountUsdc);
        clearinghouse.settleUsdc(bytes32(uint256(uint160(beneficiary))), int256(claimAmountUsdc));
        if (claim.remainingUsdc == 0) {
            _popDeferredClaimHead();
        }

        emit DeferredClearerBountyClaimed(beneficiary, claimAmountUsdc);
    }

    /// @notice Records a liquidation bounty that could not be paid immediately because vault cash was unavailable.
    function recordDeferredClearerBounty(
        address keeper,
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }
        _enqueueOrAccrueDeferredClearerBounty(keeper, amountUsdc);
        emit DeferredClearerBountyRecorded(keeper, amountUsdc);
    }

    function reserveCloseOrderExecutionBounty(
        bytes32 accountId,
        uint256 amountUsdc,
        address recipient
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }

        StoredPosition storage pos = _positions[accountId];
        uint256 positionMarginUsdc = _positionMarginBucketUsdc(accountId);
        if (pos.size == 0 || positionMarginUsdc < amountUsdc) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        (bool priceFresh, uint256 price) = _tryGetFreshLiveMarkPrice();
        if (!priceFresh) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        uint256 reachableUsdc = _physicalReachableCollateralUsdc(accountId);
        if (reachableUsdc < amountUsdc) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        CfdTypes.Position memory positionAfter = _loadPosition(accountId);
        positionAfter.margin = positionMarginUsdc - amountUsdc;
        PositionRiskAccountingLib.PositionRiskState memory riskState = _buildProjectedPositionRiskState(
            accountId,
            positionAfter,
            price,
            reachableUsdc - amountUsdc,
            isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps
        );
        if (riskState.liquidatable) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        _syncTotalSideMargin(pos.side, positionMarginUsdc, positionMarginUsdc - amountUsdc);
        clearinghouse.seizePositionMarginUsdc(accountId, amountUsdc, recipient);
    }

    /// @notice Reduces accumulated bad debt after governance-confirmed recapitalization
    /// @param amount USDC amount of bad debt to clear (6 decimals)
    function clearBadDebt(
        uint256 amount
    ) external onlyOwner {
        uint256 badDebt = accumulatedBadDebtUsdc;
        if (amount > badDebt) {
            revert CfdEngine__BadDebtTooLarge();
        }
        if (amount > 0) {
            USDC.safeTransferFrom(msg.sender, address(vault), amount);
            vault.recordRecapitalizationInflow(amount);
        }
        accumulatedBadDebtUsdc = badDebt - amount;
        emit BadDebtCleared(amount, accumulatedBadDebtUsdc);
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

    // ==========================================
    // WITHDRAW GUARD (IWithdrawGuard)
    // ==========================================

    /// @notice Reverts if the account has an open position that would be undercollateralized after withdrawal
    /// @param accountId Clearinghouse account to check
    function checkWithdraw(
        bytes32 accountId
    ) external view override {
        CfdTypes.Position memory pos = _loadPosition(accountId);
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

        uint256 reachableUsdc = _physicalReachableCollateralUsdc(accountId);
        PositionRiskAccountingLib.PositionRiskState memory riskState =
            _buildProjectedPositionRiskState(accountId, pos, price, reachableUsdc, riskParams.initMarginBps);

        uint256 initialMarginRequirementUsdc = (riskState.currentNotionalUsdc * riskParams.initMarginBps) / 10_000;
        if (riskState.equityUsdc < int256(initialMarginRequirementUsdc)) {
            revert CfdEngine__WithdrawBlockedByOpenPosition();
        }
    }

    // ==========================================
    // 1. ORDER PROCESSING & NETTING
    // ==========================================

    /// @notice Executes an order: settles funding, then increases or decreases the position.
    ///         Called exclusively by OrderRouter after MEV and slippage checks pass.
    /// @param order The order to execute (account, side, size delta, margin delta, isClose)
    /// @param currentOraclePrice Pyth oracle price (8 decimals), clamped to CAP_PRICE
    /// @param vaultDepthUsdc HousePool total assets — used to scale funding rate
    /// @param publishTime Pyth publish timestamp, stored as lastMarkTime
    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external onlyRouter nonReentrant {
        _processOrder(order, currentOraclePrice, vaultDepthUsdc, publishTime, false);
    }

    /// @notice Router-facing order execution entrypoint with typed business-rule failures.
    function processOrderTyped(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external onlyRouter nonReentrant {
        _processOrder(order, currentOraclePrice, vaultDepthUsdc, publishTime, true);
    }

    function _processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime,
        bool typedFailures
    ) internal {
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(order.accountId, currentOraclePrice, vaultDepthUsdc, publishTime);
        snap.vaultCashUsdc = vault.totalAssets();

        if (order.isClose) {
            CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snap, order, currentOraclePrice, publishTime);
            if (typedFailures) {
                _revertIfCloseInvalidTyped(delta.revertCode);
            } else {
                _revertIfCloseInvalid(delta.revertCode);
            }
            _applyClose(delta);
        } else {
            CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, currentOraclePrice, publishTime);
            if (typedFailures) {
                _revertIfOpenInvalidTyped(delta.revertCode);
            } else {
                _revertIfOpenInvalid(delta.revertCode);
            }
            _applyOpen(delta);
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

    function _syncMarginQueue(
        bytes32 accountId,
        uint256 consumedCommittedReservationUsdc
    ) internal {
        if (consumedCommittedReservationUsdc == 0 || orderRouter == address(0)) {
            return;
        }
        IOrderRouterAccounting(orderRouter).syncMarginQueue(accountId);
    }

    function _payOrRecordDeferredTraderPayout(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        if (_canPayFreshVaultPayout(amountUsdc)) {
            vault.payOut(address(clearinghouse), amountUsdc);
            clearinghouse.settleUsdc(accountId, int256(amountUsdc));
        } else {
            _enqueueOrAccrueDeferredTraderPayout(accountId, amountUsdc);
            emit DeferredPayoutRecorded(accountId, amountUsdc);
        }
    }

    function _enqueueOrAccrueDeferredTraderPayout(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        deferredPayoutUsdc[accountId] += amountUsdc;
        totalDeferredPayoutUsdc += amountUsdc;

        uint64 claimId = traderDeferredClaimIdByAccount[accountId];
        if (claimId == 0) {
            claimId =
                _enqueueDeferredClaim(ICfdEngine.DeferredClaimType.TraderPayout, accountId, address(0), amountUsdc);
            traderDeferredClaimIdByAccount[accountId] = claimId;
            return;
        }

        deferredClaims[claimId].remainingUsdc += amountUsdc;
    }

    function _enqueueOrAccrueDeferredClearerBounty(
        address keeper,
        uint256 amountUsdc
    ) internal {
        deferredClearerBountyUsdc[keeper] += amountUsdc;
        totalDeferredClearerBountyUsdc += amountUsdc;

        uint64 claimId = clearerDeferredClaimIdByKeeper[keeper];
        if (claimId == 0) {
            claimId = _enqueueDeferredClaim(ICfdEngine.DeferredClaimType.ClearerBounty, bytes32(0), keeper, amountUsdc);
            clearerDeferredClaimIdByKeeper[keeper] = claimId;
            return;
        }

        deferredClaims[claimId].remainingUsdc += amountUsdc;
    }

    function _accountVaultCashInflow(
        VaultCashInflow memory inflow
    ) internal {
        if (inflow.physicalCashReceivedUsdc == 0) {
            return;
        }

        if (inflow.protocolOwnedUsdc + inflow.lpOwnedUsdc > inflow.physicalCashReceivedUsdc) {
            revert CfdEngine__InvalidVaultCashInflow();
        }

        if (inflow.protocolOwnedUsdc > 0) {
            vault.recordProtocolInflow(inflow.protocolOwnedUsdc);
        }
        if (inflow.lpOwnedUsdc > 0) {
            vault.recordTradingRevenueInflow(inflow.lpOwnedUsdc);
        }
    }

    function _canPayFreshVaultPayout(
        uint256 amountUsdc
    ) internal view returns (bool) {
        return amountUsdc <= _freshVaultReservation().freeCashUsdc;
    }

    function _canWithdrawProtocolFees(
        uint256 amountUsdc
    ) internal view returns (bool) {
        return amountUsdc <= _freshVaultReservation().protocolFeeWithdrawalUsdc;
    }

    function _availableCashForFreshVaultPayouts() internal view returns (uint256) {
        return _freshVaultReservation().freeCashUsdc;
    }

    function _claimableHeadAmountUsdc() internal view returns (uint256) {
        uint64 claimId = deferredClaimHeadId;
        if (claimId == 0) {
            return 0;
        }

        return _headDeferredClaimReservation(deferredClaims[claimId].remainingUsdc).headClaimServiceableUsdc;
    }

    function _freshVaultReservation() internal view returns (CashPriorityLib.SeniorCashReservation memory reservation) {
        return CashPriorityLib.reserveFreshPayouts(
            vault.totalAssets(), accumulatedFeesUsdc, totalDeferredPayoutUsdc, totalDeferredClearerBountyUsdc
        );
    }

    function _headDeferredClaimReservation(
        uint256 headClaimAmountUsdc
    ) internal view returns (CashPriorityLib.SeniorCashReservation memory reservation) {
        return CashPriorityLib.reserveDeferredHeadClaim(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc,
            headClaimAmountUsdc
        );
    }

    function _enqueueDeferredClaim(
        ICfdEngine.DeferredClaimType claimType,
        bytes32 accountId,
        address keeper,
        uint256 amountUsdc
    ) internal returns (uint64 claimId) {
        claimId = nextDeferredClaimId++;
        deferredClaims[claimId] = ICfdEngine.DeferredClaim({
            claimType: claimType,
            accountId: accountId,
            keeper: keeper,
            remainingUsdc: amountUsdc,
            prevClaimId: deferredClaimTailId,
            nextClaimId: 0
        });

        if (deferredClaimTailId == 0) {
            deferredClaimHeadId = claimId;
            deferredClaimTailId = claimId;
            return claimId;
        }

        deferredClaims[deferredClaimTailId].nextClaimId = claimId;
        deferredClaimTailId = claimId;
        return claimId;
    }

    function _popDeferredClaimHead() internal {
        uint64 claimId = deferredClaimHeadId;
        if (claimId == 0) {
            return;
        }

        _unlinkDeferredClaim(claimId);
    }

    function _unlinkDeferredClaim(
        uint64 claimId
    ) internal {
        if (claimId == 0) {
            return;
        }

        ICfdEngine.DeferredClaim storage claim = deferredClaims[claimId];
        uint64 prevClaimId = claim.prevClaimId;
        uint64 nextClaimId = claim.nextClaimId;

        if (prevClaimId == 0) {
            deferredClaimHeadId = nextClaimId;
        } else {
            deferredClaims[prevClaimId].nextClaimId = nextClaimId;
        }

        if (nextClaimId == 0) {
            deferredClaimTailId = prevClaimId;
        } else {
            deferredClaims[nextClaimId].prevClaimId = prevClaimId;
        }

        if (claim.claimType == ICfdEngine.DeferredClaimType.TraderPayout) {
            bytes32 accountId = claim.accountId;
            if (traderDeferredClaimIdByAccount[accountId] == claimId) {
                delete traderDeferredClaimIdByAccount[accountId];
            }
        } else {
            address keeper = claim.keeper;
            if (clearerDeferredClaimIdByKeeper[keeper] == claimId) {
                delete clearerDeferredClaimIdByKeeper[keeper];
            }
        }

        delete deferredClaims[claimId];
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

    function hasOpenPosition(
        bytes32 accountId
    ) external view returns (bool) {
        return _positions[accountId].size > 0;
    }

    function positions(
        bytes32 accountId
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitUsdc,
            int256 entryFundingIndex,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        )
    {
        CfdTypes.Position memory pos = _loadPosition(accountId);
        return
            (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, 0, pos.side, pos.lastUpdateTime, pos.vpiAccrued);
    }

    function getPositionSize(
        bytes32 accountId
    ) external view returns (uint256) {
        return _positions[accountId].size;
    }

    function previewOpenRevertCode(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(accountId, oraclePrice, vault.totalAssets(), publishTime);
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: side,
            isClose: false
        });
        CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, oraclePrice, publishTime);
        return uint8(delta.revertCode);
    }

    function previewOpenFailurePolicyCategory(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(accountId, oraclePrice, vault.totalAssets(), publishTime);
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: side,
            isClose: false
        });
        CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, oraclePrice, publishTime);
        return planner.getOpenFailurePolicyCategory(delta.revertCode);
    }

    function getDeferredClaimHead() external view returns (ICfdEngine.DeferredClaim memory claim) {
        return deferredClaims[deferredClaimHeadId];
    }

    function getPositionSide(
        bytes32 accountId
    ) external view returns (CfdTypes.Side) {
        return _positions[accountId].side;
    }

    /// @notice Returns the maintenance margin requirement in USDC (6 decimals).
    ///         Uses fadMarginBps during the FAD window, maintMarginBps otherwise.
    /// @param size Position size in tokens (18 decimals)
    /// @param currentOraclePrice Oracle price (8 decimals)
    function getMaintenanceMarginUsdc(
        uint256 size,
        uint256 currentOraclePrice
    ) public view returns (uint256) {
        uint256 notionalUsdc = (size * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 requiredBps = isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps;
        return (notionalUsdc * requiredBps) / 10_000;
    }

    /// @notice Liquidates an undercollateralized position.
    ///         Surplus equity (after bounty) is returned to the user.
    ///         In bad-debt cases (equity < bounty), all remaining margin is seized by the vault.
    /// @param accountId Clearinghouse account that owns the position
    /// @param currentOraclePrice Pyth oracle price (8 decimals), clamped to CAP_PRICE
    /// @param vaultDepthUsdc HousePool total assets — used to scale funding rate
    /// @param publishTime Pyth publish timestamp, stored as lastMarkTime
    /// @return keeperBountyUsdc Bounty paid to the liquidation keeper (USDC, 6 decimals)
    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external onlyRouter nonReentrant returns (uint256 keeperBountyUsdc) {
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }
        if (_positions[accountId].size == 0) {
            revert CfdEngine__NoPositionToLiquidate();
        }

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(accountId, currentOraclePrice, vaultDepthUsdc, publishTime);
        snap.vaultCashUsdc = vault.totalAssets();
        CfdEnginePlanTypes.LiquidationDelta memory delta =
            planner.planLiquidation(snap, currentOraclePrice, publishTime);

        if (!delta.liquidatable) {
            revert CfdEngine__PositionIsSolvent();
        }

        return _applyLiquidation(delta);
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
        return WithdrawalAccountingLib.buildWithdrawalState(
            vault.totalAssets(),
            _maxLiability(),
            accumulatedFeesUsdc,
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc
        )
        .reservedUsdc;
    }

    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        return SolvencyAccountingLib.buildSolvencyState(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            _maxLiability(),
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc
        );
    }

    function _buildAdjustedSolvencySnapshot()
        internal
        view
        returns (CfdEngineSnapshotsLib.SolvencySnapshot memory snapshot)
    {
        SolvencyAccountingLib.SolvencyState memory state = _buildAdjustedSolvencyState();
        snapshot.physicalAssets = state.physicalAssetsUsdc;
        snapshot.protocolFees = state.protocolFeesUsdc;
        snapshot.netPhysicalAssets = state.netPhysicalAssetsUsdc;
        snapshot.maxLiability = state.maxLiabilityUsdc;
        snapshot.solvencyFunding = 0;
        snapshot.effectiveSolvencyAssets = state.effectiveAssetsUsdc;
    }

    // ==========================================
    // PLAN-APPLY: RAW SNAPSHOT BUILDER
    // ==========================================

    function _buildRawSnapshot(
        bytes32 accountId,
        uint256,
        uint256 vaultDepthUsdc,
        uint64
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap.accountId = accountId;
        snap.position = _loadPosition(accountId);

        snap.currentTimestamp = block.timestamp;
        snap.lastMarkPrice = lastMarkPrice;
        snap.lastMarkTime = lastMarkTime;

        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        snap.bullSide = _copySideSnapshot(bullState);
        snap.bearSide = _copySideSnapshot(bearState);

        snap.vaultAssetsUsdc = vaultDepthUsdc;
        snap.vaultCashUsdc = vaultDepthUsdc;

        snap.accountBuckets = clearinghouse.getAccountUsdcBuckets(accountId);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        snap.position.margin = snap.lockedBuckets.positionMarginUsdc;

        snap.accumulatedFeesUsdc = accumulatedFeesUsdc;
        snap.accumulatedBadDebtUsdc = accumulatedBadDebtUsdc;
        snap.totalDeferredPayoutUsdc = totalDeferredPayoutUsdc;
        snap.totalDeferredClearerBountyUsdc = totalDeferredClearerBountyUsdc;
        snap.deferredPayoutForAccount = deferredPayoutUsdc[accountId];
        snap.degradedMode = degradedMode;

        snap.capPrice = CAP_PRICE;
        snap.riskParams = riskParams;
        snap.isFadWindow = isFadWindow();
    }

    function _copySideSnapshot(
        SideState storage state
    ) internal view returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        snap.maxProfitUsdc = state.maxProfitUsdc;
        snap.openInterest = state.openInterest;
        snap.entryNotional = state.entryNotional;
        snap.totalMargin = state.totalMargin;
    }

    function _buildProjectedPositionRiskState(
        bytes32 accountId,
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 reachableUsdc,
        uint256 riskBps
    ) internal view returns (PositionRiskAccountingLib.PositionRiskState memory riskState) {
        accountId;
        riskState = PositionRiskAccountingLib.buildPositionRiskState(pos, price, CAP_PRICE, reachableUsdc, riskBps);
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

    function _revertIfOpenInvalid(
        CfdEnginePlanTypes.OpenRevertCode code
    ) internal pure {
        if (code == CfdEnginePlanTypes.OpenRevertCode.OK) {
            return;
        }
        if (code == CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING) {
            revert CfdEngine__MustCloseOpposingPosition();
        }
        if (code == CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE) {
            revert CfdEngine__DegradedMode();
        }
        if (code == CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL) {
            revert CfdEngine__PositionTooSmall();
        }
        if (code == CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH) {
            revert CfdEngine__SkewTooHigh();
        }
        if (code == CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES) {
            revert CfdEngine__MarginDrainedByFees();
        }
        if (code == CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN) {
            revert CfdEngine__InsufficientInitialMargin();
        }
        if (code == CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED) {
            revert CfdEngine__VaultSolvencyExceeded();
        }
    }

    function _revertIfOpenInvalidTyped(
        CfdEnginePlanTypes.OpenRevertCode code
    ) internal view {
        if (code == CfdEnginePlanTypes.OpenRevertCode.OK) {
            return;
        }

        revert ICfdEngine.CfdEngine__TypedOrderFailure(
            planner.getExecutionFailurePolicyCategory(code), uint8(code), false
        );
    }

    function _revertIfCloseInvalid(
        CfdEnginePlanTypes.CloseRevertCode code
    ) internal pure {
        if (code == CfdEnginePlanTypes.CloseRevertCode.OK) {
            return;
        }
        if (code == CfdEnginePlanTypes.CloseRevertCode.CLOSE_SIZE_EXCEEDS) {
            revert CfdEngine__CloseSizeExceedsPosition();
        }
        if (code == CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION) {
            revert CfdEngine__DustPosition();
        }
        if (code == CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNDERWATER) {
            revert CfdEngine__PartialCloseUnderwaterFunding();
        }
    }

    function _revertIfCloseInvalidTyped(
        CfdEnginePlanTypes.CloseRevertCode code
    ) internal view {
        if (code == CfdEnginePlanTypes.CloseRevertCode.OK) {
            return;
        }

        revert ICfdEngine.CfdEngine__TypedOrderFailure(
            planner.getCloseExecutionFailurePolicyCategory(code), uint8(code), true
        );
    }

    function _applyFundingAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) internal {
        lastMarkPrice = newMarkPrice;
        lastMarkTime = newMarkTime;
    }

    function _applyOpen(
        CfdEnginePlanTypes.OpenDelta memory delta
    ) internal {
        StoredPosition storage pos = _positions[delta.accountId];
        CfdTypes.Side marginSide = pos.size > 0 ? pos.side : delta.posSide;
        _applyFundingAndMark(delta.price, uint64(block.timestamp));
        uint256 marginBefore = _positionMarginBucketUsdc(delta.accountId);

        SideState storage sideState = _sideState(delta.posSide);
        sideState.maxProfitUsdc += delta.sideMaxProfitIncrease;
        sideState.openInterest += delta.sideOiIncrease;

        pos.maxProfitUsdc += delta.posMaxProfitIncrease;
        if (pos.size == 0) {
            pos.side = delta.posSide;
        }
        pos.entryPrice = delta.newPosEntryPrice;
        pos.size = delta.newPosSize;
        pos.vpiAccrued += delta.posVpiAccruedDelta;

        if (delta.sideEntryNotionalDelta >= 0) {
            sideState.entryNotional += uint256(delta.sideEntryNotionalDelta);
        } else {
            sideState.entryNotional -= uint256(-delta.sideEntryNotionalDelta);
        }

        if (delta.vaultRebatePayoutUsdc > 0) {
            vault.payOut(address(clearinghouse), delta.vaultRebatePayoutUsdc);
        }

        int256 netMarginChange =
            clearinghouse.applyOpenCost(delta.accountId, delta.marginDeltaUsdc, delta.tradeCostUsdc, address(vault));
        if (delta.tradeCostUsdc > 0) {
            uint256 protocolFeeInflowUsdc = uint256(delta.tradeCostUsdc) > delta.executionFeeUsdc
                ? delta.executionFeeUsdc
                : uint256(delta.tradeCostUsdc);
            _accountVaultCashInflow(
                VaultCashInflow({
                    physicalCashReceivedUsdc: uint256(delta.tradeCostUsdc),
                    protocolOwnedUsdc: protocolFeeInflowUsdc,
                    lpOwnedUsdc: uint256(delta.tradeCostUsdc) - protocolFeeInflowUsdc
                })
            );
        }

        uint256 marginAfterOpen =
            netMarginChange >= 0 ? marginBefore + uint256(netMarginChange) : marginBefore - uint256(-netMarginChange);
        _syncTotalSideMargin(marginSide, marginBefore, marginAfterOpen);

        accumulatedFeesUsdc += delta.executionFeeUsdc;
        pos.lastUpdateTime = uint64(block.timestamp);
        _assertPostSolvency();

        emit PositionOpened(delta.accountId, delta.posSide, delta.sizeDelta, delta.price, delta.marginDeltaUsdc);
    }

    function _applyClose(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) internal {
        StoredPosition storage pos = _positions[delta.accountId];
        CfdTypes.Side marginSide = pos.side;
        _applyFundingAndMark(delta.price, uint64(block.timestamp));
        uint256 marginBefore = _positionMarginBucketUsdc(delta.accountId);
        _syncTotalSideMargin(marginSide, marginBefore, delta.posMarginAfter);
        pos.maxProfitUsdc -= delta.posMaxProfitReduction;

        SideState storage sideState = _sideState(marginSide);
        sideState.maxProfitUsdc -= delta.sideMaxProfitReduction;
        sideState.openInterest -= delta.sideOiDecrease;
        sideState.entryNotional -= delta.sideEntryNotionalReduction;

        pos.size -= delta.posSizeDelta;
        pos.vpiAccrued -= delta.posVpiAccruedReduction;

        clearinghouse.unlockPositionMargin(delta.accountId, delta.unlockMarginUsdc);

        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.GAIN) {
            _payOrRecordDeferredTraderPayout(delta.accountId, delta.freshTraderPayoutUsdc);
        } else if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            uint64[] memory reservationOrderIds =
                IOrderRouterAccounting(orderRouter).getMarginReservationIds(delta.accountId);
            (uint256 seizedUsdc,) = clearinghouse.consumeCloseLoss(
                delta.accountId,
                reservationOrderIds,
                uint256(-delta.closeState.netSettlementUsdc),
                delta.posMarginAfter,
                delta.deletePosition,
                address(vault)
            );
            uint256 cashCollectedExecutionFeeUsdc = delta.executionFeeUsdc > delta.deferredFeeRecoveryUsdc
                ? delta.executionFeeUsdc - delta.deferredFeeRecoveryUsdc
                : 0;
            uint256 protocolFeeInflowUsdc =
                seizedUsdc > cashCollectedExecutionFeeUsdc ? cashCollectedExecutionFeeUsdc : seizedUsdc;
            _accountVaultCashInflow(
                VaultCashInflow({
                    physicalCashReceivedUsdc: seizedUsdc,
                    protocolOwnedUsdc: protocolFeeInflowUsdc,
                    lpOwnedUsdc: seizedUsdc - protocolFeeInflowUsdc
                })
            );
            _syncMarginQueue(delta.accountId, delta.syncMarginQueueAmount);
            if (delta.existingDeferredConsumedUsdc > 0) {
                _consumeDeferredTraderPayout(delta.accountId, delta.existingDeferredConsumedUsdc);
            }
            accumulatedBadDebtUsdc += delta.badDebtUsdc;
        }

        accumulatedFeesUsdc += delta.executionFeeUsdc;

        emit PositionClosed(delta.accountId, marginSide, delta.sizeDelta, delta.price, delta.realizedPnlUsdc);

        if (delta.deletePosition) {
            delete _positions[delta.accountId];
        } else {
            pos.lastUpdateTime = uint64(block.timestamp);
        }

        _enterDegradedModeIfInsolvent(delta.accountId, 0);
    }

    function _applyLiquidation(
        CfdEnginePlanTypes.LiquidationDelta memory delta
    ) internal returns (uint256 keeperBountyUsdc) {
        _applyFundingAndMark(delta.price, uint64(block.timestamp));

        SideState storage sideState = _sideState(delta.side);
        sideState.maxProfitUsdc -= delta.sideMaxProfitDecrease;
        sideState.openInterest -= delta.sideOiDecrease;
        sideState.entryNotional -= delta.sideEntryNotionalReduction;

        keeperBountyUsdc = delta.keeperBountyUsdc;
        uint64[] memory reservationOrderIds =
            IOrderRouterAccounting(orderRouter).getMarginReservationIds(delta.accountId);
        IMarginClearinghouse.LiquidationSettlementPlan memory plan = IMarginClearinghouse.LiquidationSettlementPlan({
            settlementRetainedUsdc: delta.settlementRetainedUsdc,
            settlementSeizedUsdc: delta.residualPlan.settlementSeizedUsdc,
            freshTraderPayoutUsdc: delta.freshTraderPayoutUsdc,
            badDebtUsdc: delta.badDebtUsdc,
            positionMarginUnlockedUsdc: delta.residualPlan.mutation.positionMarginUnlockedUsdc,
            otherLockedMarginUnlockedUsdc: delta.residualPlan.mutation.otherLockedMarginUnlockedUsdc
        });
        uint256 seizedUsdc =
            clearinghouse.applyLiquidationSettlementPlan(delta.accountId, reservationOrderIds, plan, address(vault));
        uint256 keeperBountyInflowUsdc = seizedUsdc > delta.keeperBountyUsdc ? delta.keeperBountyUsdc : seizedUsdc;
        _accountVaultCashInflow(
            VaultCashInflow({
                physicalCashReceivedUsdc: seizedUsdc,
                protocolOwnedUsdc: keeperBountyInflowUsdc,
                lpOwnedUsdc: seizedUsdc - keeperBountyInflowUsdc
            })
        );
        _syncMarginQueue(delta.accountId, delta.syncMarginQueueAmount);
        if (delta.existingDeferredConsumedUsdc > 0) {
            _consumeDeferredTraderPayout(delta.accountId, delta.existingDeferredConsumedUsdc);
        }
        if (delta.freshTraderPayoutUsdc > 0) {
            _payOrRecordDeferredTraderPayout(delta.accountId, delta.freshTraderPayoutUsdc);
        }
        accumulatedBadDebtUsdc += delta.badDebtUsdc;

        sideState.totalMargin -= delta.posMargin;

        emit PositionLiquidated(delta.accountId, delta.side, delta.posSize, delta.price, keeperBountyUsdc);
        delete _positions[delta.accountId];
        _enterDegradedModeIfInsolvent(delta.accountId, keeperBountyUsdc);
    }

    function _enterDegradedModeIfInsolvent(
        bytes32 accountId,
        uint256 pendingVaultPayoutUsdc
    ) internal {
        if (degradedMode) {
            return;
        }
        SolvencyAccountingLib.SolvencyState memory state = _buildAdjustedSolvencyState();
        uint256 effectiveAssetsAfter =
            SolvencyAccountingLib.effectiveAssetsAfterPendingPayout(state, pendingVaultPayoutUsdc);
        if (effectiveAssetsAfter < state.maxLiabilityUsdc) {
            degradedMode = true;
            emit DegradedModeEntered(effectiveAssetsAfter, state.maxLiabilityUsdc, accountId);
        }
    }

    function _physicalReachableCollateralUsdc(
        bytes32 accountId
    ) internal view returns (uint256) {
        return clearinghouse.getTerminalReachableUsdc(accountId);
    }

    function _positionMarginBucketUsdc(
        bytes32 accountId
    ) internal view returns (uint256) {
        return clearinghouse.getLockedMarginBuckets(accountId).positionMarginUsdc;
    }

    function _loadPosition(
        bytes32 accountId
    ) internal view returns (CfdTypes.Position memory pos) {
        StoredPosition storage stored = _positions[accountId];
        pos.size = stored.size;
        pos.margin = _positionMarginBucketUsdc(accountId);
        pos.entryPrice = stored.entryPrice;
        pos.maxProfitUsdc = stored.maxProfitUsdc;
        pos.side = stored.side;
        pos.lastUpdateTime = stored.lastUpdateTime;
        pos.vpiAccrued = stored.vpiAccrued;
    }

    function _liveMarkStalenessLimit() internal view returns (uint256) {
        return isOracleFrozen() ? fadMaxStaleness : engineMarkStalenessLimit;
    }

    function _consumeDeferredTraderPayout(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        deferredPayoutUsdc[accountId] -= amountUsdc;
        totalDeferredPayoutUsdc -= amountUsdc;

        uint64 claimId = traderDeferredClaimIdByAccount[accountId];
        if (claimId == 0) {
            revert CfdEngine__DeferredClaimNotAtHead();
        }

        ICfdEngine.DeferredClaim storage claim = deferredClaims[claimId];
        if (claim.remainingUsdc < amountUsdc) {
            revert CfdEngine__DeferredClaimNotAtHead();
        }

        claim.remainingUsdc -= amountUsdc;
        if (claim.remainingUsdc == 0) {
            _unlinkDeferredClaim(claimId);
        }
    }

    function _validateRiskParams(
        CfdTypes.RiskParams memory _riskParams
    ) internal pure {
        if (_riskParams.maintMarginBps == 0 || _riskParams.initMarginBps < _riskParams.maintMarginBps) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.fadMarginBps < _riskParams.maintMarginBps) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.initMarginBps > 10_000 || _riskParams.fadMarginBps > 10_000) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.minBountyUsdc == 0 || _riskParams.bountyBps == 0) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.maxSkewRatio > CfdMath.WAD) {
            revert CfdEngine__InvalidRiskParams();
        }
    }

    /// @notice Returns the protocol's worst-case directional liability.
    function getMaxLiability() external view returns (uint256) {
        return _maxLiability();
    }

    /// @notice Returns the total USDC reserve required for withdrawals.
    function getWithdrawalReservedUsdc() external view returns (uint256) {
        return _getWithdrawalReservedUsdc();
    }

    /// @notice Updates the cached mark price without settling funding or processing trades
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
        lastMarkPrice = clamped;
        lastMarkTime = publishTime;
    }

    /// @notice Returns true when the protocol still has live bounded directional liability.
    function hasLiveLiability() external view returns (bool) {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        return bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
    }

    // ==========================================
    // MARK-TO-MARKET
    // ==========================================

    /// @notice Aggregate unrealized PnL of all open positions at lastMarkPrice.
    ///         Positive = traders winning (house liability). Negative = traders losing (house asset).
    /// @return Net trader PnL in USDC (6 decimals), sign from the traders' perspective
    function getUnrealizedTraderPnl() external view returns (int256) {
        uint256 price = lastMarkPrice;
        if (price == 0) {
            return 0;
        }

        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        int256 bullPnl = int256(bullState.entryNotional) - int256(bullState.openInterest * price);
        int256 bearPnl = int256(bearState.openInterest * price) - int256(bearState.entryNotional);

        return (bullPnl + bearPnl) / int256(CfdMath.USDC_TO_TOKEN_SCALE);
    }

    function _getVaultMtmLiability() internal view returns (uint256) {
        uint256 price = lastMarkPrice;

        int256 bullPnl;
        int256 bearPnl;
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        if (price > 0) {
            bullPnl = (int256(bullState.entryNotional) - int256(bullState.openInterest * price))
                / int256(CfdMath.USDC_TO_TOKEN_SCALE);
            bearPnl = (int256(bearState.openInterest * price) - int256(bearState.entryNotional))
                / int256(CfdMath.USDC_TO_TOKEN_SCALE);
        }

        int256 bullTotal = bullPnl;
        int256 bearTotal = bearPnl;

        if (bullTotal < 0) {
            bullTotal = 0;
        }
        if (bearTotal < 0) {
            bearTotal = 0;
        }

        return uint256(bullTotal) + uint256(bearTotal);
    }

    function _getProtocolPhase() internal view returns (ICfdEngine.ProtocolPhase) {
        if (address(vault) == address(0) || orderRouter == address(0)) {
            return ICfdEngine.ProtocolPhase.Configuring;
        }
        if (degradedMode) {
            return ICfdEngine.ProtocolPhase.Degraded;
        }
        if (!vault.canIncreaseRisk()) {
            return ICfdEngine.ProtocolPhase.Configuring;
        }
        return ICfdEngine.ProtocolPhase.Active;
    }

    function getProtocolPhase() external view returns (ICfdEngine.ProtocolPhase) {
        return _getProtocolPhase();
    }

}
