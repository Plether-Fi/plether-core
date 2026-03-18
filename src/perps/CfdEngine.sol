// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
import {CfdEnginePlanLib} from "./libraries/CfdEnginePlanLib.sol";
import {CfdEngineSettlementLib} from "./libraries/CfdEngineSettlementLib.sol";
import {CfdEngineSnapshotsLib} from "./libraries/CfdEngineSnapshotsLib.sol";
import {CloseAccountingLib} from "./libraries/CloseAccountingLib.sol";
import {LiquidationAccountingLib} from "./libraries/LiquidationAccountingLib.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {MarketCalendarLib} from "./libraries/MarketCalendarLib.sol";
import {OpenAccountingLib} from "./libraries/OpenAccountingLib.sol";
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
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
        // Current UI helper only; this does not include terminally reachable queued committed margin.
        uint256 closeReachableUsdc;
        uint256 liquidationReachableUsdc;
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
        int256 liabilityOnlyFundingPnlUsdc;
        uint256 totalDeferredPayoutUsdc;
        uint256 totalDeferredClearerBountyUsdc;
        bool degradedMode;
        bool hasLiveLiability;
    }

    struct ClosePreview {
        bool valid;
        uint8 invalidCode;
        uint256 executionPrice;
        uint256 sizeDelta;
        int256 realizedPnlUsdc;
        int256 fundingUsdc;
        int256 vpiDeltaUsdc;
        uint256 vpiUsdc;
        uint256 executionFeeUsdc;
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
        uint256 immediatePayoutUsdc;
        uint256 deferredPayoutUsdc;
        uint256 badDebtUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct DeferredPayoutStatus {
        uint256 deferredTraderPayoutUsdc;
        bool traderPayoutClaimableNow;
        uint256 deferredClearerBountyUsdc;
        bool liquidationBountyClaimableNow;
    }

    struct LiquidationComputation {
        uint256 reachableCollateralUsdc;
        PositionRiskAccountingLib.PositionRiskState riskState;
        LiquidationAccountingLib.LiquidationState liquidationState;
        CfdEngineSettlementLib.LiquidationSettlementResult settlement;
    }

    struct CloseExecutionPlan {
        CloseAccountingLib.CloseState closeState;
        uint256 postBullOi;
        uint256 postBearOi;
    }

    struct PreviewFundingSettlement {
        int256 pendingFundingUsdc;
        int256 closeFundingSettlementUsdc;
        uint256 settlementBalanceAfterFundingUsdc;
        uint256 positionMarginAfterFundingUsdc;
        uint256 selectedSideTotalMarginAfterFundingUsdc;
        int256 selectedSideEntryFundingAfterFunding;
        uint256 fundingVaultCashOutflowUsdc;
        uint256 fundingVaultCashInflowUsdc;
    }

    struct SideState {
        uint256 maxProfitUsdc;
        uint256 openInterest;
        uint256 entryNotional;
        uint256 totalMargin;
        int256 fundingIndex;
        int256 entryFunding;
    }

    uint256 public immutable CAP_PRICE;

    IERC20 public immutable USDC;
    IMarginClearinghouse public immutable clearinghouse;
    ICfdVault public vault;

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
    mapping(bytes32 => CfdTypes.Position) public positions;
    mapping(bytes32 => uint256) public deferredPayoutUsdc;
    uint256 public totalDeferredPayoutUsdc;
    mapping(address => uint256) public deferredClearerBountyUsdc;
    uint256 public totalDeferredClearerBountyUsdc;

    address public orderRouter;

    mapping(uint256 => bool) public fadDayOverrides;
    uint256 public fadMaxStaleness = 3 days;
    uint256 public fadRunwaySeconds = 3 hours;

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

    error CfdEngine__Unauthorized();
    error CfdEngine__VaultAlreadySet();
    error CfdEngine__RouterAlreadySet();
    error CfdEngine__NoFeesToWithdraw();
    error CfdEngine__NoDeferredPayout();
    error CfdEngine__InsufficientVaultLiquidity();
    error CfdEngine__NoDeferredClearerBounty();
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
        _syncFunding();
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

    /// @notice Withdraws accumulated execution fees from the vault to a recipient
    function withdrawFees(
        address recipient
    ) external onlyOwner {
        _syncFunding();
        uint256 fees = accumulatedFeesUsdc;
        if (fees == 0) {
            revert CfdEngine__NoFeesToWithdraw();
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

        CfdTypes.Position storage pos = positions[accountId];
        if (pos.size == 0) {
            revert CfdEngine__NoOpenPosition();
        }

        clearinghouse.lockPositionMargin(accountId, amount);
        pos.margin += amount;
        _sideState(pos.side).totalMargin += amount;
        pos.lastUpdateTime = uint64(block.timestamp);
        _assertPostSolvency();

        emit MarginAdded(accountId, amount);
    }

    /// @notice Claims a previously deferred profitable close payout into the clearinghouse.
    /// @dev The payout remains subject to current vault cash availability. Funds are credited to the
    ///      clearinghouse first, so traders access them through the normal account-balance path.
    function claimDeferredPayout(
        bytes32 accountId
    ) external nonReentrant {
        _syncFunding();
        if (bytes32(uint256(uint160(msg.sender))) != accountId) {
            revert CfdEngine__NotAccountOwner();
        }

        uint256 amount = deferredPayoutUsdc[accountId];
        if (amount == 0) {
            revert CfdEngine__NoDeferredPayout();
        }
        if (vault.totalAssets() < amount) {
            revert CfdEngine__InsufficientVaultLiquidity();
        }

        deferredPayoutUsdc[accountId] = 0;
        totalDeferredPayoutUsdc -= amount;
        vault.payOut(address(clearinghouse), amount);
        clearinghouse.settleUsdc(accountId, int256(amount));

        emit DeferredPayoutClaimed(accountId, amount);
    }

    /// @notice Claims a previously deferred clearer bounty when the vault has replenished cash.
    function claimDeferredClearerBounty() external nonReentrant {
        _syncFunding();
        uint256 amount = deferredClearerBountyUsdc[msg.sender];
        if (amount == 0) {
            revert CfdEngine__NoDeferredClearerBounty();
        }
        if (vault.totalAssets() < amount) {
            revert CfdEngine__InsufficientVaultLiquidity();
        }

        deferredClearerBountyUsdc[msg.sender] = 0;
        totalDeferredClearerBountyUsdc -= amount;
        vault.payOut(msg.sender, amount);

        emit DeferredClearerBountyClaimed(msg.sender, amount);
    }

    /// @notice Records a liquidation bounty that could not be paid immediately because vault cash was unavailable.
    function recordDeferredClearerBounty(
        address keeper,
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }
        deferredClearerBountyUsdc[keeper] += amountUsdc;
        totalDeferredClearerBountyUsdc += amountUsdc;
        emit DeferredClearerBountyRecorded(keeper, amountUsdc);
    }

    /// @notice Reduces accumulated bad debt after governance-confirmed recapitalization
    /// @param amount USDC amount of bad debt to clear (6 decimals)
    function clearBadDebt(
        uint256 amount
    ) external onlyOwner {
        _syncFunding();
        uint256 badDebt = accumulatedBadDebtUsdc;
        if (amount > badDebt) {
            revert CfdEngine__BadDebtTooLarge();
        }
        if (amount > 0) {
            USDC.safeTransferFrom(msg.sender, address(vault), amount);
        }
        accumulatedBadDebtUsdc = badDebt - amount;
        emit BadDebtCleared(amount, accumulatedBadDebtUsdc);
    }

    function clearDegradedMode() external onlyOwner {
        _syncFunding();
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
        CfdTypes.Position memory pos = positions[accountId];
        if (pos.size == 0) {
            return;
        }
        if (degradedMode) {
            revert CfdEngine__DegradedMode();
        }

        uint256 price = lastMarkPrice;
        if (price == 0) {
            return;
        }

        uint256 maxStaleness = isOracleFrozen() ? fadMaxStaleness : 30;
        uint256 age = block.timestamp > lastMarkTime ? block.timestamp - lastMarkTime : 0;
        if (age > maxStaleness) {
            revert CfdEngine__MarkPriceStale();
        }

        uint256 reachableUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);
        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildPositionRiskState(
            pos,
            price,
            CAP_PRICE,
            getPendingFunding(pos),
            reachableUsdc,
            isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps
        );

        if (riskState.equityUsdc < int256(riskState.maintenanceMarginUsdc)) {
            revert CfdEngine__WithdrawBlockedByOpenPosition();
        }
    }

    // ==========================================
    // 1. CONTINUOUS FUNDING SYSTEM
    // ==========================================

    /// @notice Materializes accrued funding into storage so subsequent reads reflect current state.
    ///         O(1) gas, idempotent (no-op if called twice in the same block).
    function syncFunding() external {
        _syncFunding();
    }

    /// @dev Canonical internal funding sync. Every function that changes vault cash or reads
    ///      funding-dependent state must call this first. Using a dedicated helper instead of
    ///      inline `_updateFunding(lastMarkPrice, vault.totalAssets())` ensures new call sites
    ///      cannot silently skip the sync.
    function _syncFunding() internal {
        _updateFunding(lastMarkPrice, vault.totalAssets());
    }

    function _updateFunding(
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) internal {
        if (block.timestamp <= lastFundingTime) {
            return;
        }
        uint256 timeDelta = block.timestamp - lastFundingTime;

        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        PositionRiskAccountingLib.FundingStepResult memory step = PositionRiskAccountingLib.computeFundingStep(
            PositionRiskAccountingLib.FundingStepInputs({
                price: currentOraclePrice,
                bullOi: bullState.openInterest,
                bearOi: bearState.openInterest,
                timeDelta: timeDelta,
                vaultDepthUsdc: vaultDepthUsdc,
                riskParams: riskParams
            })
        );
        bullState.fundingIndex += step.bullFundingIndexDelta;
        bearState.fundingIndex += step.bearFundingIndexDelta;

        lastFundingTime = uint64(block.timestamp);
        emit FundingUpdated(bullState.fundingIndex, bearState.fundingIndex, step.absSkewUsdc);
    }

    /// @notice Returns unsettled funding owed to (+) or by (-) a position in USDC (6 decimals)
    /// @param pos The position to compute pending funding for
    /// @return fundingUsdc Positive if the position is owed funding, negative if it owes
    function getPendingFunding(
        CfdTypes.Position memory pos
    ) public view returns (int256 fundingUsdc) {
        if (pos.size == 0) {
            return 0;
        }
        int256 currentIndex = _sideState(pos.side).fundingIndex;
        fundingUsdc = PositionRiskAccountingLib.getPendingFunding(pos, currentIndex);
    }

    // ==========================================
    // 2. ORDER PROCESSING & NETTING
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
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(order.accountId, currentOraclePrice, vaultDepthUsdc, publishTime);
        snap.vaultCashUsdc = vault.totalAssets();

        if (order.isClose) {
            CfdEnginePlanTypes.CloseDelta memory delta =
                CfdEnginePlanLib.planClose(snap, order, currentOraclePrice, publishTime);
            _revertIfCloseInvalid(delta.revertCode);
            _applyClose(delta);
        } else {
            CfdEnginePlanTypes.OpenDelta memory delta =
                CfdEnginePlanLib.planOpen(snap, order, currentOraclePrice, publishTime);
            _revertIfOpenInvalid(delta.revertCode);
            _applyOpen(delta);
        }
    }

    // ==========================================
    // 3. INTERNAL LEDGER UPDATES
    // ==========================================

    function _settleFunding(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos
    ) internal returns (int256 closeFundingSettlementUsdc) {
        int256 pendingFunding = getPendingFunding(pos);
        if (pos.size > 0 && pendingFunding != 0) {
            if (pendingFunding > 0) {
                uint256 gain = uint256(pendingFunding);
                if (order.isClose && order.sizeDelta == pos.size) {
                    closeFundingSettlementUsdc = int256(gain);
                } else if (vault.totalAssets() >= gain) {
                    pos.margin += gain;
                    vault.payOut(address(clearinghouse), gain);
                    clearinghouse.creditSettlementAndLockMargin(order.accountId, gain);
                } else {
                    _payOrRecordDeferredTraderPayout(order.accountId, gain);
                }
            } else {
                uint256 loss = uint256(-pendingFunding);
                (uint256 marginConsumedUsdc,, uint256 uncoveredUsdc) =
                    clearinghouse.consumeFundingLoss(order.accountId, pos.margin, loss, address(vault));
                pos.margin -= marginConsumedUsdc;

                if (uncoveredUsdc > 0) {
                    if (!order.isClose) {
                        revert CfdEngine__FundingExceedsMargin();
                    }
                    if (order.sizeDelta < pos.size) {
                        revert CfdEngine__PartialCloseUnderwaterFunding();
                    }
                    closeFundingSettlementUsdc = -int256(uncoveredUsdc);
                }
            }
        }
        if (pos.size > 0) {
            SideState storage sideState = _sideState(pos.side);
            int256 newIdx = sideState.fundingIndex;
            int256 fundingDelta = int256(pos.size) * (newIdx - pos.entryFundingIndex);
            sideState.entryFunding += fundingDelta;
            pos.entryFundingIndex = newIdx;
        }
    }

    function _processIncrease(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos,
        uint256 price,
        uint256 preSkewUsdc,
        uint256 vaultDepthUsdc
    ) internal {
        CfdTypes.RiskParams memory rp = riskParams;
        OpenAccountingLib.OpenState memory openState = OpenAccountingLib.buildOpenState(
            OpenAccountingLib.OpenInputs({
                currentSize: pos.size,
                currentEntryPrice: pos.entryPrice,
                side: order.side,
                sizeDelta: order.sizeDelta,
                price: price,
                capPrice: CAP_PRICE,
                preSkewUsdc: preSkewUsdc,
                postSkewUsdc: _getPostOpenSkewUsdc(order.side, order.sizeDelta, price),
                vaultDepthUsdc: vaultDepthUsdc,
                executionFeeBps: EXECUTION_FEE_BPS,
                currentFundingIndex: _sideState(order.side).fundingIndex,
                riskParams: rp
            })
        );

        if (openState.notionalUsdc * rp.bountyBps < rp.minBountyUsdc * 10_000) {
            revert CfdEngine__PositionTooSmall();
        }

        _addGlobalLiability(order.side, openState.addedMaxProfitUsdc, order.sizeDelta);
        if (vaultDepthUsdc > 0 && ((openState.postSkewUsdc * CfdMath.WAD) / vaultDepthUsdc) > rp.maxSkewRatio) {
            revert CfdEngine__SkewTooHigh();
        }
        pos.maxProfitUsdc += openState.addedMaxProfitUsdc;

        if (pos.size == 0) {
            pos.side = order.side;
            pos.entryFundingIndex = _sideState(order.side).fundingIndex;
        }
        pos.entryPrice = openState.newEntryPrice;
        pos.size = openState.newSize;
        pos.vpiAccrued += openState.vpiUsdc;

        SideState storage sideState = _sideState(order.side);
        if (openState.newEntryNotional >= openState.oldEntryNotional) {
            sideState.entryNotional += openState.newEntryNotional - openState.oldEntryNotional;
        } else {
            sideState.entryNotional -= openState.oldEntryNotional - openState.newEntryNotional;
        }
        sideState.entryFunding += openState.positionFundingContribution;

        if (openState.tradeCostUsdc < 0) {
            uint256 rebate = uint256(-openState.tradeCostUsdc);
            vault.payOut(address(clearinghouse), rebate);
        }

        int256 netMarginChange =
            clearinghouse.applyOpenCost(order.accountId, order.marginDelta, openState.tradeCostUsdc, address(vault));

        if (netMarginChange > 0) {
            pos.margin += uint256(netMarginChange);
        } else if (netMarginChange < 0) {
            uint256 deficit = uint256(-netMarginChange);
            if (pos.margin < deficit) {
                revert CfdEngine__MarginDrainedByFees();
            }
            pos.margin -= deficit;
        }

        accumulatedFeesUsdc += openState.executionFeeUsdc;

        if (
            OpenAccountingLib.effectiveMarginAfterTradeCost(pos.margin, openState.tradeCostUsdc)
                < openState.initialMarginRequirementUsdc
        ) {
            revert CfdEngine__InsufficientInitialMargin();
        }

        emit PositionOpened(order.accountId, order.side, order.sizeDelta, price, order.marginDelta);
    }

    function _processDecrease(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos,
        uint256 price,
        uint256 preSkewUsdc,
        uint256 vaultDepthUsdc,
        int256 fundingSettlementUsdc
    ) internal returns (uint256 collectedExecFeeUsdc) {
        if (pos.size < order.sizeDelta) {
            revert CfdEngine__CloseSizeExceedsPosition();
        }

        CfdTypes.Position memory positionAfterFunding = pos;
        CloseExecutionPlan memory closePlan = _buildCloseExecutionPlan(
            positionAfterFunding, order.sizeDelta, price, preSkewUsdc, vaultDepthUsdc, fundingSettlementUsdc
        );
        CloseAccountingLib.CloseState memory closeState = closePlan.closeState;

        pos.margin = closeState.remainingMarginUsdc;

        uint256 maxProfitReduction = closeState.maxProfitReductionUsdc;
        pos.maxProfitUsdc -= maxProfitReduction;
        _reduceGlobalLiability(pos.side, maxProfitReduction, order.sizeDelta);

        uint256 entryNotionalReduction = order.sizeDelta * pos.entryPrice;
        SideState storage sideState = _sideState(pos.side);
        sideState.entryNotional -= entryNotionalReduction;
        sideState.entryFunding -= int256(order.sizeDelta) * pos.entryFundingIndex;

        pos.size -= order.sizeDelta;
        if (pos.size > 0 && pos.margin < riskParams.minBountyUsdc) {
            revert CfdEngine__DustPosition();
        }

        clearinghouse.unlockPositionMargin(order.accountId, closeState.marginToFreeUsdc);
        pos.vpiAccrued -= closeState.proportionalAccrualUsdc;

        collectedExecFeeUsdc = _settleCloseNetSettlement(
            order.accountId, closeState.netSettlementUsdc, closeState.executionFeeUsdc, pos.margin
        );

        emit PositionClosed(order.accountId, pos.side, order.sizeDelta, price, closeState.realizedPnlUsdc);

        if (pos.size == 0) {
            delete positions[order.accountId];
        }
    }

    function _getAbsSkewUsdc(
        uint256 currentOraclePrice
    ) internal view returns (uint256) {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        uint256 bullUsdc = (bullState.openInterest * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bearState.openInterest * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        return bullUsdc > bearUsdc ? bullUsdc - bearUsdc : bearUsdc - bullUsdc;
    }

    function _getPostOpenSkewUsdc(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 price
    ) internal view returns (uint256) {
        (SideState storage selectedState, SideState storage oppositeState) = _sideAndOppositeStates(side);
        uint256 selectedOi = selectedState.openInterest + sizeDelta;
        uint256 oppositeOi = oppositeState.openInterest;
        uint256 postBullOi = side == CfdTypes.Side.BULL ? selectedOi : oppositeOi;
        uint256 postBearOi = side == CfdTypes.Side.BEAR ? selectedOi : oppositeOi;
        uint256 postBullUsdc = (postBullOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postBearUsdc = (postBearOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        return postBullUsdc > postBearUsdc ? postBullUsdc - postBearUsdc : postBearUsdc - postBullUsdc;
    }

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

    function _addGlobalLiability(
        CfdTypes.Side side,
        uint256 maxProfitUsdc,
        uint256 sizeDelta
    ) internal {
        SideState storage sideState = _sideState(side);
        sideState.maxProfitUsdc += maxProfitUsdc;
        sideState.openInterest += sizeDelta;
        uint256 maxLiability = _maxLiability();
        if (_buildAdjustedSolvencySnapshot().effectiveSolvencyAssets < maxLiability) {
            revert CfdEngine__VaultSolvencyExceeded();
        }
    }

    function _reduceGlobalLiability(
        CfdTypes.Side side,
        uint256 maxProfitUsdc,
        uint256 sizeDelta
    ) internal {
        SideState storage sideState = _sideState(side);
        sideState.maxProfitUsdc -= maxProfitUsdc;
        sideState.openInterest -= sizeDelta;
    }

    function _settleCloseNetSettlement(
        bytes32 accountId,
        int256 netSettlement,
        uint256 execFeeUsdc,
        uint256 remainingPosMarginUsdc
    ) internal returns (uint256 collectedExecFeeUsdc) {
        collectedExecFeeUsdc = execFeeUsdc;

        if (netSettlement > 0) {
            _payOrRecordDeferredTraderPayout(accountId, uint256(netSettlement));
            return collectedExecFeeUsdc;
        }

        if (netSettlement == 0) {
            return collectedExecFeeUsdc;
        }

        (
            CfdEngineSettlementLib.CloseSettlementResult memory plannedResult,
            MarginClearinghouseAccountingLib.SettlementConsumption memory plannedConsumption
        ) = _planLiveCloseLoss(accountId, uint256(-netSettlement), execFeeUsdc, remainingPosMarginUsdc);
        if (plannedResult.shortfallUsdc > 0 && remainingPosMarginUsdc > 0) {
            revert CfdEngine__PartialCloseUnderwaterFunding();
        }

        CfdEngineSettlementLib.CloseSettlementResult memory result;
        uint64[] memory reservationOrderIds = IOrderRouterAccounting(orderRouter).getMarginReservationIds(accountId);
        (result.seizedUsdc, result.shortfallUsdc) = clearinghouse.consumeCloseLoss(
            accountId, reservationOrderIds, uint256(-netSettlement), remainingPosMarginUsdc, address(vault)
        );

        result.collectedExecFeeUsdc = plannedResult.collectedExecFeeUsdc;
        result.badDebtUsdc = plannedResult.badDebtUsdc;
        _syncMarginQueue(accountId, plannedConsumption.otherLockedMarginConsumedUsdc);

        collectedExecFeeUsdc = result.collectedExecFeeUsdc;
        accumulatedBadDebtUsdc += result.badDebtUsdc;
    }

    function _planLiveCloseLoss(
        bytes32 accountId,
        uint256 lossUsdc,
        uint256 execFeeUsdc,
        uint256 remainingPosMarginUsdc
    )
        internal
        view
        returns (
            CfdEngineSettlementLib.CloseSettlementResult memory result,
            MarginClearinghouseAccountingLib.SettlementConsumption memory consumption
        )
    {
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = _buildCloseSettlementBuckets(
            clearinghouse.balanceUsdc(accountId),
            lockedBuckets.positionMarginUsdc,
            lockedBuckets.committedOrderMarginUsdc,
            lockedBuckets.reservedSettlementUsdc,
            remainingPosMarginUsdc
        );
        return _planCloseLossFromBuckets(buckets, lossUsdc, execFeeUsdc, remainingPosMarginUsdc);
    }

    function _planPreviewCloseLossSettlement(
        bytes32 accountId,
        uint256 lossUsdc,
        uint256 execFeeUsdc,
        uint256 remainingPosMarginUsdc,
        uint256 marginToFreeUsdc,
        PreviewFundingSettlement memory fundingSettlement
    )
        internal
        view
        returns (
            CfdEngineSettlementLib.CloseSettlementResult memory result,
            MarginClearinghouseAccountingLib.SettlementConsumption memory consumption
        )
    {
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        uint256 adjustedPosMargin = fundingSettlement.positionMarginAfterFundingUsdc > marginToFreeUsdc
            ? fundingSettlement.positionMarginAfterFundingUsdc - marginToFreeUsdc
            : 0;
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = _buildCloseSettlementBuckets(
            fundingSettlement.settlementBalanceAfterFundingUsdc,
            adjustedPosMargin,
            lockedBuckets.committedOrderMarginUsdc,
            lockedBuckets.reservedSettlementUsdc,
            remainingPosMarginUsdc
        );
        return _planCloseLossFromBuckets(buckets, lossUsdc, execFeeUsdc, remainingPosMarginUsdc);
    }

    function _planCloseLossFromBuckets(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 lossUsdc,
        uint256 execFeeUsdc,
        uint256 remainingPosMarginUsdc
    )
        internal
        pure
        returns (
            CfdEngineSettlementLib.CloseSettlementResult memory result,
            MarginClearinghouseAccountingLib.SettlementConsumption memory consumption
        )
    {
        consumption =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, remainingPosMarginUsdc, lossUsdc);
        result = CfdEngineSettlementLib.closeSettlementResult(consumption.totalConsumedUsdc, lossUsdc, execFeeUsdc);
    }

    function _buildCloseSettlementBuckets(
        uint256 settlementBalanceUsdc,
        uint256 positionMarginUsdc,
        uint256 committedOrderMarginUsdc,
        uint256 reservedSettlementUsdc,
        uint256 remainingPosMarginUsdc
    ) internal pure returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets = MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            settlementBalanceUsdc, positionMarginUsdc, committedOrderMarginUsdc, reservedSettlementUsdc
        );
    }

    function _settleLiquidationResidual(
        bytes32 accountId,
        uint256 positionMarginUsdc,
        int256 residualUsdc
    ) internal returns (CfdEngineSettlementLib.LiquidationSettlementResult memory result) {
        MarginClearinghouseAccountingLib.LiquidationResidualPlan memory plan =
            MarginClearinghouseAccountingLib.planLiquidationResidual(
                clearinghouse.getAccountUsdcBuckets(accountId), residualUsdc
            );
        uint64[] memory reservationOrderIds = IOrderRouterAccounting(orderRouter).getMarginReservationIds(accountId);
        (result.seizedUsdc, result.payoutUsdc, result.badDebtUsdc) = clearinghouse.consumeLiquidationResidual(
            accountId, reservationOrderIds, positionMarginUsdc, residualUsdc, address(vault)
        );
        _syncMarginQueue(accountId, plan.mutation.otherLockedMarginUnlockedUsdc);
        if (result.payoutUsdc > 0) {
            _payOrRecordDeferredTraderPayout(accountId, result.payoutUsdc);
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

        uint256 availableCash = vault.totalAssets();
        if (availableCash >= amountUsdc) {
            vault.payOut(address(clearinghouse), amountUsdc);
            clearinghouse.settleUsdc(accountId, int256(amountUsdc));
        } else {
            deferredPayoutUsdc[accountId] += amountUsdc;
            totalDeferredPayoutUsdc += amountUsdc;
            emit DeferredPayoutRecorded(accountId, amountUsdc);
        }
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
        return positions[accountId].size > 0;
    }

    function getPositionSize(
        bytes32 accountId
    ) external view returns (uint256) {
        return positions[accountId].size;
    }

    function getAccountCollateralView(
        bytes32 accountId
    ) external view returns (AccountCollateralView memory viewData) {
        CfdTypes.Position memory pos = positions[accountId];
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        viewData.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        viewData.lockedMarginUsdc = buckets.totalLockedMarginUsdc;
        viewData.activePositionMarginUsdc = buckets.activePositionMarginUsdc;
        viewData.otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;
        viewData.freeSettlementUsdc = buckets.freeSettlementUsdc;
        // This remains a free-settlement view helper, not the broader terminally reachable amount that
        // full-close settlement can consume after queued committed margin is released/consumed.
        viewData.closeReachableUsdc = clearinghouse.getFreeSettlementBalanceUsdc(accountId);
        viewData.liquidationReachableUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);
        viewData.accountEquityUsdc = clearinghouse.getAccountEquityUsdc(accountId);
        viewData.freeBuyingPowerUsdc = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        viewData.deferredPayoutUsdc = deferredPayoutUsdc[accountId];
    }

    function getAccountLedgerView(
        bytes32 accountId
    ) external view returns (ICfdEngine.AccountLedgerView memory viewData) {
        ICfdEngine.AccountLedgerSnapshot memory snapshot = _buildAccountLedgerSnapshot(accountId);
        viewData.settlementBalanceUsdc = snapshot.settlementBalanceUsdc;
        viewData.freeSettlementUsdc = snapshot.freeSettlementUsdc;
        viewData.activePositionMarginUsdc = snapshot.activePositionMarginUsdc;
        viewData.otherLockedMarginUsdc = snapshot.otherLockedMarginUsdc;
        viewData.executionEscrowUsdc = snapshot.executionEscrowUsdc;
        viewData.committedMarginUsdc = snapshot.committedMarginUsdc;
        viewData.deferredPayoutUsdc = snapshot.deferredPayoutUsdc;
        viewData.pendingOrderCount = snapshot.pendingOrderCount;
    }

    function getAccountLedgerSnapshot(
        bytes32 accountId
    ) external view returns (ICfdEngine.AccountLedgerSnapshot memory snapshot) {
        return _buildAccountLedgerSnapshot(accountId);
    }

    function _buildAccountLedgerSnapshot(
        bytes32 accountId
    ) internal view returns (ICfdEngine.AccountLedgerSnapshot memory snapshot) {
        CfdTypes.Position memory pos = positions[accountId];
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        IOrderRouterAccounting.AccountEscrowView memory escrow =
            IOrderRouterAccounting(orderRouter).getAccountEscrow(accountId);

        snapshot.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        snapshot.freeSettlementUsdc = buckets.freeSettlementUsdc;
        snapshot.activePositionMarginUsdc = buckets.activePositionMarginUsdc;
        snapshot.otherLockedMarginUsdc = buckets.otherLockedMarginUsdc;
        snapshot.positionMarginBucketUsdc = lockedBuckets.positionMarginUsdc;
        snapshot.committedOrderMarginBucketUsdc = lockedBuckets.committedOrderMarginUsdc;
        snapshot.reservedSettlementBucketUsdc = lockedBuckets.reservedSettlementUsdc;
        snapshot.executionEscrowUsdc = escrow.executionBountyUsdc;
        snapshot.committedMarginUsdc = escrow.committedMarginUsdc;
        snapshot.deferredPayoutUsdc = deferredPayoutUsdc[accountId];
        snapshot.pendingOrderCount = escrow.pendingOrderCount;
        snapshot.closeReachableUsdc = clearinghouse.getFreeSettlementBalanceUsdc(accountId);
        snapshot.liquidationReachableUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);
        snapshot.accountEquityUsdc = clearinghouse.getAccountEquityUsdc(accountId);
        snapshot.freeBuyingPowerUsdc = clearinghouse.getFreeBuyingPowerUsdc(accountId);

        if (pos.size == 0) {
            return snapshot;
        }

        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildPositionRiskState(
            pos,
            lastMarkPrice,
            CAP_PRICE,
            getPendingFunding(pos),
            snapshot.liquidationReachableUsdc,
            isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps
        );

        snapshot.hasPosition = true;
        snapshot.side = pos.side;
        snapshot.size = pos.size;
        snapshot.margin = pos.margin;
        snapshot.entryPrice = pos.entryPrice;
        snapshot.unrealizedPnlUsdc = riskState.unrealizedPnlUsdc;
        snapshot.pendingFundingUsdc = riskState.pendingFundingUsdc;
        snapshot.netEquityUsdc = riskState.equityUsdc;
        snapshot.liquidatable = riskState.liquidatable;
    }

    function getPositionView(
        bytes32 accountId
    ) external view returns (PositionView memory viewData) {
        CfdTypes.Position memory pos = positions[accountId];
        if (pos.size == 0) {
            return viewData;
        }

        uint256 reachableUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);
        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildPositionRiskState(
            pos,
            lastMarkPrice,
            CAP_PRICE,
            getPendingFunding(pos),
            reachableUsdc,
            isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps
        );

        viewData.exists = true;
        viewData.side = pos.side;
        viewData.size = pos.size;
        viewData.margin = pos.margin;
        viewData.entryPrice = pos.entryPrice;
        viewData.entryNotionalUsdc = (pos.size * pos.entryPrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        viewData.unrealizedPnlUsdc = riskState.unrealizedPnlUsdc;
        viewData.pendingFundingUsdc = riskState.pendingFundingUsdc;
        viewData.netEquityUsdc = riskState.equityUsdc;
        viewData.maxProfitUsdc = CfdMath.calculateMaxProfit(pos.size, pos.entryPrice, pos.side, CAP_PRICE);
        viewData.liquidatable = riskState.liquidatable;
    }

    function getProtocolAccountingView() external view returns (ProtocolAccountingView memory viewData) {
        ICfdEngine.ProtocolAccountingSnapshot memory snapshot = _buildProtocolAccountingSnapshot();
        viewData.vaultAssetsUsdc = snapshot.vaultAssetsUsdc;
        viewData.maxLiabilityUsdc = snapshot.maxLiabilityUsdc;
        viewData.withdrawalReservedUsdc = snapshot.withdrawalReservedUsdc;
        viewData.freeUsdc = snapshot.freeUsdc;
        viewData.accumulatedFeesUsdc = snapshot.accumulatedFeesUsdc;
        viewData.cappedFundingPnlUsdc = snapshot.cappedFundingPnlUsdc;
        viewData.liabilityOnlyFundingPnlUsdc = snapshot.liabilityOnlyFundingPnlUsdc;
        viewData.totalDeferredPayoutUsdc = snapshot.totalDeferredPayoutUsdc;
        viewData.totalDeferredClearerBountyUsdc = snapshot.totalDeferredClearerBountyUsdc;
        viewData.degradedMode = snapshot.degradedMode;
        viewData.hasLiveLiability = snapshot.hasLiveLiability;
    }

    function getProtocolAccountingSnapshot()
        external
        view
        returns (ICfdEngine.ProtocolAccountingSnapshot memory snapshot)
    {
        return _buildProtocolAccountingSnapshot();
    }

    function _buildProtocolAccountingSnapshot()
        internal
        view
        returns (ICfdEngine.ProtocolAccountingSnapshot memory snapshot)
    {
        uint256 vaultAssetsUsdc = vault.totalAssets();
        uint256 maxLiabilityUsdc = _maxLiability();
        WithdrawalAccountingLib.WithdrawalState memory withdrawalState = WithdrawalAccountingLib.buildWithdrawalState(
            vaultAssetsUsdc,
            maxLiabilityUsdc,
            accumulatedFeesUsdc,
            _getLiabilityOnlyFundingPnl(),
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc
        );
        SolvencyAccountingLib.SolvencyState memory solvencyState = _buildAdjustedSolvencyState();
        snapshot.vaultAssetsUsdc = vaultAssetsUsdc;
        snapshot.netPhysicalAssetsUsdc = solvencyState.netPhysicalAssetsUsdc;
        snapshot.maxLiabilityUsdc = maxLiabilityUsdc;
        snapshot.effectiveSolvencyAssetsUsdc = solvencyState.effectiveAssetsUsdc;
        snapshot.withdrawalReservedUsdc = withdrawalState.reservedUsdc;
        snapshot.freeUsdc = withdrawalState.freeUsdc;
        snapshot.accumulatedFeesUsdc = accumulatedFeesUsdc;
        snapshot.accumulatedBadDebtUsdc = accumulatedBadDebtUsdc;
        snapshot.cappedFundingPnlUsdc = solvencyState.solvencyFundingPnlUsdc;
        snapshot.liabilityOnlyFundingPnlUsdc = withdrawalState.fundingLiabilityUsdc;
        snapshot.totalDeferredPayoutUsdc = totalDeferredPayoutUsdc;
        snapshot.totalDeferredClearerBountyUsdc = totalDeferredClearerBountyUsdc;
        snapshot.degradedMode = degradedMode;
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        snapshot.hasLiveLiability = bullState.maxProfitUsdc + bearState.maxProfitUsdc > 0;
    }

    function getDeferredPayoutStatus(
        bytes32 accountId,
        address keeper
    ) external view returns (DeferredPayoutStatus memory status) {
        status.deferredTraderPayoutUsdc = deferredPayoutUsdc[accountId];
        status.traderPayoutClaimableNow =
            vault.totalAssets() >= status.deferredTraderPayoutUsdc && status.deferredTraderPayoutUsdc > 0;
        status.deferredClearerBountyUsdc = deferredClearerBountyUsdc[keeper];
        status.liquidationBountyClaimableNow =
            vault.totalAssets() >= status.deferredClearerBountyUsdc && status.deferredClearerBountyUsdc > 0;
    }

    function previewClose(
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (ClosePreview memory preview) {
        uint256 price = oraclePrice > CAP_PRICE ? CAP_PRICE : oraclePrice;
        preview.executionPrice = price;
        preview.sizeDelta = sizeDelta;

        CfdTypes.Position memory pos = positions[accountId];
        if (pos.size == 0) {
            preview.invalidCode = 1;
            return preview;
        }
        if (sizeDelta == 0 || sizeDelta > pos.size) {
            preview.invalidCode = 2;
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(accountId, oraclePrice, vaultDepthUsdc, 0);
        snap.vaultCashUsdc = vault.totalAssets();
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: sizeDelta,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: pos.side,
            isClose: true
        });
        CfdEnginePlanTypes.CloseDelta memory delta = CfdEnginePlanLib.planClose(snap, order, oraclePrice, 0);

        preview.fundingUsdc = delta.funding.pendingFundingUsdc;
        preview.realizedPnlUsdc = delta.realizedPnlUsdc;
        preview.remainingMargin = delta.posMarginAfter;
        preview.remainingSize = pos.size - sizeDelta;
        preview.vpiDeltaUsdc = delta.closeState.vpiDeltaUsdc;
        if (delta.closeState.vpiDeltaUsdc > 0) {
            preview.vpiUsdc = uint256(delta.closeState.vpiDeltaUsdc);
        }
        preview.executionFeeUsdc = delta.executionFeeUsdc;

        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION) {
            preview.invalidCode = 5;
            return preview;
        }

        preview.immediatePayoutUsdc = delta.payoutIsImmediate ? delta.traderPayoutUsdc : 0;
        preview.deferredPayoutUsdc = delta.payoutIsDeferred ? delta.traderPayoutUsdc : 0;

        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            preview.seizedCollateralUsdc = delta.lossResult.seizedUsdc;
            preview.badDebtUsdc = delta.badDebtUsdc;
        }

        if (
            delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNDERWATER
                || delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.FUNDING_PARTIAL_CLOSE_UNDERWATER
        ) {
            preview.invalidCode = 3;
            return preview;
        }

        preview.valid = delta.valid;
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterUsdc = delta.solvency.effectiveAssetsAfterUsdc;
        preview.maxLiabilityAfterUsdc = delta.solvency.maxLiabilityAfterUsdc;
    }

    function _previewFundingSettlement(
        bytes32 accountId,
        CfdTypes.Position memory pos,
        bool fullClose,
        uint256 vaultDepthUsdc
    ) internal view returns (PreviewFundingSettlement memory settlement) {
        settlement.pendingFundingUsdc = _previewPendingFunding(pos, vaultDepthUsdc);

        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        settlement.settlementBalanceAfterFundingUsdc = clearinghouse.balanceUsdc(accountId);
        settlement.positionMarginAfterFundingUsdc = lockedBuckets.positionMarginUsdc;

        (SideState storage selectedState,) = _sideAndOppositeStates(pos.side);
        settlement.selectedSideTotalMarginAfterFundingUsdc = selectedState.totalMargin;

        (int256 bullFundingIndex, int256 bearFundingIndex) = _previewFundingIndexes(vaultDepthUsdc);
        int256 selectedFundingIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        settlement.selectedSideEntryFundingAfterFunding =
            selectedState.entryFunding + int256(pos.size) * (selectedFundingIndex - pos.entryFundingIndex);

        if (settlement.pendingFundingUsdc >= 0) {
            if (fullClose) {
                settlement.closeFundingSettlementUsdc = settlement.pendingFundingUsdc;
            } else {
                uint256 gain = uint256(settlement.pendingFundingUsdc);
                settlement.positionMarginAfterFundingUsdc += gain;
                settlement.settlementBalanceAfterFundingUsdc += gain;
                settlement.selectedSideTotalMarginAfterFundingUsdc += gain;
                settlement.fundingVaultCashOutflowUsdc = gain;
            }
            return settlement;
        }

        uint256 loss = uint256(-settlement.pendingFundingUsdc);
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planFundingLossConsumption(buckets, loss);

        settlement.settlementBalanceAfterFundingUsdc -= consumption.totalConsumedUsdc;
        settlement.fundingVaultCashInflowUsdc = consumption.totalConsumedUsdc;
        if (consumption.activeMarginConsumedUsdc > 0) {
            settlement.positionMarginAfterFundingUsdc -= consumption.activeMarginConsumedUsdc;
            settlement.selectedSideTotalMarginAfterFundingUsdc -= consumption.activeMarginConsumedUsdc;
        }
        if (consumption.uncoveredUsdc > 0) {
            settlement.closeFundingSettlementUsdc = -int256(consumption.uncoveredUsdc);
        }
    }

    function _buildCloseExecutionPlan(
        CfdTypes.Position memory pos,
        uint256 sizeDelta,
        uint256 price,
        uint256 preSkewUsdc,
        uint256 vaultDepthUsdc,
        int256 fundingSettlementUsdc
    ) internal view returns (CloseExecutionPlan memory plan) {
        (SideState storage selectedState, SideState storage oppositeState) = _sideAndOppositeStates(pos.side);
        uint256 selectedOiAfter = selectedState.openInterest - sizeDelta;
        uint256 oppositeOi = oppositeState.openInterest;
        plan.postBullOi = pos.side == CfdTypes.Side.BULL ? selectedOiAfter : oppositeOi;
        plan.postBearOi = pos.side == CfdTypes.Side.BEAR ? selectedOiAfter : oppositeOi;

        uint256 postBullUsdc = (plan.postBullOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postBearUsdc = (plan.postBearOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postSkewUsdc = postBullUsdc > postBearUsdc ? postBullUsdc - postBearUsdc : postBearUsdc - postBullUsdc;

        plan.closeState = CloseAccountingLib.buildCloseState(
            pos.size,
            pos.margin,
            pos.entryPrice,
            pos.maxProfitUsdc,
            pos.vpiAccrued,
            pos.side,
            sizeDelta,
            price,
            CAP_PRICE,
            preSkewUsdc,
            postSkewUsdc,
            vaultDepthUsdc,
            riskParams.vpiFactor,
            EXECUTION_FEE_BPS,
            fundingSettlementUsdc
        );
    }

    function _previewPendingFunding(
        CfdTypes.Position memory pos,
        uint256 vaultDepthUsdc
    ) internal view returns (int256 fundingUsdc) {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        fundingUsdc = PositionRiskAccountingLib.previewPendingFunding(
            pos,
            bullState.fundingIndex,
            bearState.fundingIndex,
            lastMarkPrice,
            bullState.openInterest,
            bearState.openInterest,
            lastFundingTime,
            block.timestamp,
            vaultDepthUsdc,
            riskParams
        );
    }

    function previewLiquidation(
        bytes32 accountId,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (LiquidationPreview memory preview) {
        uint256 price = oraclePrice > CAP_PRICE ? CAP_PRICE : oraclePrice;
        preview.oraclePrice = price;

        if (positions[accountId].size == 0) {
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(accountId, oraclePrice, vaultDepthUsdc, 0);
        snap.vaultCashUsdc = vault.totalAssets();
        CfdEnginePlanTypes.LiquidationDelta memory delta = CfdEnginePlanLib.planLiquidation(snap, oraclePrice, 0);

        preview.liquidatable = delta.liquidatable;
        preview.reachableCollateralUsdc =
            MarginClearinghouseAccountingLib.getLiquidationReachableUsdc(snap.accountBuckets);
        preview.pnlUsdc = delta.riskState.unrealizedPnlUsdc;
        preview.fundingUsdc = delta.riskState.pendingFundingUsdc;
        preview.equityUsdc = delta.riskState.equityUsdc;
        preview.keeperBountyUsdc = delta.keeperBountyUsdc;

        preview.seizedCollateralUsdc = delta.residualPlan.seizedUsdc;
        preview.immediatePayoutUsdc = delta.payoutIsImmediate ? delta.traderPayoutUsdc : 0;
        preview.deferredPayoutUsdc = delta.payoutIsDeferred ? delta.traderPayoutUsdc : 0;
        preview.badDebtUsdc = delta.badDebtUsdc;

        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterUsdc = delta.solvency.effectiveAssetsAfterUsdc;
        preview.maxLiabilityAfterUsdc = delta.solvency.maxLiabilityAfterUsdc;
    }

    function viewDataMaxLiabilityAfterClose(
        CfdTypes.Side side,
        uint256 maxProfitReduction
    ) internal view returns (uint256) {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        return SolvencyAccountingLib.getMaxLiabilityAfterClose(
            bullState.maxProfitUsdc, bearState.maxProfitUsdc, side, maxProfitReduction
        );
    }

    function getPositionSide(
        bytes32 accountId
    ) external view returns (CfdTypes.Side) {
        return positions[accountId].side;
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
        if (positions[accountId].size == 0) {
            revert CfdEngine__NoPositionToLiquidate();
        }

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(accountId, currentOraclePrice, vaultDepthUsdc, publishTime);
        snap.vaultCashUsdc = vault.totalAssets();
        CfdEnginePlanTypes.LiquidationDelta memory delta =
            CfdEnginePlanLib.planLiquidation(snap, currentOraclePrice, publishTime);

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
            _getLiabilityOnlyFundingPnl(),
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc
        )
        .reservedUsdc;
    }

    function _buildHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) internal view returns (ICfdEngine.HousePoolInputSnapshot memory snapshot) {
        uint256 vaultAssetsUsdc = vault.totalAssets();
        snapshot.protocolFeesUsdc = accumulatedFeesUsdc;
        snapshot.netPhysicalAssetsUsdc =
            vaultAssetsUsdc > snapshot.protocolFeesUsdc ? vaultAssetsUsdc - snapshot.protocolFeesUsdc : 0;
        snapshot.maxLiabilityUsdc = _maxLiability();
        snapshot.withdrawalFundingLiabilityUsdc = _getLiabilityOnlyFundingPnl();
        snapshot.unrealizedMtmLiabilityUsdc = _getVaultMtmLiability();
        snapshot.deferredTraderPayoutUsdc = totalDeferredPayoutUsdc;
        snapshot.deferredClearerBountyUsdc = totalDeferredClearerBountyUsdc;
        snapshot.markFreshnessRequired = sides[_sideIndex(CfdTypes.Side.BULL)].maxProfitUsdc
                + sides[_sideIndex(CfdTypes.Side.BEAR)].maxProfitUsdc > 0;
        if (snapshot.markFreshnessRequired) {
            snapshot.maxMarkStaleness = isOracleFrozen() ? fadMaxStaleness : markStalenessLimit;
        }
    }

    function _buildHousePoolStatusSnapshot()
        internal
        view
        returns (ICfdEngine.HousePoolStatusSnapshot memory snapshot)
    {
        snapshot.lastMarkTime = lastMarkTime;
        snapshot.oracleFrozen = isOracleFrozen();
        snapshot.degradedMode = degradedMode;
    }

    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        return SolvencyAccountingLib.buildSolvencyState(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            _maxLiability(),
            _getSolvencyCappedFundingPnl(),
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc
        );
    }

    function _buildPreviewSolvencyState(
        uint256 bullOiAfter,
        uint256 bearOiAfter,
        int256 bullEntryFundingAfter,
        int256 bearEntryFundingAfter,
        uint256 bullMarginAfter,
        uint256 bearMarginAfter,
        uint256 vaultDepthUsdc
    ) internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        (int256 bullFundingIndex, int256 bearFundingIndex) = _previewFundingIndexes(vaultDepthUsdc);
        int256 bullFundingAfter =
            (int256(bullOiAfter) * bullFundingIndex - bullEntryFundingAfter) / int256(CfdMath.FUNDING_INDEX_SCALE);
        int256 bearFundingAfter =
            (int256(bearOiAfter) * bearFundingIndex - bearEntryFundingAfter) / int256(CfdMath.FUNDING_INDEX_SCALE);
        CfdEngineSnapshotsLib.FundingSnapshot memory fundingSnapshot = CfdEngineSnapshotsLib.buildFundingSnapshot(
            bullFundingAfter, bearFundingAfter, bullMarginAfter, bearMarginAfter
        );

        return SolvencyAccountingLib.buildSolvencyState(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            _maxLiability(),
            fundingSnapshot.solvencyFunding,
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc
        );
    }

    function _buildPreviewCloseSolvencyState(
        CfdTypes.Position memory pos,
        uint256 sizeDelta,
        uint256 postBullOi,
        uint256 postBearOi,
        uint256 remainingMarginUsdc,
        uint256 vaultDepthUsdc,
        uint256 selectedSideTotalMarginAfterFundingUsdc,
        int256 selectedSideEntryFundingAfterFunding
    ) internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        (, SideState storage oppositeState) = _sideAndOppositeStates(pos.side);
        (int256 bullFundingIndex, int256 bearFundingIndex) = _previewFundingIndexes(vaultDepthUsdc);
        int256 selectedFundingIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        uint256 selectedMarginAfter = selectedSideTotalMarginAfterFundingUsdc - pos.margin + remainingMarginUsdc;
        int256 selectedEntryFundingAfter =
            selectedSideEntryFundingAfterFunding - int256(sizeDelta) * selectedFundingIndex;
        uint256 bullOiAfter = pos.side == CfdTypes.Side.BULL ? postBullOi : oppositeState.openInterest;
        uint256 bearOiAfter = pos.side == CfdTypes.Side.BEAR ? postBearOi : oppositeState.openInterest;
        int256 bullEntryFundingAfter =
            pos.side == CfdTypes.Side.BULL ? selectedEntryFundingAfter : oppositeState.entryFunding;
        int256 bearEntryFundingAfter =
            pos.side == CfdTypes.Side.BEAR ? selectedEntryFundingAfter : oppositeState.entryFunding;
        uint256 bullMarginAfter = pos.side == CfdTypes.Side.BULL ? selectedMarginAfter : oppositeState.totalMargin;
        uint256 bearMarginAfter = pos.side == CfdTypes.Side.BEAR ? selectedMarginAfter : oppositeState.totalMargin;
        return _buildPreviewSolvencyState(
            bullOiAfter,
            bearOiAfter,
            bullEntryFundingAfter,
            bearEntryFundingAfter,
            bullMarginAfter,
            bearMarginAfter,
            vaultDepthUsdc
        );
    }

    function _buildPreviewLiquidationSolvencyState(
        CfdTypes.Position memory pos,
        uint256 vaultDepthUsdc
    ) internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        (SideState storage selectedState, SideState storage oppositeState) = _sideAndOppositeStates(pos.side);
        uint256 selectedOiAfter = selectedState.openInterest - pos.size;
        int256 selectedEntryFundingAfter = selectedState.entryFunding - int256(pos.size) * pos.entryFundingIndex;
        uint256 selectedMarginAfter = selectedState.totalMargin - pos.margin;
        uint256 bullOiAfter = pos.side == CfdTypes.Side.BULL ? selectedOiAfter : oppositeState.openInterest;
        uint256 bearOiAfter = pos.side == CfdTypes.Side.BEAR ? selectedOiAfter : oppositeState.openInterest;
        int256 bullEntryFundingAfter =
            pos.side == CfdTypes.Side.BULL ? selectedEntryFundingAfter : oppositeState.entryFunding;
        int256 bearEntryFundingAfter =
            pos.side == CfdTypes.Side.BEAR ? selectedEntryFundingAfter : oppositeState.entryFunding;
        uint256 bullMarginAfter = pos.side == CfdTypes.Side.BULL ? selectedMarginAfter : oppositeState.totalMargin;
        uint256 bearMarginAfter = pos.side == CfdTypes.Side.BEAR ? selectedMarginAfter : oppositeState.totalMargin;
        return _buildPreviewSolvencyState(
            bullOiAfter,
            bearOiAfter,
            bullEntryFundingAfter,
            bearEntryFundingAfter,
            bullMarginAfter,
            bearMarginAfter,
            vaultDepthUsdc
        );
    }

    function _previewFundingIndexes(
        uint256 vaultDepthUsdc
    ) internal view returns (int256 bullFundingIndex, int256 bearFundingIndex) {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        bullFundingIndex = bullState.fundingIndex;
        bearFundingIndex = bearState.fundingIndex;

        uint256 timeDelta = block.timestamp - lastFundingTime;
        if (timeDelta == 0 || vaultDepthUsdc == 0 || lastMarkPrice == 0) {
            return (bullFundingIndex, bearFundingIndex);
        }

        PositionRiskAccountingLib.FundingStepResult memory step = PositionRiskAccountingLib.computeFundingStep(
            PositionRiskAccountingLib.FundingStepInputs({
                price: lastMarkPrice,
                bullOi: bullState.openInterest,
                bearOi: bearState.openInterest,
                timeDelta: timeDelta,
                vaultDepthUsdc: vaultDepthUsdc,
                riskParams: riskParams
            })
        );
        bullFundingIndex += step.bullFundingIndexDelta;
        bearFundingIndex += step.bearFundingIndexDelta;
    }

    function _buildLiquidationComputation(
        bytes32 accountId,
        CfdTypes.Position memory pos,
        uint256 price,
        int256 pendingFundingUsdc
    ) internal view returns (LiquidationComputation memory computation) {
        uint256 maintMarginBps = isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps;
        computation.reachableCollateralUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);
        computation.riskState = PositionRiskAccountingLib.buildPositionRiskState(
            pos, price, CAP_PRICE, pendingFundingUsdc, computation.reachableCollateralUsdc, maintMarginBps
        );
        computation.liquidationState = LiquidationAccountingLib.buildLiquidationState(
            pos.size,
            price,
            computation.reachableCollateralUsdc,
            computation.riskState.pendingFundingUsdc,
            computation.riskState.unrealizedPnlUsdc,
            maintMarginBps,
            riskParams.minBountyUsdc,
            riskParams.bountyBps,
            CfdMath.USDC_TO_TOKEN_SCALE
        );
        computation.settlement = LiquidationAccountingLib.settlementForState(computation.liquidationState);
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
        snapshot.solvencyFunding = state.solvencyFundingPnlUsdc;
        snapshot.effectiveSolvencyAssets = state.effectiveAssetsUsdc;
    }

    // ==========================================
    // PLAN-APPLY: RAW SNAPSHOT BUILDER
    // ==========================================

    function _buildRawSnapshot(
        bytes32 accountId,
        uint256 executionPrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap.accountId = accountId;
        snap.position = positions[accountId];

        snap.currentTimestamp = block.timestamp;
        snap.lastFundingTime = lastFundingTime;
        snap.lastMarkPrice = lastMarkPrice;
        snap.lastMarkTime = lastMarkTime;

        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        snap.bullSide = _copySideSnapshot(bullState);
        snap.bearSide = _copySideSnapshot(bearState);

        snap.vaultAssetsUsdc = vaultDepthUsdc;
        snap.vaultCashUsdc = vaultDepthUsdc;

        snap.accountBuckets = clearinghouse.getAccountUsdcBuckets(accountId);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);

        if (orderRouter != address(0)) {
            snap.marginReservationIds = IOrderRouterAccounting(orderRouter).getMarginReservationIds(accountId);
        }

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
        snap.fundingIndex = state.fundingIndex;
        snap.entryFunding = state.entryFunding;
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
        if (code == CfdEnginePlanTypes.OpenRevertCode.FUNDING_EXCEEDS_MARGIN) {
            revert CfdEngine__FundingExceedsMargin();
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
        if (code == CfdEnginePlanTypes.CloseRevertCode.FUNDING_PARTIAL_CLOSE_UNDERWATER) {
            revert CfdEngine__PartialCloseUnderwaterFunding();
        }
    }

    function _applyFundingAndMark(
        int256 bullDelta,
        int256 bearDelta,
        uint256 absSkew,
        uint64 newFundingTime,
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) internal {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        if (bullDelta != 0 || bearDelta != 0) {
            bullState.fundingIndex += bullDelta;
            bearState.fundingIndex += bearDelta;
        }
        lastFundingTime = newFundingTime;
        emit FundingUpdated(bullState.fundingIndex, bearState.fundingIndex, absSkew);
        lastMarkPrice = newMarkPrice;
        lastMarkTime = newMarkTime;
    }

    function _applyFundingSettlement(
        CfdEnginePlanTypes.FundingDelta memory fd,
        bytes32 accountId,
        CfdTypes.Position storage pos
    ) internal {
        if (fd.payoutType == CfdEnginePlanTypes.FundingPayoutType.MARGIN_CREDIT) {
            pos.margin += fd.posMarginIncrease;
            vault.payOut(address(clearinghouse), fd.fundingVaultPayoutUsdc);
            clearinghouse.creditSettlementAndLockMargin(accountId, fd.fundingClearinghouseCreditUsdc);
        } else if (fd.payoutType == CfdEnginePlanTypes.FundingPayoutType.DEFERRED_PAYOUT) {
            _payOrRecordDeferredTraderPayout(accountId, uint256(fd.pendingFundingUsdc));
        } else if (
            fd.payoutType == CfdEnginePlanTypes.FundingPayoutType.LOSS_CONSUMED
                || fd.payoutType == CfdEnginePlanTypes.FundingPayoutType.LOSS_UNCOVERED_CLOSE
        ) {
            uint256 loss = uint256(-fd.pendingFundingUsdc);
            clearinghouse.consumeFundingLoss(accountId, pos.margin, loss, address(vault));
            pos.margin -= fd.posMarginDecrease;
        }

        if (pos.size > 0) {
            _sideState(pos.side).entryFunding += fd.sideEntryFundingDelta;
            pos.entryFundingIndex = fd.newPosEntryFundingIndex;
        }
    }

    function _applyOpen(
        CfdEnginePlanTypes.OpenDelta memory delta
    ) internal {
        CfdTypes.Position storage pos = positions[delta.accountId];
        CfdTypes.Side marginSide = pos.size > 0 ? pos.side : delta.posSide;
        uint256 marginSnapshot = pos.margin;

        CfdEnginePlanTypes.FundingDelta memory fd = delta.funding;
        _applyFundingAndMark(
            fd.bullFundingIndexDelta,
            fd.bearFundingIndexDelta,
            fd.fundingAbsSkewUsdc,
            fd.newLastFundingTime,
            fd.newLastMarkPrice,
            fd.newLastMarkTime
        );
        _applyFundingSettlement(fd, delta.accountId, pos);
        uint256 marginAfterFunding = pos.margin;
        _syncTotalSideMargin(marginSide, marginSnapshot, marginAfterFunding);

        SideState storage sideState = _sideState(delta.posSide);
        sideState.maxProfitUsdc += delta.sideMaxProfitIncrease;
        sideState.openInterest += delta.sideOiIncrease;

        pos.maxProfitUsdc += delta.posMaxProfitIncrease;
        if (pos.size == 0) {
            pos.side = delta.posSide;
            pos.entryFundingIndex = sideState.fundingIndex;
        }
        pos.entryPrice = delta.newPosEntryPrice;
        pos.size = delta.newPosSize;
        pos.vpiAccrued += delta.posVpiAccruedDelta;

        if (delta.sideEntryNotionalDelta >= 0) {
            sideState.entryNotional += uint256(delta.sideEntryNotionalDelta);
        } else {
            sideState.entryNotional -= uint256(-delta.sideEntryNotionalDelta);
        }
        sideState.entryFunding += delta.sideEntryFundingContribution;

        if (delta.vaultRebatePayoutUsdc > 0) {
            vault.payOut(address(clearinghouse), delta.vaultRebatePayoutUsdc);
        }

        int256 netMarginChange =
            clearinghouse.applyOpenCost(delta.accountId, delta.marginDeltaUsdc, delta.tradeCostUsdc, address(vault));

        if (netMarginChange > 0) {
            pos.margin += uint256(netMarginChange);
        } else if (netMarginChange < 0) {
            pos.margin -= uint256(-netMarginChange);
        }

        accumulatedFeesUsdc += delta.executionFeeUsdc;
        _syncTotalSideMargin(marginSide, marginAfterFunding, pos.margin);
        pos.lastUpdateTime = uint64(block.timestamp);

        emit PositionOpened(delta.accountId, delta.posSide, delta.sizeDelta, delta.price, delta.marginDeltaUsdc);
    }

    function _applyClose(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) internal {
        CfdTypes.Position storage pos = positions[delta.accountId];
        CfdTypes.Side marginSide = pos.side;
        uint256 marginSnapshot = pos.margin;

        CfdEnginePlanTypes.FundingDelta memory fd = delta.funding;
        _applyFundingAndMark(
            fd.bullFundingIndexDelta,
            fd.bearFundingIndexDelta,
            fd.fundingAbsSkewUsdc,
            fd.newLastFundingTime,
            fd.newLastMarkPrice,
            fd.newLastMarkTime
        );
        _applyFundingSettlement(fd, delta.accountId, pos);
        uint256 marginAfterFunding = pos.margin;
        _syncTotalSideMargin(marginSide, marginSnapshot, marginAfterFunding);

        pos.margin = delta.posMarginAfter;
        pos.maxProfitUsdc -= delta.posMaxProfitReduction;

        SideState storage sideState = _sideState(marginSide);
        sideState.maxProfitUsdc -= delta.sideMaxProfitReduction;
        sideState.openInterest -= delta.sideOiDecrease;
        sideState.entryNotional -= delta.sideEntryNotionalReduction;
        sideState.entryFunding -= delta.sideEntryFundingReduction;

        pos.size -= delta.posSizeDelta;
        pos.vpiAccrued -= delta.posVpiAccruedReduction;

        clearinghouse.unlockPositionMargin(delta.accountId, delta.unlockMarginUsdc);

        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.GAIN) {
            _payOrRecordDeferredTraderPayout(delta.accountId, delta.traderPayoutUsdc);
        } else if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            uint64[] memory reservationOrderIds =
                IOrderRouterAccounting(orderRouter).getMarginReservationIds(delta.accountId);
            clearinghouse.consumeCloseLoss(
                delta.accountId,
                reservationOrderIds,
                uint256(-delta.closeState.netSettlementUsdc),
                delta.posMarginAfter,
                address(vault)
            );
            _syncMarginQueue(delta.accountId, delta.syncMarginQueueAmount);
            accumulatedBadDebtUsdc += delta.badDebtUsdc;
        }

        accumulatedFeesUsdc += delta.executionFeeUsdc;
        _syncTotalSideMargin(marginSide, marginAfterFunding, pos.margin);

        emit PositionClosed(delta.accountId, marginSide, delta.sizeDelta, delta.price, delta.realizedPnlUsdc);

        if (delta.deletePosition) {
            delete positions[delta.accountId];
        } else {
            pos.lastUpdateTime = uint64(block.timestamp);
        }

        _enterDegradedModeIfInsolvent(delta.accountId, 0);
    }

    function _applyLiquidation(
        CfdEnginePlanTypes.LiquidationDelta memory delta
    ) internal returns (uint256 keeperBountyUsdc) {
        CfdEnginePlanTypes.GlobalFundingDelta memory gfd = delta.funding;
        _applyFundingAndMark(
            gfd.bullFundingIndexDelta,
            gfd.bearFundingIndexDelta,
            gfd.fundingAbsSkewUsdc,
            gfd.newLastFundingTime,
            gfd.newLastMarkPrice,
            gfd.newLastMarkTime
        );

        SideState storage sideState = _sideState(delta.side);
        sideState.entryFunding -= delta.sideEntryFundingReduction;
        sideState.maxProfitUsdc -= delta.sideMaxProfitDecrease;
        sideState.openInterest -= delta.sideOiDecrease;
        sideState.entryNotional -= delta.sideEntryNotionalReduction;

        keeperBountyUsdc = delta.keeperBountyUsdc;
        uint64[] memory reservationOrderIds =
            IOrderRouterAccounting(orderRouter).getMarginReservationIds(delta.accountId);
        (, uint256 payoutUsdc, uint256 badDebtUsdc) = clearinghouse.consumeLiquidationResidual(
            delta.accountId, reservationOrderIds, delta.posMargin, delta.residualUsdc, address(vault)
        );
        _syncMarginQueue(delta.accountId, delta.syncMarginQueueAmount);
        if (payoutUsdc > 0) {
            _payOrRecordDeferredTraderPayout(delta.accountId, payoutUsdc);
        }
        accumulatedBadDebtUsdc += badDebtUsdc;

        sideState.totalMargin -= delta.posMargin;

        emit PositionLiquidated(delta.accountId, delta.side, delta.posSize, delta.price, keeperBountyUsdc);
        delete positions[delta.accountId];
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

    function _computeGlobalFundingPnl() internal view returns (int256 bullFunding, int256 bearFunding) {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        bullFunding = (int256(bullState.openInterest) * bullState.fundingIndex - bullState.entryFunding)
            / int256(CfdMath.FUNDING_INDEX_SCALE);
        bearFunding = (int256(bearState.openInterest) * bearState.fundingIndex - bearState.entryFunding)
            / int256(CfdMath.FUNDING_INDEX_SCALE);
    }

    function _buildFundingSnapshot() internal view returns (CfdEngineSnapshotsLib.FundingSnapshot memory snapshot) {
        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        return CfdEngineSnapshotsLib.buildFundingSnapshot(
            bullFunding, bearFunding, bullState.totalMargin, bearState.totalMargin
        );
    }

    function _getSolvencyCappedFundingPnl() internal view returns (int256) {
        return _buildFundingSnapshot().solvencyFunding;
    }

    function _getLiabilityOnlyFundingPnl() internal view returns (int256) {
        return _buildFundingSnapshot().withdrawalFundingLiability;
    }

    function _validateRiskParams(
        CfdTypes.RiskParams memory _riskParams
    ) internal pure {
        if (_riskParams.maintMarginBps == 0 || _riskParams.fadMarginBps < _riskParams.maintMarginBps) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.fadMarginBps > 10_000) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.minBountyUsdc == 0 || _riskParams.bountyBps == 0) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.kinkSkewRatio == 0 || _riskParams.maxSkewRatio <= _riskParams.kinkSkewRatio) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.maxSkewRatio > CfdMath.WAD) {
            revert CfdEngine__InvalidRiskParams();
        }
        if (_riskParams.baseApy > _riskParams.maxApy) {
            revert CfdEngine__InvalidRiskParams();
        }
    }

    function _getUnrealizedFundingPnl() internal view returns (int256) {
        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();
        return bullFunding + bearFunding;
    }

    /// @notice Aggregate unsettled funding across all positions (uncapped, for reporting only)
    /// @return Net funding PnL in USDC (6 decimals), positive = traders are owed funding
    function getUnrealizedFundingPnl() external view returns (int256) {
        return _getUnrealizedFundingPnl();
    }

    /// @notice Aggregate unsettled funding across all positions with uncollectible debts capped by margin.
    /// @return Net funding PnL in USDC (6 decimals), positive = traders are owed funding
    function getCappedFundingPnl() external view returns (int256) {
        return _getSolvencyCappedFundingPnl();
    }

    /// @notice Aggregate unsettled funding liabilities only, ignoring trader debts owed to the vault.
    /// @return Funding liabilities the vault should conservatively reserve for withdrawals (6 decimals)
    function getLiabilityOnlyFundingPnl() external view returns (int256) {
        return _getLiabilityOnlyFundingPnl();
    }

    /// @notice Returns the protocol's worst-case directional liability.
    function getMaxLiability() external view returns (uint256) {
        return _maxLiability();
    }

    /// @notice Returns the total USDC reserve required for withdrawals.
    function getWithdrawalReservedUsdc() external view returns (uint256) {
        return _getWithdrawalReservedUsdc();
    }

    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (ICfdEngine.HousePoolInputSnapshot memory snapshot) {
        return _buildHousePoolInputSnapshot(markStalenessLimit);
    }

    function getHousePoolStatusSnapshot() external view returns (ICfdEngine.HousePoolStatusSnapshot memory snapshot) {
        return _buildHousePoolStatusSnapshot();
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
        _syncFunding();
        lastMarkPrice = clamped;
        lastMarkTime = publishTime;
    }

    function _cacheMarkPriceIfNewer(
        uint256 price,
        uint64 publishTime
    ) internal {
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }
        lastMarkPrice = price;
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

    /// @notice Combined MtM: per-side (PnL + funding), clamped at zero.
    ///         Positive = vault owes traders (unrealized liability). Zero = traders losing or neutral.
    ///         The vault never counts unrealized trader losses as assets — realized losses flow
    ///         through physical USDC transfers (settlements, liquidations).
    /// @return Net MtM adjustment the vault must reserve (always >= 0), in USDC (6 decimals)
    function getVaultMtmAdjustment() external view returns (int256) {
        return _getVaultMtmLiability();
    }

    function _getVaultMtmLiability() internal view returns (int256) {
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

        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();

        if (bullFunding < -int256(bullState.totalMargin)) {
            bullFunding = -int256(bullState.totalMargin);
        }
        if (bearFunding < -int256(bearState.totalMargin)) {
            bearFunding = -int256(bearState.totalMargin);
        }

        int256 bullTotal = bullPnl + bullFunding;
        int256 bearTotal = bearPnl + bearFunding;

        if (bullTotal < 0) {
            bullTotal = 0;
        }
        if (bearTotal < 0) {
            bearTotal = 0;
        }

        return bullTotal + bearTotal;
    }

}
