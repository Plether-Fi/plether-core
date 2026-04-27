// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {CfdEngineSettlementTypes} from "./interfaces/CfdEngineSettlementTypes.sol";
import {EngineStatusViewTypes} from "./interfaces/EngineStatusViewTypes.sol";
import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdEngineAdminHost} from "./interfaces/ICfdEngineAdminHost.sol";
import {ICfdEnginePlanner} from "./interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineSettlementHost} from "./interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineSettlementModule} from "./interfaces/ICfdEngineSettlementModule.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
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
/// @dev Settles all funds through the MarginClearinghouse and CfdVault.
/// @custom:security-contact contact@plether.com
contract CfdEngine is IWithdrawGuard, ICfdEngineAdminHost, Ownable2Step, ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    struct AccountCollateralView {
        uint256 settlementBalanceUsdc;
        uint256 lockedMarginUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
        uint256 closeReachableUsdc;
        uint256 terminalReachableUsdc;
        uint256 accountEquityUsdc;
        uint256 freeBuyingPowerUsdc;
        uint256 deferredTraderCreditUsdc;
    }

    struct PositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        uint256 entryNotionalUsdc;
        uint256 physicalReachableCollateralUsdc;
        uint256 nettableDeferredTraderCreditUsdc;
        int256 unrealizedPnlUsdc;
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
        uint256 totalDeferredTraderCreditUsdc;
        uint256 totalDeferredKeeperCreditUsdc;
        bool degradedMode;
        bool hasLiveLiability;
    }

    struct ClosePreview {
        bool valid;
        CfdTypes.CloseInvalidReason invalidReason;
        uint256 executionPrice;
        uint256 sizeDelta;
        int256 realizedPnlUsdc;
        int256 vpiDeltaUsdc;
        uint256 vpiUsdc;
        uint256 executionFeeUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 existingDeferredConsumedUsdc;
        uint256 existingDeferredRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 deferredTraderCreditUsdc;
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
        uint256 reachableCollateralUsdc;
        uint256 keeperBountyUsdc;
        uint256 seizedCollateralUsdc;
        uint256 settlementRetainedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 existingDeferredConsumedUsdc;
        uint256 existingDeferredRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 deferredTraderCreditUsdc;
        uint256 badDebtUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct DeferredCreditStatus {
        uint256 deferredTraderCreditUsdc;
        bool traderPayoutClaimableNow;
        uint256 deferredKeeperCreditUsdc;
        bool keeperCreditClaimableNow;
    }

    struct SideState {
        uint256 maxProfitUsdc;
        uint256 openInterest;
        uint256 entryNotional;
        uint256 totalMargin;
    }

    struct StoredPosition {
        uint256 size;
        uint256 entryPrice;
        uint256 maxProfitUsdc;
        CfdTypes.Side side;
        uint64 lastUpdateTime;
        uint64 lastCarryTimestamp;
        int256 vpiAccrued;
    }

    uint256 public immutable CAP_PRICE;

    IERC20 public immutable USDC;
    IMarginClearinghouse public immutable clearinghouse;
    ICfdVault public vault;
    ICfdEnginePlanner public planner;
    ICfdEngineSettlementModule public settlementModule;
    address public admin;

    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    SideState[2] public sides;
    uint256 public lastMarkPrice;
    uint64 public lastMarkTime;

    uint256 public accumulatedFeesUsdc;
    uint256 public accumulatedBadDebtUsdc;
    mapping(address => uint256) public unsettledCarryUsdc;
    bool public degradedMode;

    CfdTypes.RiskParams public riskParams;
    mapping(address => StoredPosition) internal _positions;
    mapping(address => uint256) public deferredTraderCreditUsdc;
    uint256 public totalDeferredTraderCreditUsdc;
    mapping(address => uint256) public deferredKeeperCreditUsdc;
    uint256 public totalDeferredKeeperCreditUsdc;
    address public orderRouter;

    mapping(uint256 => bool) public fadDayOverrides;
    uint256[] private _fadOverrideDays;
    uint256 public fadMaxStaleness = 3 days;
    uint256 public fadRunwaySeconds = 3 hours;
    uint256 public engineMarkStalenessLimit = 60;
    uint256 public executionFeeBps = 4;
    error CfdEngine__Unauthorized();
    error CfdEngine__VaultAlreadySet();
    error CfdEngine__RouterAlreadySet();
    error CfdEngine__DependenciesAlreadySet();
    error CfdEngine__NoFeesToWithdraw();
    error CfdEngine__NoDeferredTraderCredit();
    error CfdEngine__InsufficientVaultLiquidity();
    error CfdEngine__NoDeferredKeeperCredit();
    error CfdEngine__MustCloseOpposingPosition();
    error CfdEngine__CarryExceedsMargin();
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
    error CfdEngine__ZeroAmount();
    error CfdEngine__RunwayTooLong();
    error CfdEngine__PartialCloseUnderwaterCarry();
    error CfdEngine__DustPosition();
    error CfdEngine__MarkPriceStale();
    error CfdEngine__MarkPriceOutOfOrder();
    error CfdEngine__NotClearinghouse();
    error CfdEngine__NotAccountOwner();
    error CfdEngine__NoOpenPosition();
    error CfdEngine__BadDebtTooLarge();
    error CfdEngine__InvalidRiskParams();
    error CfdEngine__SkewTooHigh();
    error CfdEngine__DegradedMode();
    error CfdEngine__NotDegraded();
    error CfdEngine__StillInsolvent();
    error CfdEngine__ZeroAddress();
    error CfdEngine__InsufficientCloseOrderBountyBacking();
    event CarryUpdated(int256 bullIndex, int256 bearIndex, uint256 absSkewUsdc);
    event PositionOpened(
        address indexed account, CfdTypes.Side side, uint256 sizeDelta, uint256 price, uint256 marginDelta
    );
    event PositionClosed(address indexed account, CfdTypes.Side side, uint256 sizeDelta, uint256 price, int256 pnl);
    event PositionLiquidated(
        address indexed account, CfdTypes.Side side, uint256 size, uint256 price, uint256 keeperBounty
    );
    event MarginAdded(address indexed account, uint256 amount);
    event FadDaysAdded(uint256[] timestamps);
    event FadDaysRemoved(uint256[] timestamps);
    event FadMaxStalenessUpdated(uint256 newStaleness);
    event FadRunwayUpdated(uint256 newRunway);
    event EngineMarkStalenessLimitUpdated(uint256 newStaleness);
    event BadDebtCleared(uint256 amount, uint256 remaining);
    event DegradedModeEntered(uint256 effectiveAssets, uint256 maxLiability, address indexed triggeringAccount);
    event DegradedModeCleared();
    event DeferredTraderCreditRecorded(address indexed account, uint256 amountUsdc);
    event DeferredTraderCreditClaimed(address indexed account, uint256 amountUsdc);
    event DeferredKeeperCreditRecorded(address indexed keeper, uint256 amountUsdc);
    event DeferredKeeperCreditClaimed(address indexed keeper, uint256 amountUsdc);
    event CarryCheckpointed(address indexed account, uint256 addedUnsettledCarryUsdc, uint256 totalUnsettledCarryUsdc);
    event CarryRealized(
        address indexed account,
        uint256 realizedCarryUsdc,
        uint256 freeSettlementConsumedUsdc,
        uint256 marginConsumedUsdc,
        uint256 remainingUnsettledCarryUsdc
    );
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

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

    function _checkpointDeferredClaimCarryIfPossible(
        address account,
        StoredPosition storage pos
    ) internal {
        if (pos.size == 0) {
            return;
        }

        (bool priceFresh, uint256 price) = _tryGetFreshLiveMarkPrice();
        if (priceFresh) {
            _checkpointCarryBeforeBasisChange(account, pos, price, _genericReachableCollateralUsdc(account));
            return;
        }

        price = lastMarkPrice;
        if (price == 0 || lastMarkTime == 0) {
            revert CfdEngine__MarkPriceStale();
        }

        _checkpointCarryBeforeBasisChange(account, pos, price, _genericReachableCollateralUsdc(account));
    }

    function _claimDeferredBalance(
        uint256 amount,
        address account
    ) internal returns (uint256 claimAmountUsdc) {
        claimAmountUsdc = CashPriorityLib.availableCashForDeferredBeneficiaryClaim(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            totalDeferredTraderCreditUsdc,
            totalDeferredKeeperCreditUsdc,
            amount
        );
        if (claimAmountUsdc == 0) {
            revert CfdEngine__InsufficientVaultLiquidity();
        }

        vault.payOut(address(clearinghouse), claimAmountUsdc);
        clearinghouse.settleUsdc(account, int256(claimAmountUsdc));
    }

    function _increaseDeferredLiability(
        uint256 currentAmountUsdc,
        uint256 currentTotalUsdc,
        uint256 amountUsdc
    ) internal pure returns (uint256 updatedAmountUsdc, uint256 updatedTotalUsdc) {
        updatedAmountUsdc = currentAmountUsdc + amountUsdc;
        updatedTotalUsdc = currentTotalUsdc + amountUsdc;
    }

    function _decreaseDeferredLiability(
        uint256 currentAmountUsdc,
        uint256 currentTotalUsdc,
        uint256 amountUsdc
    ) internal pure returns (uint256 updatedAmountUsdc, uint256 updatedTotalUsdc) {
        updatedAmountUsdc = currentAmountUsdc - amountUsdc;
        updatedTotalUsdc = currentTotalUsdc - amountUsdc;
    }

    modifier onlyRouter() {
        if (msg.sender != orderRouter) {
            revert CfdEngine__Unauthorized();
        }
        _;
    }

    modifier onlySettlementModule() {
        if (msg.sender != address(settlementModule)) {
            revert CfdEngine__Unauthorized();
        }
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert CfdEngine__Unauthorized();
        }
        _;
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
        _validateRiskParams(_riskParams);
        USDC = IERC20(_usdc);
        clearinghouse = IMarginClearinghouse(_clearinghouse);
        CAP_PRICE = _capPrice;
        riskParams = _riskParams;
    }

    /// @notice One-time setter for planner, settlement module, and admin sidecars.
    function setDependencies(
        address planner_,
        address settlementModule_,
        address admin_
    ) external onlyOwner {
        if (planner_ == address(0) || settlementModule_ == address(0) || admin_ == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (address(planner) != address(0) || address(settlementModule) != address(0) || admin != address(0)) {
            revert CfdEngine__DependenciesAlreadySet();
        }
        planner = ICfdEnginePlanner(planner_);
        settlementModule = ICfdEngineSettlementModule(settlementModule_);
        admin = admin_;
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

    /// @notice Withdraws accumulated execution fees from the vault to a recipient.
    function withdrawFees(
        address recipient
    ) external onlyOwner {
        withdrawFees(recipient, accumulatedFeesUsdc);
    }

    /// @notice Withdraws up to `amountUsdc` of accumulated execution fees from the vault to a recipient.
    function withdrawFees(
        address recipient,
        uint256 amountUsdc
    ) public onlyOwner {
        uint256 fees = accumulatedFeesUsdc;
        if (fees == 0) {
            revert CfdEngine__NoFeesToWithdraw();
        }
        if (amountUsdc == 0) {
            revert CfdEngine__NoFeesToWithdraw();
        }
        uint256 withdrawalUsdc = amountUsdc < fees ? amountUsdc : fees;
        if (!_canWithdrawProtocolFees(withdrawalUsdc)) {
            revert CfdEngine__InsufficientVaultLiquidity();
        }
        accumulatedFeesUsdc = fees - withdrawalUsdc;
        vault.payOut(recipient, withdrawalUsdc);
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

    /// @notice Books router-delivered protocol-owned inflow as protocol fees after the router has already funded the vault.
    function recordRouterProtocolFee(
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }

        accumulatedFeesUsdc += amountUsdc;
    }

    /// @notice Credits a router-collected execution bounty into the beneficiary's clearinghouse account.
    /// @dev Realizes carry first when the beneficiary currently has an open position because the
    ///      clearinghouse settlement credit changes the carry basis. Router execution already validates
    ///      the oracle publish time, so this helper only enforces monotonic publish ordering before
    ///      checkpointing against the validated cached mark.
    function creditKeeperExecutionBounty(
        address beneficiary,
        uint256 amountUsdc,
        uint256 price,
        uint64 publishTime
    ) external onlyRouter nonReentrant {
        if (amountUsdc == 0) {
            return;
        }

        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }

        uint256 clampedPrice = price > CAP_PRICE ? CAP_PRICE : price;
        lastMarkPrice = clampedPrice;
        lastMarkTime = publishTime;

        address account = beneficiary;
        StoredPosition storage pos = _positions[account];
        if (pos.size > 0) {
            _checkpointCarryBeforeBasisChange(account, pos, clampedPrice, _genericReachableCollateralUsdc(account));
        }

        clearinghouse.settleUsdc(account, int256(amountUsdc));
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

        (bool priceFresh, uint256 price) = _tryGetFreshLiveMarkPrice();
        if (!priceFresh) {
            revert CfdEngine__MarkPriceStale();
        }
        _realizeCarryFromSettlement(account, pos, price, _genericReachableCollateralUsdc(account));

        uint256 marginBefore = _positionMarginBucketUsdc(account);
        clearinghouse.lockPositionMargin(account, amount);
        _syncTotalSideMargin(pos.side, marginBefore, _positionMarginBucketUsdc(account));
        pos.lastUpdateTime = uint64(block.timestamp);
        pos.lastCarryTimestamp = uint64(block.timestamp);

        emit MarginAdded(account, amount);
    }

    /// @notice Realizes accrued carry before a user-level clearinghouse balance mutation changes the carry basis.
    /// @dev Called only by the clearinghouse before user deposits and withdrawals.
    function realizeCarryBeforeMarginChange(
        address account,
        uint256 reachableCollateralBasisUsdc
    ) external nonReentrant {
        if (msg.sender != address(clearinghouse)) {
            revert CfdEngine__NotClearinghouse();
        }

        StoredPosition storage pos = _positions[account];
        if (pos.size == 0) {
            return;
        }

        (bool priceFresh, uint256 price) = _tryGetFreshLiveMarkPrice();
        if (!priceFresh) {
            revert CfdEngine__MarkPriceStale();
        }

        _realizeCarryFromSettlement(account, pos, price, reachableCollateralBasisUsdc);
    }

    /// @notice Checkpoints carry against the cached stored mark when fresh-mark liveness is unavailable.
    /// @dev Restricted to the clearinghouse stale-deposit path so deposits preserve pre-mutation carry basis.
    function checkpointCarryUsingStoredMark(
        address account,
        uint256 reachableCollateralBasisUsdc
    ) external nonReentrant {
        if (msg.sender != address(clearinghouse)) {
            revert CfdEngine__NotClearinghouse();
        }

        StoredPosition storage pos = _positions[account];
        if (pos.size == 0 || pos.lastCarryTimestamp == 0) {
            return;
        }

        uint256 price = lastMarkPrice;
        if (price == 0 || lastMarkTime == 0) {
            revert CfdEngine__MarkPriceStale();
        }

        _checkpointCarryBeforeBasisChange(account, pos, price, reachableCollateralBasisUsdc);
    }

    /// @notice Claims deferred trader credit balance into the clearinghouse.
    /// @dev The claim can be partial if current vault cash is insufficient. Funds are credited to the
    ///      clearinghouse first, so beneficiaries access them through the normal account-balance path.
    ///      Carry is checkpointed before the settlement-basis change using a fresh mark when available,
    ///      otherwise the cached stored mark is used.
    function claimDeferredTraderCredit(
        address account
    ) external nonReentrant {
        if (msg.sender != account) {
            revert CfdEngine__NotAccountOwner();
        }
        StoredPosition storage pos = _positions[account];
        _checkpointDeferredClaimCarryIfPossible(account, pos);

        uint256 amount = deferredTraderCreditUsdc[account];
        if (amount == 0) {
            revert CfdEngine__NoDeferredTraderCredit();
        }
        uint256 claimAmountUsdc = _claimDeferredBalance(amount, account);

        deferredTraderCreditUsdc[account] -= claimAmountUsdc;
        totalDeferredTraderCreditUsdc -= claimAmountUsdc;

        emit DeferredTraderCreditClaimed(account, claimAmountUsdc);
    }

    /// @notice Claims previously deferred keeper credit when the vault has replenished cash.
    /// @dev Deferred keeper value always settles to clearinghouse credit for the recorded keeper address-derived account.
    function claimDeferredKeeperCredit() external nonReentrant {
        address beneficiary = msg.sender;
        address account = beneficiary;
        StoredPosition storage pos = _positions[account];
        _checkpointDeferredClaimCarryIfPossible(account, pos);

        uint256 amount = deferredKeeperCreditUsdc[beneficiary];
        if (amount == 0) {
            revert CfdEngine__NoDeferredKeeperCredit();
        }

        uint256 claimAmountUsdc = _claimDeferredBalance(amount, account);

        (deferredKeeperCreditUsdc[beneficiary], totalDeferredKeeperCreditUsdc) = _decreaseDeferredLiability(
            deferredKeeperCreditUsdc[beneficiary], totalDeferredKeeperCreditUsdc, claimAmountUsdc
        );

        emit DeferredKeeperCreditClaimed(beneficiary, claimAmountUsdc);
    }

    /// @notice Records keeper credit that could not be serviced immediately because vault cash was unavailable.
    function recordDeferredKeeperCredit(
        address keeper,
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }
        _enqueueOrAccrueDeferredKeeperCredit(keeper, amountUsdc);
        emit DeferredKeeperCreditRecorded(keeper, amountUsdc);
    }

    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 amountUsdc,
        address recipient
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
            address(vault) == address(0) ? 0 : vault.markStalenessLimit(),
            0,
            0,
            fadMaxStaleness
        );
        if (closeCommitPolicy.requireStoredMark && lastMarkTime == 0) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        if (priceFresh) {
            _realizeCarryFromSettlement(account, pos, price, _genericReachableCollateralUsdc(account));
        }

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

        CfdTypes.Position memory positionAfter = _loadPosition(account);
        positionAfter.margin = positionMarginUsdc - marginBackedBountyUsdc;
        bool isFullClose = sizeDelta == positionAfter.size;
        uint256 pendingCarryUsdc =
            _totalPendingCarryUsdc(account, positionAfter, price, postReservationReachableUsdc, block.timestamp);
        PositionRiskAccountingLib.PositionRiskState memory riskState =
            PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
                positionAfter,
                price,
                CAP_PRICE,
                pendingCarryUsdc,
                postReservationReachableUsdc,
                isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps
            );
        if (riskState.liquidatable && !isFullClose) {
            revert CfdEngine__InsufficientCloseOrderBountyBacking();
        }

        _syncTotalSideMargin(pos.side, positionMarginUsdc, positionMarginUsdc - marginBackedBountyUsdc);
        if (freeBackedBountyUsdc > 0) {
            if (priceFresh) {
                clearinghouse.reserveCloseExecutionBountyFromSettlement(account, freeBackedBountyUsdc, recipient);
            } else {
                clearinghouse.reserveStaleCloseExecutionBountyFromSettlement(account, freeBackedBountyUsdc, recipient);
            }
        }
        if (marginBackedBountyUsdc == 0) {
            return;
        }
        if (priceFresh) {
            clearinghouse.seizePositionMarginUsdc(account, marginBackedBountyUsdc, recipient);
        } else {
            clearinghouse.reserveStaleCloseExecutionBountyFromPositionMargin(account, marginBackedBountyUsdc, recipient);
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
        USDC.safeTransferFrom(msg.sender, address(vault), amount);
        vault.recordClaimantInflow(
            amount, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
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
        emit TokenSwept(token, to, amount);
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
        _validateRiskParams(config.riskParams);
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
        uint256[] memory removedTimestamps = new uint256[](oldLength);
        for (uint256 i; i < oldLength; i++) {
            uint256 day = _fadOverrideDays[i];
            removedTimestamps[i] = day * 86_400;
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
        emit FadDaysRemoved(removedTimestamps);
        emit FadDaysAdded(config.fadDayTimestamps);
        emit FadRunwayUpdated(config.fadRunwaySeconds);
    }

    function applyFreshnessConfig(
        ICfdEngineAdminHost.EngineFreshnessConfig calldata config
    ) external onlyAdmin {
        if (config.fadMaxStaleness == 0 || config.engineMarkStalenessLimit == 0) {
            revert CfdEngine__ZeroStaleness();
        }
        fadMaxStaleness = config.fadMaxStaleness;
        engineMarkStalenessLimit = config.engineMarkStalenessLimit;
        emit FadMaxStalenessUpdated(config.fadMaxStaleness);
        emit EngineMarkStalenessLimitUpdated(config.engineMarkStalenessLimit);
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
        _realizeCarryFromSettlement(account, storedPos, price, reachableUsdc);
        pos = _loadPosition(account);
        reachableUsdc = _genericReachableCollateralUsdc(account);
        uint256 pendingCarryUsdc = _totalPendingCarryUsdc(account, pos, price, reachableUsdc, block.timestamp);
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
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external onlyRouter nonReentrant {
        _processOrder(order, currentOraclePrice, vaultDepthUsdc, publishTime);
    }

    function _processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) internal {
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(order.account, currentOraclePrice, vaultDepthUsdc, publishTime);
        snap.vaultCashUsdc = vault.totalAssets();

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

    function _syncMarginQueue(
        address account,
        uint256 consumedCommittedReservationUsdc
    ) internal {
        if (consumedCommittedReservationUsdc == 0 || orderRouter == address(0)) {
            return;
        }
        IOrderRouterAccounting(orderRouter).syncMarginQueue(account);
    }

    function _payOrRecordDeferredTraderPayout(
        address account,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        if (_canPayFreshVaultPayout(amountUsdc)) {
            vault.payOut(address(clearinghouse), amountUsdc);
            clearinghouse.settleUsdc(account, int256(amountUsdc));
        } else {
            _enqueueOrAccrueDeferredTraderPayout(account, amountUsdc);
            emit DeferredTraderCreditRecorded(account, amountUsdc);
        }
    }

    function _enqueueOrAccrueDeferredTraderPayout(
        address account,
        uint256 amountUsdc
    ) internal {
        (deferredTraderCreditUsdc[account], totalDeferredTraderCreditUsdc) =
            _increaseDeferredLiability(deferredTraderCreditUsdc[account], totalDeferredTraderCreditUsdc, amountUsdc);
    }

    function _enqueueOrAccrueDeferredKeeperCredit(
        address keeper,
        uint256 amountUsdc
    ) internal {
        (deferredKeeperCreditUsdc[keeper], totalDeferredKeeperCreditUsdc) =
            _increaseDeferredLiability(deferredKeeperCreditUsdc[keeper], totalDeferredKeeperCreditUsdc, amountUsdc);
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

    function _freshVaultReservation() internal view returns (CashPriorityLib.SeniorCashReservation memory reservation) {
        return CashPriorityLib.reserveFreshPayouts(
            vault.totalAssets(), accumulatedFeesUsdc, totalDeferredTraderCreditUsdc, totalDeferredKeeperCreditUsdc
        );
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

    function getPositionLastCarryTimestamp(
        address account
    ) external view returns (uint64) {
        return _positions[account].lastCarryTimestamp;
    }

    /// @notice Liquidates an undercollateralized position.
    ///         Surplus equity (after bounty) is returned to the user.
    ///         In bad-debt cases (equity < bounty), all remaining margin is seized by the vault.
    /// @param account Clearinghouse account that owns the position
    /// @param currentOraclePrice Pyth oracle price (8 decimals), clamped to CAP_PRICE
    /// @param vaultDepthUsdc HousePool total assets used for post-op solvency checks and payout affordability
    /// @param publishTime Pyth publish timestamp, stored as lastMarkTime
    /// @return keeperBountyUsdc Bounty paid to the liquidation keeper (USDC, 6 decimals)
    function liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external onlyRouter nonReentrant returns (uint256 keeperBountyUsdc) {
        if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }
        if (_positions[account].size == 0) {
            revert CfdEngine__NoPositionToLiquidate();
        }

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(account, currentOraclePrice, vaultDepthUsdc, publishTime);
        snap.vaultCashUsdc = vault.totalAssets();
        CfdEnginePlanTypes.LiquidationDelta memory delta =
            planner.planLiquidation(snap, currentOraclePrice, publishTime);

        if (!delta.liquidatable) {
            revert CfdEngine__PositionIsSolvent();
        }

        return _applyLiquidation(delta, publishTime);
    }

    function _assertPostSolvency() internal view {
        SolvencyAccountingLib.SolvencyState memory state = _buildAdjustedSolvencyState();
        if (SolvencyAccountingLib.isInsolvent(state)) {
            revert CfdEngine__PostOpSolvencyBreach();
        }
    }

    function _maxLiability() internal view returns (uint256) {
        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        return SolvencyAccountingLib.getMaxLiability(
            bullState.maxProfitUsdc, bullState.totalMargin, bearState.maxProfitUsdc, bearState.totalMargin
        );
    }

    function _getWithdrawalReservedUsdc() internal view returns (uint256 reservedUsdc) {
        return _buildAdjustedSolvencyState().withdrawalReservedUsdc;
    }

    function _buildAdjustedSolvencyState() internal view returns (SolvencyAccountingLib.SolvencyState memory) {
        return SolvencyAccountingLib.buildSolvencyState(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            _maxLiability(),
            totalDeferredTraderCreditUsdc,
            totalDeferredKeeperCreditUsdc
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
        snapshot.effectiveSolvencyAssets = state.effectiveAssetsUsdc;
    }

    // ==========================================
    // PLAN-APPLY: RAW SNAPSHOT BUILDER
    // ==========================================

    function _buildRawSnapshot(
        address account,
        uint256,
        uint256 vaultDepthUsdc,
        uint64
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap.account = account;
        snap.position = _loadPosition(account);

        snap.currentTimestamp = block.timestamp;
        snap.lastMarkPrice = lastMarkPrice;
        snap.lastMarkTime = lastMarkTime;

        (SideState storage bullState, SideState storage bearState) = _bullAndBearStates();
        snap.bullSide = _copySideSnapshot(bullState);
        snap.bearSide = _copySideSnapshot(bearState);

        snap.vaultAssetsUsdc = vaultDepthUsdc;
        snap.vaultCashUsdc = vaultDepthUsdc;

        snap.accountBuckets = clearinghouse.getAccountUsdcBuckets(account);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        snap.position.margin = snap.lockedBuckets.positionMarginUsdc;

        snap.accumulatedFeesUsdc = accumulatedFeesUsdc;
        snap.accumulatedBadDebtUsdc = accumulatedBadDebtUsdc;
        snap.unsettledCarryUsdc = unsettledCarryUsdc[account];
        snap.totalDeferredTraderCreditUsdc = totalDeferredTraderCreditUsdc;
        snap.totalDeferredKeeperCreditUsdc = totalDeferredKeeperCreditUsdc;
        snap.deferredTraderCreditForAccount = deferredTraderCreditUsdc[account];
        snap.degradedMode = degradedMode;

        snap.capPrice = CAP_PRICE;
        snap.riskParams = riskParams;
        snap.executionFeeBps = executionFeeBps;
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

        revert ICfdEngine.CfdEngine__TypedOrderFailure(
            planner.getExecutionFailurePolicyCategory(code), uint8(code), false
        );
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

    function _applyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) internal {
        lastMarkPrice = newMarkPrice;
        lastMarkTime = newMarkTime;
    }

    function settlementApplyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) external onlySettlementModule {
        _applyCarryAndMark(newMarkPrice, newMarkTime);
    }

    function settlementSyncTotalSideMargin(
        CfdTypes.Side side,
        uint256 marginBefore,
        uint256 marginAfter
    ) external onlySettlementModule {
        _syncTotalSideMargin(side, marginBefore, marginAfter);
    }

    function settlementApplySideDelta(
        CfdTypes.Side side,
        int256 maxProfitDelta,
        int256 openInterestDelta,
        int256 entryNotionalDelta
    ) external onlySettlementModule {
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

    function settlementConsumeDeferredTraderPayout(
        address account,
        uint256 amountUsdc
    ) external onlySettlementModule {
        _consumeDeferredTraderPayout(account, amountUsdc);
    }

    function settlementRecordDeferredTraderPayout(
        address account,
        uint256 amountUsdc
    ) external onlySettlementModule {
        _payOrRecordDeferredTraderPayout(account, amountUsdc);
    }

    function settlementAccumulateFees(
        uint256 amountUsdc
    ) external onlySettlementModule {
        accumulatedFeesUsdc += amountUsdc;
    }

    function settlementAccumulateBadDebt(
        uint256 amountUsdc
    ) external onlySettlementModule {
        accumulatedBadDebtUsdc += amountUsdc;
    }

    function settlementWritePosition(
        address account,
        CfdEngineSettlementTypes.PositionState calldata position
    ) external onlySettlementModule {
        StoredPosition storage pos = _positions[account];
        pos.size = position.size;
        pos.entryPrice = position.entryPrice;
        pos.maxProfitUsdc = position.maxProfitUsdc;
        pos.side = position.side;
        pos.lastUpdateTime = position.lastUpdateTime;
        pos.lastCarryTimestamp = position.lastCarryTimestamp;
        pos.vpiAccrued = position.vpiAccrued;
    }

    function settlementDeletePosition(
        address account
    ) external onlySettlementModule {
        delete _positions[account];
    }

    function _applyOpen(
        CfdEnginePlanTypes.OpenDelta memory delta,
        uint64 publishTime
    ) internal {
        StoredPosition storage pos = _positions[delta.account];
        CfdTypes.Position memory currentPosition = _loadPosition(delta.account);
        if (pos.size > 0) {
            _realizeCarryFromSettlement(delta.account, pos, delta.price, _genericReachableCollateralUsdc(delta.account));
            currentPosition = _loadPosition(delta.account);
        }
        settlementModule.executeOpen(ICfdEngineSettlementHost(address(this)), delta, currentPosition, publishTime);
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
        settlementModule.executeClose(ICfdEngineSettlementHost(address(this)), delta, currentPosition, publishTime);
        emit PositionClosed(delta.account, marginSide, delta.sizeDelta, delta.price, delta.realizedPnlUsdc);

        unsettledCarryUsdc[delta.account] = 0;

        _enterDegradedModeIfInsolvent(delta.account, 0);
    }

    function _applyLiquidation(
        CfdEnginePlanTypes.LiquidationDelta memory delta,
        uint64 publishTime
    ) internal returns (uint256 keeperBountyUsdc) {
        keeperBountyUsdc =
            settlementModule.executeLiquidation(ICfdEngineSettlementHost(address(this)), delta, publishTime);
        emit PositionLiquidated(delta.account, delta.side, delta.posSize, delta.price, keeperBountyUsdc);

        unsettledCarryUsdc[delta.account] = 0;

        _enterDegradedModeIfInsolvent(delta.account, keeperBountyUsdc);
    }

    function _enterDegradedModeIfInsolvent(
        address account,
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
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 reachableCollateralUsdc,
        uint256 timestampNow
    ) internal view returns (uint256) {
        if (pos.size == 0 || pos.lastCarryTimestamp == 0 || timestampNow <= pos.lastCarryTimestamp) {
            return 0;
        }
        uint256 lpBackedNotionalUsdc =
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(pos.size, price, reachableCollateralUsdc);
        return PositionRiskAccountingLib.computePendingCarryUsdc(
            lpBackedNotionalUsdc, riskParams.baseCarryBps, timestampNow - pos.lastCarryTimestamp
        );
    }

    function _totalPendingCarryUsdc(
        address account,
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 reachableCollateralUsdc,
        uint256 timestampNow
    ) internal view returns (uint256) {
        return unsettledCarryUsdc[account] + _elapsedCarryUsdc(pos, price, reachableCollateralUsdc, timestampNow);
    }

    function _canFullyRealizeCarryFromSettlement(
        address account,
        CfdTypes.Position memory pos,
        uint256 price
    ) internal view returns (bool) {
        uint256 reachableCollateralUsdc = _genericReachableCollateralUsdc(account);
        uint256 pendingCarryUsdc = _totalPendingCarryUsdc(account, pos, price, reachableCollateralUsdc, block.timestamp);
        if (pendingCarryUsdc == 0) {
            return true;
        }

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        return MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, pendingCarryUsdc).uncoveredUsdc == 0;
    }

    function _checkpointCarryBeforeBasisChange(
        address account,
        StoredPosition storage pos,
        uint256 price,
        uint256 reachableCollateralUsdc
    ) internal {
        if (_canFullyRealizeCarryFromSettlement(account, _loadPosition(account), price)) {
            _realizeCarryFromSettlement(account, pos, price, reachableCollateralUsdc);
            return;
        }

        uint256 elapsedCarryUsdc =
            _elapsedCarryUsdc(_loadPosition(account), price, reachableCollateralUsdc, block.timestamp);
        if (elapsedCarryUsdc > 0) {
            unsettledCarryUsdc[account] += elapsedCarryUsdc;
            emit CarryCheckpointed(account, elapsedCarryUsdc, unsettledCarryUsdc[account]);
        }
        pos.lastCarryTimestamp = uint64(block.timestamp);
    }

    function _realizeCarryFromSettlement(
        address account,
        StoredPosition storage pos,
        uint256 price,
        uint256 reachableCollateralUsdc
    ) internal returns (uint256 realizedCarryUsdc) {
        CfdTypes.Position memory loaded = _loadPosition(account);
        uint256 carryDueUsdc = _totalPendingCarryUsdc(account, loaded, price, reachableCollateralUsdc, block.timestamp);
        if (carryDueUsdc == 0) {
            pos.lastCarryTimestamp = uint64(block.timestamp);
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
        }

        if (realizedCarryUsdc > 0) {
            USDC.safeTransfer(address(vault), realizedCarryUsdc);
            vault.recordClaimantInflow(
                realizedCarryUsdc, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
            );
        }
        emit CarryRealized(
            account, realizedCarryUsdc, freeSettlementConsumedUsdc, marginConsumedUsdc, unsettledCarryUsdc[account]
        );
        pos.lastCarryTimestamp = uint64(block.timestamp);
    }

    function _liveMarkStalenessLimit() internal view returns (uint256) {
        return OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.PoolReconcile,
            isOracleFrozen(),
            isFadWindow(),
            engineMarkStalenessLimit,
            address(vault) == address(0) ? 0 : vault.markStalenessLimit(),
            0,
            0,
            fadMaxStaleness
        )
        .maxStaleness;
    }

    function _consumeDeferredTraderPayout(
        address account,
        uint256 amountUsdc
    ) internal {
        if (amountUsdc == 0) {
            return;
        }

        deferredTraderCreditUsdc[account] -= amountUsdc;
        totalDeferredTraderCreditUsdc -= amountUsdc;
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
        lastMarkPrice = clamped;
        lastMarkTime = publishTime;
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

    function getProtocolStatus() external view returns (EngineStatusViewTypes.ProtocolStatus memory status) {
        status.phase = uint8(_getProtocolPhase());
        status.lastMarkPrice = lastMarkPrice;
        status.lastMarkTime = lastMarkTime;
        status.oracleFrozen = isOracleFrozen();
        status.fadWindow = isFadWindow();
        status.fadMaxStaleness = fadMaxStaleness;
    }

}
