// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
import {CfdEngineSettlementLib} from "./libraries/CfdEngineSettlementLib.sol";
import {CfdEngineSnapshotsLib} from "./libraries/CfdEngineSnapshotsLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CfdEngine
/// @notice The core mathematical ledger for Plether CFDs.
/// @dev Settles all funds through the MarginClearinghouse and CfdVault.
/// @custom:security-contact contact@plether.com
contract CfdEngine is IWithdrawGuard, Ownable2Step, ReentrancyGuard {

    using SafeERC20 for IERC20;

    struct AccountCollateralView {
        uint256 settlementBalanceUsdc;
        uint256 lockedMarginUsdc;
        uint256 reservedSettlementUsdc;
        uint256 freeSettlementUsdc;
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
        uint256 totalDeferredLiquidationBountyUsdc;
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
        uint256 badDebtUsdc;
        bool triggersDegradedMode;
    }

    struct DeferredPayoutStatus {
        uint256 deferredTraderPayoutUsdc;
        bool traderPayoutClaimableNow;
        uint256 deferredLiquidationBountyUsdc;
        bool liquidationBountyClaimableNow;
    }

    uint256 public immutable CAP_PRICE;

    IERC20 public immutable USDC;
    IMarginClearinghouse public clearinghouse;
    ICfdVault public vault;

    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    uint256 public globalBullMaxProfit;
    uint256 public globalBearMaxProfit;

    uint256 public bullOI;
    uint256 public bearOI;

    uint256 public globalBullEntryNotional;
    uint256 public globalBearEntryNotional;
    uint256 public lastMarkPrice;
    uint64 public lastMarkTime;

    uint256 public totalBullMargin;
    uint256 public totalBearMargin;

    uint256 public accumulatedFeesUsdc;
    uint256 public accumulatedBadDebtUsdc;
    bool public degradedMode;

    // ==========================================
    // FUNDING ACCUMULATORS
    // ==========================================

    int256 public bullFundingIndex;
    int256 public bearFundingIndex;
    uint64 public lastFundingTime;
    int256 public globalBullEntryFunding;
    int256 public globalBearEntryFunding;

    CfdTypes.RiskParams public riskParams;
    mapping(bytes32 => CfdTypes.Position) public positions;
    mapping(bytes32 => uint256) public deferredPayoutUsdc;
    uint256 public totalDeferredPayoutUsdc;
    mapping(address => uint256) public deferredLiquidationBountyUsdc;
    uint256 public totalDeferredLiquidationBountyUsdc;

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
    error CfdEngine__NoDeferredLiquidationBounty();
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
    event DeferredLiquidationBountyRecorded(address indexed keeper, uint256 amountUsdc);
    event DeferredLiquidationBountyClaimed(address indexed keeper, uint256 amountUsdc);

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
        if (address(vault) != address(0)) {
            revert CfdEngine__VaultAlreadySet();
        }
        vault = ICfdVault(_vault);
    }

    /// @notice One-time setter for the authorized OrderRouter
    function setOrderRouter(
        address _router
    ) external onlyOwner {
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
        _updateFunding(lastMarkPrice, vault.totalAssets());
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
        uint256 fees = accumulatedFeesUsdc;
        if (fees == 0) {
            revert CfdEngine__NoFeesToWithdraw();
        }
        accumulatedFeesUsdc = 0;
        vault.payOut(recipient, fees);
        _assertPostSolvency();
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

        clearinghouse.lockMargin(accountId, amount);
        pos.margin += amount;
        if (pos.side == CfdTypes.Side.BULL) {
            totalBullMargin += amount;
        } else {
            totalBearMargin += amount;
        }
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
        clearinghouse.settleUsdc(accountId, address(USDC), int256(amount));

        emit DeferredPayoutClaimed(accountId, amount);
    }

    /// @notice Claims a previously deferred liquidation bounty when the vault has replenished cash.
    function claimDeferredLiquidationBounty() external nonReentrant {
        uint256 amount = deferredLiquidationBountyUsdc[msg.sender];
        if (amount == 0) {
            revert CfdEngine__NoDeferredLiquidationBounty();
        }
        if (vault.totalAssets() < amount) {
            revert CfdEngine__InsufficientVaultLiquidity();
        }

        deferredLiquidationBountyUsdc[msg.sender] = 0;
        totalDeferredLiquidationBountyUsdc -= amount;
        vault.payOut(msg.sender, amount);

        emit DeferredLiquidationBountyClaimed(msg.sender, amount);
    }

    /// @notice Records a liquidation bounty that could not be paid immediately because vault cash was unavailable.
    function recordDeferredLiquidationBounty(
        address keeper,
        uint256 amountUsdc
    ) external onlyRouter {
        if (amountUsdc == 0) {
            return;
        }
        deferredLiquidationBountyUsdc[keeper] += amountUsdc;
        totalDeferredLiquidationBountyUsdc += amountUsdc;
        emit DeferredLiquidationBountyRecorded(keeper, amountUsdc);
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

        int256 pendingFunding = getPendingFunding(pos);
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, CAP_PRICE);

        uint256 reachableUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);

        int256 equity = int256(reachableUsdc) + pendingFunding;
        equity = isProfit ? equity + int256(pnlAbs) : equity - int256(pnlAbs);

        uint256 mmr = getMaintenanceMarginUsdc(pos.size, price);
        if (equity < int256(mmr)) {
            revert CfdEngine__WithdrawBlockedByOpenPosition();
        }
    }

    // ==========================================
    // 1. CONTINUOUS FUNDING SYSTEM
    // ==========================================

    function _updateFunding(
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) internal {
        uint256 timeDelta = block.timestamp - lastFundingTime;
        if (timeDelta == 0) {
            return;
        }

        uint256 bullUsdc = (bullOI * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bearOI * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;

        uint256 absSkew;
        bool bullMajority;

        if (bullUsdc > bearUsdc) {
            absSkew = bullUsdc - bearUsdc;
            bullMajority = true;
        } else {
            absSkew = bearUsdc - bullUsdc;
            bullMajority = false;
        }

        if (absSkew > 0 && vaultDepthUsdc > 0) {
            uint256 annRate = CfdMath.getAnnualizedFundingRate(absSkew, vaultDepthUsdc, riskParams);
            uint256 fundingDelta = (annRate * timeDelta) / CfdMath.SECONDS_PER_YEAR;
            int256 step = int256((currentOraclePrice * fundingDelta) / 1e8);

            if (step > 0) {
                if (bullMajority) {
                    bullFundingIndex -= step;
                    bearFundingIndex += step;
                } else {
                    bearFundingIndex -= step;
                    bullFundingIndex += step;
                }
            }
        }

        lastFundingTime = uint64(block.timestamp);
        emit FundingUpdated(bullFundingIndex, bearFundingIndex, absSkew);
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
        int256 currentIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        int256 indexDelta = currentIndex - pos.entryFundingIndex;
        fundingUsdc = (int256(pos.size) * indexDelta) / int256(CfdMath.FUNDING_INDEX_SCALE);
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
        uint256 price = currentOraclePrice > CAP_PRICE ? CAP_PRICE : currentOraclePrice;
        _updateFunding(lastMarkPrice, vaultDepthUsdc);
        _cacheMarkPriceIfNewer(price, publishTime);

        CfdTypes.Position storage pos = positions[order.accountId];
        uint256 marginSnapshot = pos.margin;
        CfdTypes.Side marginSide = pos.size > 0 ? pos.side : order.side;

        uint256 preSkewUsdc = _getAbsSkewUsdc(price);

        if (pos.size > 0 && pos.side != order.side) {
            revert CfdEngine__MustCloseOpposingPosition();
        }

        uint256 unsettledFundingDebt = _settleFunding(order, pos);

        if (order.isClose) {
            accumulatedFeesUsdc += _processDecrease(
                order, pos, price, preSkewUsdc, vaultDepthUsdc, unsettledFundingDebt
            );
            _enterDegradedModeIfInsolvent(order.accountId, 0);
        } else {
            if (degradedMode) {
                revert CfdEngine__DegradedMode();
            }
            _processIncrease(order, pos, price, preSkewUsdc, vaultDepthUsdc);
            _assertPostSolvency();
        }

        uint256 marginAfter = pos.margin;
        if (marginAfter > marginSnapshot) {
            if (marginSide == CfdTypes.Side.BULL) {
                totalBullMargin += marginAfter - marginSnapshot;
            } else {
                totalBearMargin += marginAfter - marginSnapshot;
            }
        } else if (marginSnapshot > marginAfter) {
            if (marginSide == CfdTypes.Side.BULL) {
                totalBullMargin -= marginSnapshot - marginAfter;
            } else {
                totalBearMargin -= marginSnapshot - marginAfter;
            }
        }

        pos.lastUpdateTime = uint64(block.timestamp);
    }

    // ==========================================
    // 3. INTERNAL LEDGER UPDATES
    // ==========================================

    function _settleFunding(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos
    ) internal returns (uint256 unsettledFundingDebt) {
        int256 pendingFunding = getPendingFunding(pos);
        if (pos.size > 0 && pendingFunding != 0) {
            if (pendingFunding > 0) {
                uint256 gain = uint256(pendingFunding);
                pos.margin += gain;
                vault.payOut(address(clearinghouse), gain);
                clearinghouse.settleUsdc(order.accountId, address(USDC), pendingFunding);
                clearinghouse.lockMargin(order.accountId, gain);
            } else {
                uint256 loss = uint256(-pendingFunding);
                (uint256 marginConsumedUsdc,, uint256 uncoveredUsdc) = clearinghouse.consumeFundingLoss(
                    order.accountId, pos.margin, loss, address(vault)
                );
                pos.margin -= marginConsumedUsdc;

                if (uncoveredUsdc > 0) {
                    if (!order.isClose) {
                        revert CfdEngine__FundingExceedsMargin();
                    }
                    if (order.sizeDelta < pos.size) {
                        revert CfdEngine__PartialCloseUnderwaterFunding();
                    }
                    unsettledFundingDebt = uncoveredUsdc;
                }
            }
        }
        if (pos.size > 0) {
            int256 newIdx = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
            int256 fundingDelta = int256(pos.size) * (newIdx - pos.entryFundingIndex);
            if (pos.side == CfdTypes.Side.BULL) {
                globalBullEntryFunding += fundingDelta;
            } else {
                globalBearEntryFunding += fundingDelta;
            }
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
        uint256 newMaxProfit = CfdMath.calculateMaxProfit(order.sizeDelta, price, order.side, CAP_PRICE);
        _addGlobalLiability(order.side, newMaxProfit, order.sizeDelta);
        pos.maxProfitUsdc += newMaxProfit;

        uint256 oldNotional = pos.size * pos.entryPrice;

        if (pos.size == 0) {
            pos.entryPrice = price;
            pos.side = order.side;
            pos.entryFundingIndex = order.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        } else {
            uint256 totalValue = oldNotional + (order.sizeDelta * price);
            pos.entryPrice = totalValue / (pos.size + order.sizeDelta);
        }

        pos.size += order.sizeDelta;
        uint256 newNotional = pos.size * pos.entryPrice;

        if (order.side == CfdTypes.Side.BULL) {
            if (newNotional >= oldNotional) {
                globalBullEntryNotional += newNotional - oldNotional;
            } else {
                globalBullEntryNotional -= oldNotional - newNotional;
            }
            globalBullEntryFunding += int256(order.sizeDelta) * pos.entryFundingIndex;
        } else {
            if (newNotional >= oldNotional) {
                globalBearEntryNotional += newNotional - oldNotional;
            } else {
                globalBearEntryNotional -= oldNotional - newNotional;
            }
            globalBearEntryFunding += int256(order.sizeDelta) * pos.entryFundingIndex;
        }

        CfdTypes.RiskParams memory rp = riskParams;

        uint256 postSkewUsdc = _getAbsSkewUsdc(price);
        if (vaultDepthUsdc > 0 && ((postSkewUsdc * CfdMath.WAD) / vaultDepthUsdc) > rp.maxSkewRatio) {
            revert CfdEngine__SkewTooHigh();
        }
        int256 vpiUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, rp.vpiFactor);
        pos.vpiAccrued += vpiUsdc;

        uint256 notionalUsdc = (order.sizeDelta * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        if (notionalUsdc * rp.bountyBps < rp.minBountyUsdc * 10_000) {
            revert CfdEngine__PositionTooSmall();
        }
        uint256 execFeeUsdc = (notionalUsdc * EXECUTION_FEE_BPS) / 10_000;

        int256 tradeCost = vpiUsdc + int256(execFeeUsdc);
        int256 netMarginChange = int256(order.marginDelta) - tradeCost;

        if (tradeCost > 0) {
            _seizeUsdcToVault(order.accountId, uint256(tradeCost));
        } else if (tradeCost < 0) {
            uint256 rebate = uint256(-tradeCost);
            vault.payOut(address(clearinghouse), rebate);
            clearinghouse.settleUsdc(order.accountId, address(USDC), int256(rebate));
        }

        if (netMarginChange > 0) {
            pos.margin += uint256(netMarginChange);
        } else if (netMarginChange < 0) {
            uint256 deficit = uint256(-netMarginChange);
            if (pos.margin < deficit) {
                revert CfdEngine__MarginDrainedByFees();
            }
            pos.margin -= deficit;
        }

        int256 lockDelta = netMarginChange;
        if (lockDelta > 0) {
            clearinghouse.lockMargin(order.accountId, uint256(lockDelta));
        } else if (lockDelta < 0) {
            clearinghouse.unlockMargin(order.accountId, uint256(-lockDelta));
        }

        accumulatedFeesUsdc += execFeeUsdc;

        uint256 mmr = getMaintenanceMarginUsdc(pos.size, price);
        uint256 imr = (mmr * 150) / 100;
        if (imr < rp.minBountyUsdc) {
            imr = rp.minBountyUsdc;
        }
        uint256 effectiveMargin = pos.margin;
        if (tradeCost < 0) {
            uint256 rebate = uint256(-tradeCost);
            effectiveMargin = effectiveMargin > rebate ? effectiveMargin - rebate : 0;
        }
        if (effectiveMargin < imr) {
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
        uint256 unsettledFundingDebt
    ) internal returns (uint256 collectedExecFeeUsdc) {
        if (pos.size < order.sizeDelta) {
            revert CfdEngine__CloseSizeExceedsPosition();
        }

        CfdTypes.Position memory closedPart = pos;
        closedPart.size = order.sizeDelta;
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, price, CAP_PRICE);
        int256 realizedPnl = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        uint256 marginToFree = (pos.margin * order.sizeDelta) / pos.size;
        pos.margin -= marginToFree;

        uint256 maxProfitReduction = (pos.maxProfitUsdc * order.sizeDelta) / pos.size;
        pos.maxProfitUsdc -= maxProfitReduction;
        _reduceGlobalLiability(pos.side, maxProfitReduction, order.sizeDelta);

        uint256 entryNotionalReduction = order.sizeDelta * pos.entryPrice;
        if (pos.side == CfdTypes.Side.BULL) {
            globalBullEntryNotional -= entryNotionalReduction;
            globalBullEntryFunding -= int256(order.sizeDelta) * pos.entryFundingIndex;
        } else {
            globalBearEntryNotional -= entryNotionalReduction;
            globalBearEntryFunding -= int256(order.sizeDelta) * pos.entryFundingIndex;
        }

        pos.size -= order.sizeDelta;

        if (pos.size > 0 && pos.margin < riskParams.minBountyUsdc) {
            revert CfdEngine__DustPosition();
        }

        clearinghouse.unlockMargin(order.accountId, marginToFree);

        uint256 postSkewUsdc = _getAbsSkewUsdc(price);
        int256 vpiUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, riskParams.vpiFactor);

        uint256 originalSize = pos.size + order.sizeDelta;
        int256 proportionalAccrual = (pos.vpiAccrued * int256(order.sizeDelta)) / int256(originalSize);
        if (proportionalAccrual + vpiUsdc < 0) {
            vpiUsdc = -proportionalAccrual;
        }
        pos.vpiAccrued -= proportionalAccrual;

        uint256 notionalUsdc = (order.sizeDelta * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 execFeeUsdc = (notionalUsdc * EXECUTION_FEE_BPS) / 10_000;

        int256 netSettlement = realizedPnl - vpiUsdc - int256(execFeeUsdc) - int256(unsettledFundingDebt);

        collectedExecFeeUsdc = _settleCloseNetSettlement(order.accountId, netSettlement, execFeeUsdc, pos.margin);

        emit PositionClosed(order.accountId, pos.side, order.sizeDelta, price, realizedPnl);

        if (pos.size == 0) {
            delete positions[order.accountId];
        }
    }

    function _getAbsSkewUsdc(
        uint256 currentOraclePrice
    ) internal view returns (uint256) {
        uint256 bullUsdc = (bullOI * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bearOI * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        return bullUsdc > bearUsdc ? bullUsdc - bearUsdc : bearUsdc - bullUsdc;
    }

    function _addGlobalLiability(
        CfdTypes.Side side,
        uint256 maxProfitUsdc,
        uint256 sizeDelta
    ) internal {
        if (side == CfdTypes.Side.BULL) {
            globalBullMaxProfit += maxProfitUsdc;
            bullOI += sizeDelta;
        } else {
            globalBearMaxProfit += maxProfitUsdc;
            bearOI += sizeDelta;
        }
        uint256 maxLiability = globalBullMaxProfit > globalBearMaxProfit ? globalBullMaxProfit : globalBearMaxProfit;
        if (_buildAdjustedSolvencySnapshot().effectiveSolvencyAssets < maxLiability) {
            revert CfdEngine__VaultSolvencyExceeded();
        }
    }

    function _reduceGlobalLiability(
        CfdTypes.Side side,
        uint256 maxProfitUsdc,
        uint256 sizeDelta
    ) internal {
        if (side == CfdTypes.Side.BULL) {
            globalBullMaxProfit -= maxProfitUsdc;
            bullOI -= sizeDelta;
        } else {
            globalBearMaxProfit -= maxProfitUsdc;
            bearOI -= sizeDelta;
        }
    }

    function _settleCloseNetSettlement(
        bytes32 accountId,
        int256 netSettlement,
        uint256 execFeeUsdc,
        uint256 remainingPosMarginUsdc
    ) internal returns (uint256 collectedExecFeeUsdc) {
        collectedExecFeeUsdc = execFeeUsdc;

        if (netSettlement > 0) {
            uint256 settlementGain = uint256(netSettlement);
            uint256 availableCash = vault.totalAssets();
            if (availableCash >= settlementGain) {
                vault.payOut(address(clearinghouse), settlementGain);
                clearinghouse.settleUsdc(accountId, address(USDC), netSettlement);
            } else {
                deferredPayoutUsdc[accountId] += settlementGain;
                totalDeferredPayoutUsdc += settlementGain;
                emit DeferredPayoutRecorded(accountId, settlementGain);
            }
            return collectedExecFeeUsdc;
        }

        if (netSettlement == 0) {
            return collectedExecFeeUsdc;
        }

        remainingPosMarginUsdc;
        CfdEngineSettlementLib.CloseSettlementResult memory result = CfdEngineSettlementLib.closeSettlementResult(
            clearinghouse.getFreeSettlementBalanceUsdc(accountId), uint256(-netSettlement), execFeeUsdc
        );
        if (result.seizedUsdc > 0) {
            _seizeUsdcToVault(accountId, result.seizedUsdc);
        }
        if (result.shortfallUsdc > 0 && remainingPosMarginUsdc > 0) {
            revert CfdEngine__PartialCloseUnderwaterFunding();
        }

        collectedExecFeeUsdc = result.collectedExecFeeUsdc;
        accumulatedBadDebtUsdc += result.badDebtUsdc;
    }

    function _settleLiquidationResidual(
        bytes32 accountId,
        uint256 positionMarginUsdc,
        int256 residualUsdc
    ) internal returns (CfdEngineSettlementLib.LiquidationSettlementResult memory result) {
        (result.seizedUsdc, result.payoutUsdc, result.badDebtUsdc) = clearinghouse.consumeLiquidationResidual(
            accountId, positionMarginUsdc, residualUsdc, address(vault)
        );
        if (result.payoutUsdc > 0) {
            vault.payOut(address(clearinghouse), result.payoutUsdc);
            clearinghouse.settleUsdc(accountId, address(USDC), int256(result.payoutUsdc));
        }
    }

    // ==========================================
    // LIQUIDATIONS & FAD
    // ==========================================

    /// @notice Returns true during the Friday Afternoon Deleverage (FAD) window
    ///         (Friday 19:00 UTC → Sunday 22:00 UTC), on admin-configured FAD days,
    ///         or within fadRunwaySeconds before an admin FAD day (deleverage runway).
    function isFadWindow() public view returns (bool) {
        uint256 dayOfWeek = ((block.timestamp / 86_400) + 4) % 7;
        uint256 hourOfDay = (block.timestamp % 86_400) / 3600;

        if (dayOfWeek == 5 && hourOfDay >= 19) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && hourOfDay < 22) {
            return true;
        }

        uint256 today = block.timestamp / 86_400;

        if (fadDayOverrides[today]) {
            return true;
        }

        uint256 runway = fadRunwaySeconds;
        if (runway > 0) {
            uint256 secondsUntilTomorrow = 86_400 - (block.timestamp % 86_400);
            if (secondsUntilTomorrow <= runway && fadDayOverrides[today + 1]) {
                return true;
            }
        }

        return false;
    }

    /// @notice Returns true only when FX markets are closed and oracle freshness can be relaxed.
    ///         Distinct from FAD, which starts earlier for deleveraging risk controls.
    function isOracleFrozen() public view returns (bool) {
        uint256 dayOfWeek = ((block.timestamp / 86_400) + 4) % 7;
        uint256 hourOfDay = (block.timestamp % 86_400) / 3600;

        if (dayOfWeek == 5 && hourOfDay >= 22) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && hourOfDay < 21) {
            return true;
        }

        return fadDayOverrides[block.timestamp / 86_400];
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
        uint256 positionMargin = pos.margin;
        viewData.settlementBalanceUsdc = clearinghouse.balances(accountId, address(USDC));
        viewData.lockedMarginUsdc = clearinghouse.lockedMarginUsdc(accountId);
        viewData.reservedSettlementUsdc = clearinghouse.reservedSettlementUsdc(accountId);
        viewData.freeSettlementUsdc = clearinghouse.getFreeSettlementBalanceUsdc(accountId);
        viewData.closeReachableUsdc = clearinghouse.getFreeSettlementBalanceUsdc(accountId);
        viewData.liquidationReachableUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, positionMargin);
        viewData.accountEquityUsdc = clearinghouse.getAccountEquityUsdc(accountId);
        viewData.freeBuyingPowerUsdc = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        viewData.deferredPayoutUsdc = deferredPayoutUsdc[accountId];
    }

    function getPositionView(
        bytes32 accountId
    ) external view returns (PositionView memory viewData) {
        CfdTypes.Position memory pos = positions[accountId];
        if (pos.size == 0) {
            return viewData;
        }

        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, lastMarkPrice, CAP_PRICE);
        int256 pendingFunding = getPendingFunding(pos);
        uint256 reachableUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);

        int256 equityUsdc = int256(reachableUsdc) + pendingFunding;
        equityUsdc = isProfit ? equityUsdc + int256(pnlAbs) : equityUsdc - int256(pnlAbs);

        viewData.exists = true;
        viewData.side = pos.side;
        viewData.size = pos.size;
        viewData.margin = pos.margin;
        viewData.entryPrice = pos.entryPrice;
        viewData.entryNotionalUsdc = (pos.size * pos.entryPrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        viewData.unrealizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        viewData.pendingFundingUsdc = pendingFunding;
        viewData.netEquityUsdc = equityUsdc;
        viewData.maxProfitUsdc = CfdMath.calculateMaxProfit(pos.size, pos.entryPrice, pos.side, CAP_PRICE);
        uint256 currentNotionalUsdc = (pos.size * lastMarkPrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 requiredBps = isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps;
        viewData.liquidatable = equityUsdc <= int256((currentNotionalUsdc * requiredBps) / 10_000);
    }

    function getProtocolAccountingView() external view returns (ProtocolAccountingView memory viewData) {
        viewData.vaultAssetsUsdc = vault.totalAssets();
        viewData.maxLiabilityUsdc = _maxLiability();
        viewData.withdrawalReservedUsdc = _getWithdrawalReservedUsdc();
        viewData.freeUsdc = viewData.vaultAssetsUsdc > viewData.withdrawalReservedUsdc
            ? viewData.vaultAssetsUsdc - viewData.withdrawalReservedUsdc
            : 0;
        viewData.accumulatedFeesUsdc = accumulatedFeesUsdc;
        viewData.cappedFundingPnlUsdc = _getSolvencyCappedFundingPnl();
        viewData.liabilityOnlyFundingPnlUsdc = _getLiabilityOnlyFundingPnl();
        viewData.totalDeferredPayoutUsdc = totalDeferredPayoutUsdc;
        viewData.totalDeferredLiquidationBountyUsdc = totalDeferredLiquidationBountyUsdc;
        viewData.degradedMode = degradedMode;
        viewData.hasLiveLiability = globalBullMaxProfit + globalBearMaxProfit > 0;
    }

    function getDeferredPayoutStatus(
        bytes32 accountId,
        address keeper
    ) external view returns (DeferredPayoutStatus memory status) {
        status.deferredTraderPayoutUsdc = deferredPayoutUsdc[accountId];
        status.traderPayoutClaimableNow =
            vault.totalAssets() >= status.deferredTraderPayoutUsdc && status.deferredTraderPayoutUsdc > 0;
        status.deferredLiquidationBountyUsdc = deferredLiquidationBountyUsdc[keeper];
        status.liquidationBountyClaimableNow =
            vault.totalAssets() >= status.deferredLiquidationBountyUsdc && status.deferredLiquidationBountyUsdc > 0;
    }

    function previewClose(
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (ClosePreview memory preview) {
        CfdTypes.Position memory pos = positions[accountId];
        preview.executionPrice = oraclePrice;
        preview.sizeDelta = sizeDelta;
        if (pos.size == 0) {
            preview.invalidCode = 1;
            return preview;
        }
        if (sizeDelta == 0 || sizeDelta > pos.size) {
            preview.invalidCode = 2;
            return preview;
        }

        preview.valid = true;
        (int256 pendingFunding, uint256 unsettledFundingDebt, uint256 marginAfterFunding) =
            _previewFundingSettlement(pos);
        pos.margin = marginAfterFunding;

        CfdTypes.Position memory closedPart = pos;
        closedPart.size = sizeDelta;
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, oraclePrice, CAP_PRICE);
        preview.realizedPnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        uint256 marginToFree = (pos.margin * sizeDelta) / pos.size;
        preview.remainingMargin = pos.margin - marginToFree;
        preview.remainingSize = pos.size - sizeDelta;
        preview.fundingUsdc = pendingFunding;

        uint256 preSkewUsdc = _getAbsSkewUsdc(lastMarkPrice);
        uint256 maxProfitReduction = (pos.maxProfitUsdc * sizeDelta) / pos.size;
        uint256 postBullOi = bullOI;
        uint256 postBearOi = bearOI;
        if (pos.side == CfdTypes.Side.BULL) {
            postBullOi -= sizeDelta;
        } else {
            postBearOi -= sizeDelta;
        }
        uint256 postBullUsdc = (postBullOi * oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postBearUsdc = (postBearOi * oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postSkewUsdc = postBullUsdc > postBearUsdc ? postBullUsdc - postBearUsdc : postBearUsdc - postBullUsdc;
        preview.vpiDeltaUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, riskParams.vpiFactor);
        if (preview.vpiDeltaUsdc > 0) {
            preview.vpiUsdc = uint256(preview.vpiDeltaUsdc);
        }
        uint256 notionalUsdc = (sizeDelta * oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        preview.executionFeeUsdc = (notionalUsdc * EXECUTION_FEE_BPS) / 10_000;

        int256 netSettlement = preview.realizedPnlUsdc - preview.vpiDeltaUsdc - int256(preview.executionFeeUsdc)
            - int256(unsettledFundingDebt);
        if (netSettlement > 0) {
            uint256 settlementGain = uint256(netSettlement);
            uint256 availableCash = vault.totalAssets();
            preview.immediatePayoutUsdc = availableCash >= settlementGain ? settlementGain : 0;
            preview.deferredPayoutUsdc = availableCash >= settlementGain ? 0 : settlementGain;
        } else if (netSettlement < 0) {
            CfdEngineSettlementLib.CloseSettlementResult memory result = CfdEngineSettlementLib.closeSettlementResult(
                clearinghouse.getFreeSettlementBalanceUsdc(accountId), uint256(-netSettlement), preview.executionFeeUsdc
            );
            preview.seizedCollateralUsdc = result.seizedUsdc;
            preview.badDebtUsdc = result.badDebtUsdc;
            if (result.shortfallUsdc > 0 && preview.remainingMargin > 0) {
                preview.valid = false;
                preview.invalidCode = 3;
            }
        }

        uint256 maxLiabilityAfter = viewDataMaxLiabilityAfterClose(pos.side, maxProfitReduction);
        uint256 effectiveAssetsAfter = _buildAdjustedSolvencySnapshot().effectiveSolvencyAssets;
        preview.triggersDegradedMode = !degradedMode && effectiveAssetsAfter < maxLiabilityAfter;
    }

    function _previewFundingSettlement(
        CfdTypes.Position memory pos
    ) internal view returns (int256 pendingFunding, uint256 unsettledFundingDebt, uint256 marginAfterFunding) {
        pendingFunding = getPendingFunding(pos);
        marginAfterFunding = pos.margin;
        if (pendingFunding >= 0) {
            marginAfterFunding += uint256(pendingFunding);
            return (pendingFunding, 0, marginAfterFunding);
        }

        uint256 loss = uint256(-pendingFunding);
        if (marginAfterFunding < loss) {
            unsettledFundingDebt = loss - marginAfterFunding;
            marginAfterFunding = 0;
        } else {
            marginAfterFunding -= loss;
        }
    }

    function previewLiquidation(
        bytes32 accountId,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (LiquidationPreview memory preview) {
        CfdTypes.Position memory pos = positions[accountId];
        preview.oraclePrice = oraclePrice;
        if (pos.size == 0) {
            return preview;
        }

        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, oraclePrice, CAP_PRICE);
        preview.pnlUsdc = isProfit ? int256(pnlAbs) : -int256(pnlAbs);
        preview.fundingUsdc = getPendingFunding(pos);
        preview.reachableCollateralUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);
        preview.equityUsdc = int256(preview.reachableCollateralUsdc) + preview.fundingUsdc + preview.pnlUsdc;
        uint256 requiredBps = isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps;
        uint256 maintenanceMarginUsdc = (((pos.size * oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE) * requiredBps) / 10_000;
        preview.liquidatable = preview.equityUsdc <= int256(maintenanceMarginUsdc);

        uint256 posMargin = pos.margin;
        uint256 notionalUsdc = (pos.size * oraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bounty = (notionalUsdc * riskParams.bountyBps) / 10_000;
        if (bounty < riskParams.minBountyUsdc) {
            bounty = riskParams.minBountyUsdc;
        }
        if (preview.equityUsdc > 0 && bounty > uint256(preview.equityUsdc)) {
            bounty = uint256(preview.equityUsdc);
        } else if (preview.equityUsdc <= 0 && bounty > posMargin) {
            bounty = posMargin;
        }
        preview.keeperBountyUsdc = bounty;

        CfdEngineSettlementLib.LiquidationSettlementResult memory result =
            CfdEngineSettlementLib.liquidationSettlementResult(
                preview.reachableCollateralUsdc, preview.equityUsdc - int256(bounty)
            );
        preview.seizedCollateralUsdc = result.seizedUsdc;
        preview.immediatePayoutUsdc = result.payoutUsdc;
        preview.badDebtUsdc = result.badDebtUsdc;

        uint256 maxLiabilityAfter = viewDataMaxLiabilityAfterClose(pos.side, pos.maxProfitUsdc);
        uint256 effectiveAssetsAfter = _buildAdjustedSolvencySnapshot().effectiveSolvencyAssets;
        preview.triggersDegradedMode = !degradedMode && effectiveAssetsAfter < maxLiabilityAfter;
        vaultDepthUsdc;
    }

    function viewDataMaxLiabilityAfterClose(
        CfdTypes.Side side,
        uint256 maxProfitReduction
    ) internal view returns (uint256) {
        uint256 bullMax = globalBullMaxProfit;
        uint256 bearMax = globalBearMaxProfit;
        if (side == CfdTypes.Side.BULL) {
            bullMax -= maxProfitReduction;
        } else {
            bearMax -= maxProfitReduction;
        }
        return bullMax > bearMax ? bullMax : bearMax;
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
        return _liquidatePosition(accountId, currentOraclePrice, vaultDepthUsdc, publishTime);
    }

    function _liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) internal returns (uint256 keeperBountyUsdc) {
        uint256 price = currentOraclePrice > CAP_PRICE ? CAP_PRICE : currentOraclePrice;
        _updateFunding(lastMarkPrice, vaultDepthUsdc);
        _cacheMarkPriceIfNewer(price, publishTime);

        CfdTypes.Position storage pos = positions[accountId];
        if (pos.size == 0) {
            revert CfdEngine__NoPositionToLiquidate();
        }

        int256 pendingFunding = getPendingFunding(pos);
        if (pos.side == CfdTypes.Side.BULL) {
            globalBullEntryFunding -= int256(pos.size) * pos.entryFundingIndex;
        } else {
            globalBearEntryFunding -= int256(pos.size) * pos.entryFundingIndex;
        }

        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, CAP_PRICE);

        uint256 reachableUsdc = clearinghouse.getLiquidationReachableUsdc(accountId, pos.margin);

        int256 equityUsdc = int256(reachableUsdc) + pendingFunding;
        equityUsdc = isProfit ? equityUsdc + int256(pnlAbs) : equityUsdc - int256(pnlAbs);

        uint256 mmUsdc = getMaintenanceMarginUsdc(pos.size, price);
        if (equityUsdc >= int256(mmUsdc)) {
            revert CfdEngine__PositionIsSolvent();
        }

        _reduceGlobalLiability(pos.side, pos.maxProfitUsdc, pos.size);

        uint256 liqEntryNotional = pos.size * pos.entryPrice;
        if (pos.side == CfdTypes.Side.BULL) {
            globalBullEntryNotional -= liqEntryNotional;
        } else {
            globalBearEntryNotional -= liqEntryNotional;
        }

        CfdTypes.RiskParams memory rp = riskParams;

        uint256 notionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        keeperBountyUsdc = (notionalUsdc * rp.bountyBps) / 10_000;
        if (keeperBountyUsdc < rp.minBountyUsdc) {
            keeperBountyUsdc = rp.minBountyUsdc;
        }
        uint256 posMargin = pos.margin;
        if (equityUsdc > 0 && keeperBountyUsdc > uint256(equityUsdc)) {
            keeperBountyUsdc = uint256(equityUsdc);
        } else if (equityUsdc <= 0) {
            if (keeperBountyUsdc > posMargin) {
                keeperBountyUsdc = posMargin;
            }
        }
        int256 residual = equityUsdc - int256(keeperBountyUsdc);
        CfdEngineSettlementLib.LiquidationSettlementResult memory settlement =
            _settleLiquidationResidual(accountId, posMargin, residual);
        accumulatedBadDebtUsdc += settlement.badDebtUsdc;

        if (pos.side == CfdTypes.Side.BULL) {
            totalBullMargin -= posMargin;
        } else {
            totalBearMargin -= posMargin;
        }

        emit PositionLiquidated(accountId, pos.side, pos.size, price, keeperBountyUsdc);
        delete positions[accountId];
        _enterDegradedModeIfInsolvent(accountId, keeperBountyUsdc);
    }

    function _assertPostSolvency() internal view {
        CfdEngineSnapshotsLib.SolvencySnapshot memory snapshot = _buildAdjustedSolvencySnapshot();
        if (snapshot.effectiveSolvencyAssets < snapshot.maxLiability) {
            revert CfdEngine__PostOpSolvencyBreach();
        }
    }

    function _maxLiability() internal view returns (uint256) {
        return globalBullMaxProfit > globalBearMaxProfit ? globalBullMaxProfit : globalBearMaxProfit;
    }

    function _getWithdrawalReservedUsdc() internal view returns (uint256 reservedUsdc) {
        return CfdEngineSnapshotsLib.getWithdrawalReservedUsdc(
            _maxLiability(), accumulatedFeesUsdc, _getLiabilityOnlyFundingPnl()
        ) + totalDeferredPayoutUsdc + totalDeferredLiquidationBountyUsdc;
    }

    function _buildAdjustedSolvencySnapshot()
        internal
        view
        returns (CfdEngineSnapshotsLib.SolvencySnapshot memory snapshot)
    {
        snapshot = CfdEngineSnapshotsLib.buildSolvencySnapshot(
            vault.totalAssets(), accumulatedFeesUsdc, _maxLiability(), _buildFundingSnapshot()
        );
        if (totalDeferredPayoutUsdc > 0) {
            snapshot.effectiveSolvencyAssets = snapshot.effectiveSolvencyAssets > totalDeferredPayoutUsdc
                ? snapshot.effectiveSolvencyAssets - totalDeferredPayoutUsdc
                : 0;
        }
        if (totalDeferredLiquidationBountyUsdc > 0) {
            snapshot.effectiveSolvencyAssets = snapshot.effectiveSolvencyAssets > totalDeferredLiquidationBountyUsdc
                ? snapshot.effectiveSolvencyAssets - totalDeferredLiquidationBountyUsdc
                : 0;
        }
    }

    function _enterDegradedModeIfInsolvent(
        bytes32 accountId,
        uint256 pendingVaultPayoutUsdc
    ) internal {
        if (degradedMode) {
            return;
        }
        CfdEngineSnapshotsLib.SolvencySnapshot memory snapshot = _buildAdjustedSolvencySnapshot();
        if (pendingVaultPayoutUsdc > 0) {
            snapshot.effectiveSolvencyAssets = snapshot.effectiveSolvencyAssets > pendingVaultPayoutUsdc
                ? snapshot.effectiveSolvencyAssets - pendingVaultPayoutUsdc
                : 0;
        }
        if (snapshot.effectiveSolvencyAssets < snapshot.maxLiability) {
            degradedMode = true;
            emit DegradedModeEntered(snapshot.effectiveSolvencyAssets, snapshot.maxLiability, accountId);
        }
    }

    function _computeGlobalFundingPnl() internal view returns (int256 bullFunding, int256 bearFunding) {
        bullFunding = (int256(bullOI) * bullFundingIndex - globalBullEntryFunding) / int256(CfdMath.FUNDING_INDEX_SCALE);
        bearFunding = (int256(bearOI) * bearFundingIndex - globalBearEntryFunding) / int256(CfdMath.FUNDING_INDEX_SCALE);
    }

    function _buildFundingSnapshot() internal view returns (CfdEngineSnapshotsLib.FundingSnapshot memory snapshot) {
        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();
        return CfdEngineSnapshotsLib.buildFundingSnapshot(bullFunding, bearFunding, totalBullMargin, totalBearMargin);
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
        _updateFunding(lastMarkPrice, vault.totalAssets());
        lastMarkPrice = clamped;
        lastMarkTime = publishTime;
    }

    function _cacheMarkPriceIfNewer(
        uint256 price,
        uint64 publishTime
    ) internal {
        if (publishTime >= lastMarkTime) {
            lastMarkPrice = price;
            lastMarkTime = publishTime;
        }
    }

    /// @notice Returns true when the protocol still has live bounded directional liability.
    function hasLiveLiability() external view returns (bool) {
        return globalBullMaxProfit + globalBearMaxProfit > 0;
    }

    function _seizeUsdcToVault(
        bytes32 accountId,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }
        clearinghouse.seizeAsset(accountId, address(USDC), amount, address(this));
        USDC.safeTransfer(address(vault), amount);
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

        int256 bullPnl = int256(globalBullEntryNotional) - int256(bullOI * price);
        int256 bearPnl = int256(bearOI * price) - int256(globalBearEntryNotional);

        return (bullPnl + bearPnl) / int256(CfdMath.USDC_TO_TOKEN_SCALE);
    }

    /// @notice Combined MtM: per-side (PnL + funding), clamped at zero.
    ///         Positive = vault owes traders (unrealized liability). Zero = traders losing or neutral.
    ///         The vault never counts unrealized trader losses as assets — realized losses flow
    ///         through physical USDC transfers (settlements, liquidations).
    /// @return Net MtM adjustment the vault must reserve (always >= 0), in USDC (6 decimals)
    function getVaultMtmAdjustment() external view returns (int256) {
        uint256 price = lastMarkPrice;

        int256 bullPnl;
        int256 bearPnl;
        if (price > 0) {
            bullPnl = (int256(globalBullEntryNotional) - int256(bullOI * price)) / int256(CfdMath.USDC_TO_TOKEN_SCALE);
            bearPnl = (int256(bearOI * price) - int256(globalBearEntryNotional)) / int256(CfdMath.USDC_TO_TOKEN_SCALE);
        }

        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();

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
