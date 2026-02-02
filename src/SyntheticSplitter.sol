// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SyntheticToken} from "./SyntheticToken.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/// @title SyntheticSplitter
/// @custom:security-contact contact@plether.com
/// @notice Core protocol contract for minting/burning synthetic plDXY tokens.
/// @dev Accepts USDC collateral to mint equal amounts of plDXY-BEAR + plDXY-BULL tokens.
///      Maintains 10% liquidity buffer locally, 90% deployed to yield adapters.
///      Three lifecycle states: ACTIVE → PAUSED → SETTLED (liquidated).
contract SyntheticSplitter is ISyntheticSplitter, Ownable2Step, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ==========================================
    // STATE
    // ==========================================

    // Assets
    SyntheticToken public immutable BEAR;
    SyntheticToken public immutable BULL;
    IERC20 public immutable USDC;

    // Logic
    AggregatorV3Interface public immutable ORACLE;
    uint256 public immutable CAP;
    uint256 private constant USDC_DECIMALS = 6;
    uint256 public constant USDC_MULTIPLIER = 10 ** (18 + 8 - USDC_DECIMALS);
    uint256 public constant BUFFER_PERCENT = 10;

    // The Bank
    IERC4626 public yieldAdapter;

    // Governance: Adapter Migration
    address public pendingAdapter;
    uint256 public adapterActivationTime;

    // Governance: Fee Receivers
    address public treasury;
    address public staking;

    struct FeeConfig {
        address treasuryAddr;
        address stakingAddr;
    }
    FeeConfig public pendingFees;
    uint256 public feesActivationTime;

    uint256 public constant ORACLE_TIMEOUT = 24 hours;
    uint256 public constant TIMELOCK_DELAY = 7 days;
    uint256 public lastUnpauseTime;

    uint256 public constant HARVEST_REWARD_BPS = 10;
    uint256 public constant MIN_SURPLUS_THRESHOLD = 50 * 10 ** USDC_DECIMALS;

    // Liquidation State
    bool public isLiquidated;

    // Sequencer Feed
    AggregatorV3Interface public immutable SEQUENCER_UPTIME_FEED;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    // Events
    event Minted(address indexed user, uint256 amount);
    event Burned(address indexed user, uint256 amount);
    event AdapterProposed(address indexed newAdapter, uint256 activationTime);
    event AdapterMigrated(address indexed oldAdapter, address indexed newAdapter, uint256 transferredAmount);
    event LiquidationTriggered(uint256 price);
    event EmergencyRedeemed(address indexed user, uint256 amount);
    event YieldHarvested(uint256 totalSurplus, uint256 treasuryAmt, uint256 stakingAmt);
    event FeesProposed(address indexed treasury, address indexed staking, uint256 activationTime);
    event FeesUpdated(address indexed treasury, address indexed staking);
    event EmergencyEjected(uint256 amountRecovered);
    event AdapterWithdrawn(uint256 requested, uint256 withdrawn);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    error Splitter__ZeroAddress();
    error Splitter__InvalidCap();
    error Splitter__ZeroAmount();
    error Splitter__ZeroRefund();
    error Splitter__AdapterNotSet();
    error Splitter__AdapterInsufficientLiquidity();
    error Splitter__LiquidationActive();
    error Splitter__NotLiquidated();
    error Splitter__TimelockActive();
    error Splitter__InvalidProposal();
    error Splitter__NoSurplus();
    error Splitter__GovernanceLocked();
    error Splitter__InsufficientHarvest();
    error Splitter__AdapterWithdrawFailed();
    error Splitter__Insolvent();
    error Splitter__NotPaused();
    error Splitter__CannotRescueCoreAsset();
    error Splitter__MigrationLostFunds();
    error Splitter__InvalidAdapter();

    // Structs for Views
    struct SystemStatus {
        uint256 currentPrice;
        uint256 capPrice;
        bool liquidated;
        bool isPaused;
        uint256 totalAssets; // Local + Adapter
        uint256 totalLiabilities; // Bear Supply * CAP
        uint256 collateralRatio; // Basis points
        uint256 adapterAssets; // USDC value held in yield adapter
    }

    /// @notice Deploys the SyntheticSplitter and creates plDXY-BEAR and plDXY-BULL tokens.
    /// @param _oracle Chainlink-compatible price feed for plDXY basket.
    /// @param _usdc USDC token address (6 decimals).
    /// @param _yieldAdapter ERC4626-compliant yield adapter for USDC deposits.
    /// @param _cap Maximum plDXY price (8 decimals). Triggers liquidation when breached.
    /// @param _treasury Treasury address for fee distribution.
    /// @param _sequencerUptimeFeed L2 sequencer uptime feed (address(0) for L1/testnets).
    constructor(
        address _oracle,
        address _usdc,
        address _yieldAdapter,
        uint256 _cap,
        address _treasury,
        address _sequencerUptimeFeed
    ) Ownable(msg.sender) {
        if (_oracle == address(0)) {
            revert Splitter__ZeroAddress();
        }
        if (_usdc == address(0)) {
            revert Splitter__ZeroAddress();
        }
        if (_yieldAdapter == address(0)) {
            revert Splitter__ZeroAddress();
        }
        if (_cap == 0) {
            revert Splitter__InvalidCap();
        }
        if (_treasury == address(0)) {
            revert Splitter__ZeroAddress();
        }

        ORACLE = AggregatorV3Interface(_oracle);
        USDC = IERC20(_usdc);
        yieldAdapter = IERC4626(_yieldAdapter);
        CAP = _cap;
        treasury = _treasury;
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(_sequencerUptimeFeed);

        BEAR = new SyntheticToken("Plether Dollar Index Bear", "plDXY-BEAR", address(this));
        BULL = new SyntheticToken("Plether Dollar Index Bull", "plDXY-BULL", address(this));
    }

    // ==========================================
    // 1. MINTING (With Buffer)
    // ==========================================

    /**
     * @notice Simulates a mint to see required USDC input
     * @param mintAmount The amount of TokenA/B the user wants to mint
     * @return usdcRequired Total USDC needed from user
     * @return depositToAdapter Amount that will be sent to Yield Source
     * @return keptInBuffer Amount that will stay in Splitter contract
     */
    function previewMint(
        uint256 mintAmount
    ) external view returns (uint256 usdcRequired, uint256 depositToAdapter, uint256 keptInBuffer) {
        if (mintAmount == 0) {
            return (0, 0, 0);
        }
        if (isLiquidated) {
            revert Splitter__LiquidationActive();
        }

        // Check Oracle Price to fail fast if over CAP
        uint256 price = _getOraclePrice();
        if (price >= CAP) {
            revert Splitter__LiquidationActive();
        }

        // Calculate USDC required (round UP to favor protocol)
        usdcRequired = Math.mulDiv(mintAmount, CAP, USDC_MULTIPLIER, Math.Rounding.Ceil);

        // Calculate Buffer Split
        keptInBuffer = (usdcRequired * BUFFER_PERCENT) / 100;
        depositToAdapter = usdcRequired - keptInBuffer;
    }

    /// @notice Mint plDXY-BEAR and plDXY-BULL tokens by depositing USDC collateral.
    /// @param amount The amount of token pairs to mint (18 decimals).
    function mint(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (amount == 0) {
            revert Splitter__ZeroAmount();
        }
        if (isLiquidated) {
            revert Splitter__LiquidationActive();
        }
        if (address(yieldAdapter) == address(0)) {
            revert Splitter__AdapterNotSet();
        }

        uint256 price = _getOraclePrice();
        if (price >= CAP) {
            revert Splitter__LiquidationActive();
        }

        uint256 usdcNeeded = Math.mulDiv(amount, CAP, USDC_MULTIPLIER, Math.Rounding.Ceil);
        if (usdcNeeded == 0) {
            revert Splitter__ZeroAmount();
        }

        USDC.safeTransferFrom(msg.sender, address(this), usdcNeeded);

        uint256 keepAmount = (usdcNeeded * BUFFER_PERCENT) / 100;
        uint256 depositAmount = usdcNeeded - keepAmount;

        if (depositAmount > 0) {
            USDC.forceApprove(address(yieldAdapter), depositAmount);
            yieldAdapter.deposit(depositAmount, address(this));
        }

        BEAR.mint(msg.sender, amount);
        BULL.mint(msg.sender, amount);

        emit Minted(msg.sender, amount);
    }

    // ==========================================
    // 2. BURNING (Smart Withdrawal)
    // ==========================================

    /**
     * @notice Simulates a burn to see USDC return
     * @param burnAmount The amount of TokenA/B the user wants to burn
     * @return usdcRefund Total USDC user will receive
     * @return withdrawnFromAdapter Amount pulled from Yield Source to cover shortage
     */
    function previewBurn(
        uint256 burnAmount
    ) external view returns (uint256 usdcRefund, uint256 withdrawnFromAdapter) {
        if (burnAmount == 0) {
            return (0, 0);
        }

        // 1. Solvency Check (Simulates the paused logic)
        _requireSolventIfPaused();

        // 2. Calculate Refund
        usdcRefund = (burnAmount * CAP) / USDC_MULTIPLIER;
        if (usdcRefund == 0) {
            revert Splitter__ZeroRefund();
        }

        // 3. Calculate Liquidity Source
        uint256 localBalance = USDC.balanceOf(address(this));

        if (localBalance < usdcRefund) {
            withdrawnFromAdapter = usdcRefund - localBalance;

            // Optional: Check if adapter actually has this liquidity
            // logical constraint to warn frontend if withdrawal will fail
            uint256 maxWithdraw = yieldAdapter.maxWithdraw(address(this));
            if (maxWithdraw < withdrawnFromAdapter) {
                revert Splitter__AdapterInsufficientLiquidity();
            }
        } else {
            withdrawnFromAdapter = 0;
        }
    }

    /// @notice Burn plDXY-BEAR and plDXY-BULL tokens to redeem USDC collateral.
    /// @param amount The amount of token pairs to burn (18 decimals).
    function burn(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) {
            revert Splitter__ZeroAmount();
        }

        // If paused, enforce 100% solvency to prevent race to exit
        _requireSolventIfPaused();

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;
        if (usdcRefund == 0) {
            revert Splitter__ZeroRefund();
        }

        // 1. Check Local Buffer First
        uint256 localBalance = USDC.balanceOf(address(this));

        if (localBalance < usdcRefund) {
            uint256 shortage = usdcRefund - localBalance;
            // Check adapter just in case (though solvency check handles this usually)
            if (address(yieldAdapter) == address(0)) {
                revert Splitter__AdapterNotSet();
            }

            // Try withdraw first, fall back to redeem if it fails
            _withdrawFromAdapter(shortage);
        }

        // 2. Transfer USDC to user BEFORE burning tokens
        // This ensures tokens aren't burned if USDC transfer fails
        USDC.safeTransfer(msg.sender, usdcRefund);

        // 3. Burn tokens AFTER successful USDC transfer
        BEAR.burn(msg.sender, amount);
        BULL.burn(msg.sender, amount);

        emit Burned(msg.sender, amount);
    }

    /// @dev Withdraws USDC from yield adapter with redeem fallback.
    /// @param amount USDC amount to withdraw (6 decimals).
    function _withdrawFromAdapter(
        uint256 amount
    ) internal {
        try yieldAdapter.withdraw(amount, address(this), address(this)) {
        // Success via withdraw
        }
        catch {
            uint256 sharesToRedeem = yieldAdapter.convertToShares(amount);
            if (sharesToRedeem > 0) {
                uint256 maxShares = yieldAdapter.maxRedeem(address(this));
                sharesToRedeem = sharesToRedeem + 1 > maxShares ? maxShares : sharesToRedeem + 1;
            }
            try yieldAdapter.redeem(sharesToRedeem, address(this), address(this)) {}
            catch {
                revert Splitter__AdapterWithdrawFailed();
            }
        }
    }

    // ==========================================
    // 3. LIQUIDATION & EMERGENCY
    // ==========================================

    /// @notice Locks the protocol into liquidated state when price >= CAP.
    /// @dev Permissionless. Prevents system revival if price drops after breach.
    function triggerLiquidation() external nonReentrant {
        uint256 price = _getOraclePrice();
        if (price < CAP) {
            revert Splitter__NotLiquidated();
        }
        if (isLiquidated) {
            revert Splitter__LiquidationActive();
        }

        isLiquidated = true;
        emit LiquidationTriggered(price);
    }

    /// @notice Emergency redemption when protocol is liquidated (price >= CAP).
    /// @dev Only burns plDXY-BEAR tokens at CAP price. plDXY-BULL becomes worthless.
    /// @param amount The amount of plDXY-BEAR tokens to redeem (18 decimals).
    function emergencyRedeem(
        uint256 amount
    ) external nonReentrant {
        if (!isLiquidated) {
            uint256 price = _getOraclePrice();
            if (price >= CAP) {
                isLiquidated = true;
                emit LiquidationTriggered(price);
            } else {
                revert Splitter__NotLiquidated();
            }
        }
        if (amount == 0) {
            revert Splitter__ZeroAmount();
        }

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;
        if (usdcRefund == 0) {
            revert Splitter__ZeroRefund();
        }

        uint256 localBalance = USDC.balanceOf(address(this));
        if (localBalance < usdcRefund) {
            uint256 shortage = usdcRefund - localBalance;
            _withdrawFromAdapter(shortage);
        }

        USDC.safeTransfer(msg.sender, usdcRefund);
        BEAR.burn(msg.sender, amount);

        emit EmergencyRedeemed(msg.sender, amount);
    }

    /// @notice Emergency exit: withdraws all funds from yield adapter.
    /// @dev Bypasses timelock. Auto-pauses protocol. Use if adapter is compromised.
    function ejectLiquidity() external onlyOwner {
        if (address(yieldAdapter) == address(0)) {
            revert Splitter__AdapterNotSet();
        }

        uint256 shares = yieldAdapter.balanceOf(address(this));
        uint256 recovered = 0;

        if (shares > 0) {
            // Redeem Everything -> USDC moves to Splitter
            recovered = yieldAdapter.redeem(shares, address(this), address(this));
        }

        // Auto-pause to prevent new deposits into broken adapter
        _pause();

        emit EmergencyEjected(recovered);
    }

    /// @notice Withdraws a specific amount from yield adapter while paused.
    /// @dev Requires protocol to be paused. Use for gradual liquidity extraction
    ///      when full ejectLiquidity() fails due to adapter liquidity constraints.
    /// @param amount Desired USDC amount to withdraw. Capped by adapter's maxWithdraw.
    function withdrawFromAdapter(
        uint256 amount
    ) external nonReentrant onlyOwner {
        if (!paused()) {
            revert Splitter__NotPaused();
        }
        if (address(yieldAdapter) == address(0)) {
            revert Splitter__AdapterNotSet();
        }
        if (amount == 0) {
            revert Splitter__ZeroAmount();
        }

        uint256 maxAvailable = yieldAdapter.maxWithdraw(address(this));
        uint256 toWithdraw = amount > maxAvailable ? maxAvailable : amount;

        if (toWithdraw > 0) {
            yieldAdapter.withdraw(toWithdraw, address(this), address(this));
        }

        emit AdapterWithdrawn(amount, toWithdraw);
    }

    // ==========================================
    // 4. HARVEST (Permissionless)
    // ==========================================

    /// @notice Previews yield harvest amounts and eligibility.
    /// @return canHarvest True if surplus exceeds MIN_SURPLUS_THRESHOLD.
    /// @return totalSurplus Available surplus (total assets - liabilities).
    /// @return callerReward Caller incentive (0.1% of harvest).
    /// @return treasuryShare Treasury allocation (20% of remaining).
    /// @return stakingShare Staking allocation (79.9% of remaining).
    function previewHarvest()
        external
        view
        returns (
            bool canHarvest,
            uint256 totalSurplus,
            uint256 callerReward,
            uint256 treasuryShare,
            uint256 stakingShare
        )
    {
        if (address(yieldAdapter) == address(0)) {
            return (false, 0, 0, 0, 0);
        }

        // 1. Calculate Total Holdings
        uint256 myShares = yieldAdapter.balanceOf(address(this));
        uint256 adapterAssets = yieldAdapter.convertToAssets(myShares);
        uint256 localBuffer = USDC.balanceOf(address(this));
        uint256 totalHoldings = adapterAssets + localBuffer;

        // 2. Calculate Liabilities
        uint256 requiredBacking = (BEAR.totalSupply() * CAP) / USDC_MULTIPLIER;

        // 3. Determine Surplus
        if (totalHoldings > requiredBacking) {
            totalSurplus = totalHoldings - requiredBacking;
        } else {
            return (false, 0, 0, 0, 0);
        }

        if (totalSurplus < MIN_SURPLUS_THRESHOLD) {
            return (false, totalSurplus, 0, 0, 0);
        }

        // 4. Calculate Splits
        // Note: The actual harvest logic limits withdrawal to `adapterAssets` if surplus > adapterAssets.
        uint256 harvestableAmount = (adapterAssets > totalSurplus) ? totalSurplus : adapterAssets;

        callerReward = (harvestableAmount * HARVEST_REWARD_BPS) / 10_000;
        uint256 remaining = harvestableAmount - callerReward;
        treasuryShare = (remaining * 20) / 100;
        stakingShare = remaining - treasuryShare;

        canHarvest = true;
    }

    /// @notice Permissionless yield harvesting from the adapter.
    /// @dev Distributes surplus: 0.1% to caller, 20% to treasury, 79.9% to staking.
    function harvestYield() external nonReentrant whenNotPaused {
        if (address(yieldAdapter) == address(0)) {
            revert Splitter__AdapterNotSet();
        }

        // Poke adapter to accrue pending interest before calculating surplus
        // This ensures totalAssets() returns actual (not expected) values
        try IYieldAdapter(address(yieldAdapter)).accrueInterest() {} catch {}

        uint256 myShares = yieldAdapter.balanceOf(address(this));
        uint256 adapterAssets = yieldAdapter.convertToAssets(myShares);
        uint256 localBuffer = USDC.balanceOf(address(this));
        uint256 totalHoldings = adapterAssets + localBuffer;

        uint256 requiredBacking = (BEAR.totalSupply() * CAP) / USDC_MULTIPLIER;

        if (totalHoldings <= requiredBacking + MIN_SURPLUS_THRESHOLD) {
            revert Splitter__NoSurplus();
        }

        uint256 surplus = totalHoldings - requiredBacking;

        // Withdraw from adapter
        uint256 expectedPull = adapterAssets > surplus ? surplus : adapterAssets;
        uint256 balanceBefore = USDC.balanceOf(address(this));
        if (adapterAssets > surplus) {
            yieldAdapter.withdraw(surplus, address(this), address(this));
        } else {
            yieldAdapter.redeem(myShares, address(this), address(this));
        }
        uint256 harvested = USDC.balanceOf(address(this)) - balanceBefore;

        // Safety check: Ensure we got at least 90% of expected (adjust threshold as needed)
        if (harvested < (expectedPull * 90) / 100) {
            revert Splitter__InsufficientHarvest();
        }

        // Distribute based on actual harvested
        uint256 callerCut = (harvested * HARVEST_REWARD_BPS) / 10_000;
        uint256 remaining = harvested - callerCut;
        uint256 treasuryShare = (remaining * 20) / 100;
        uint256 stakingShare = remaining - treasuryShare;

        emit YieldHarvested(harvested, treasuryShare, stakingShare);

        // Transfers (CEI: All calcs done before interactions)
        if (callerCut > 0) {
            USDC.safeTransfer(msg.sender, callerCut);
        }
        USDC.safeTransfer(treasury, treasuryShare);
        if (staking != address(0)) {
            USDC.safeTransfer(staking, stakingShare);
        } else {
            USDC.safeTransfer(treasury, stakingShare);
        }
    }

    // ==========================================
    // 5. GOVERNANCE
    // ==========================================

    /// @dev Enforces 7-day cooldown after unpause for governance actions.
    function _checkLiveness() internal view {
        if (paused()) {
            revert Splitter__GovernanceLocked();
        }
        // Using TIMELOCK_DELAY (7 days) as the Cooldown
        if (block.timestamp < lastUnpauseTime + TIMELOCK_DELAY) {
            revert Splitter__GovernanceLocked();
        }
    }

    /// @notice Propose new fee receiver addresses (7-day timelock).
    /// @param _treasury New treasury address.
    /// @param _staking New staking address (can be zero to send all to treasury).
    function proposeFeeReceivers(
        address _treasury,
        address _staking
    ) external onlyOwner {
        if (_treasury == address(0)) {
            revert Splitter__ZeroAddress();
        }
        pendingFees = FeeConfig(_treasury, _staking);
        feesActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FeesProposed(_treasury, _staking, feesActivationTime);
    }

    /// @notice Finalize pending fee receiver change after timelock expires.
    function finalizeFeeReceivers() external onlyOwner {
        if (feesActivationTime == 0) {
            revert Splitter__InvalidProposal();
        }
        if (block.timestamp < feesActivationTime) {
            revert Splitter__TimelockActive();
        }

        _checkLiveness();

        treasury = pendingFees.treasuryAddr;
        staking = pendingFees.stakingAddr;

        delete pendingFees;
        feesActivationTime = 0;
        emit FeesUpdated(treasury, staking);
    }

    /// @notice Propose a new yield adapter (7-day timelock).
    /// @param _newAdapter Address of the new ERC4626-compliant adapter.
    function proposeAdapter(
        address _newAdapter
    ) external onlyOwner {
        if (_newAdapter == address(0)) {
            revert Splitter__ZeroAddress();
        }
        if (IERC4626(_newAdapter).asset() != address(USDC)) {
            revert Splitter__InvalidAdapter();
        }
        pendingAdapter = _newAdapter;
        adapterActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit AdapterProposed(_newAdapter, adapterActivationTime);
    }

    /// @notice Finalize adapter migration after timelock. Migrates all funds atomically.
    function finalizeAdapter() external nonReentrant onlyOwner {
        if (pendingAdapter == address(0)) {
            revert Splitter__InvalidProposal();
        }
        if (block.timestamp < adapterActivationTime) {
            revert Splitter__TimelockActive();
        }

        _checkLiveness();

        uint256 assetsBefore = _getTotalAssets();

        IERC4626 oldAdapter = yieldAdapter;
        IERC4626 newAdapter = IERC4626(pendingAdapter);

        uint256 movedAmount = 0;
        if (address(oldAdapter) != address(0)) {
            uint256 shares = oldAdapter.balanceOf(address(this));
            if (shares > 0) {
                movedAmount = oldAdapter.redeem(shares, address(this), address(this));
            }
        }
        if (movedAmount > 0) {
            USDC.forceApprove(address(newAdapter), movedAmount);
            newAdapter.deposit(movedAmount, address(this));
        }

        yieldAdapter = newAdapter;

        uint256 assetsAfter = _getTotalAssets();
        if (assetsAfter < (assetsBefore * 99_999) / 100_000) {
            revert Splitter__MigrationLostFunds();
        }

        pendingAdapter = address(0);
        adapterActivationTime = 0;
        emit AdapterMigrated(address(oldAdapter), address(newAdapter), movedAmount);
    }

    // ==========================================
    // ADMIN HELPERS
    // ==========================================

    /// @notice Pause the protocol. Blocks minting and harvesting.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the protocol. Starts 7-day governance cooldown.
    function unpause() external onlyOwner {
        lastUnpauseTime = block.timestamp; // START 7 DAY COUNTDOWN
        _unpause();
    }

    /// @notice Rescue accidentally sent tokens. Cannot rescue core assets.
    /// @param token The ERC20 token to rescue.
    /// @param to The recipient address.
    function rescueToken(
        address token,
        address to
    ) external onlyOwner {
        if (
            token == address(USDC) || token == address(BEAR) || token == address(BULL) || token == address(yieldAdapter)
        ) {
            revert Splitter__CannotRescueCoreAsset();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
        emit TokenRescued(token, to, balance);
    }

    // ==========================================
    // VIEW HELPERS (DASHBOARD)
    // ==========================================

    /**
     * @notice Returns the current protocol lifecycle status.
     * @return The current Status enum value (ACTIVE, PAUSED, or SETTLED).
     */
    function currentStatus() external view override returns (Status) {
        if (isLiquidated) {
            return Status.SETTLED;
        }
        if (paused()) {
            return Status.PAUSED;
        }
        return Status.ACTIVE;
    }

    /// @notice Returns comprehensive system metrics for dashboards.
    /// @return status Struct containing price, collateral ratio, and liquidity data.
    function getSystemStatus() external view returns (SystemStatus memory status) {
        status.capPrice = CAP;
        status.liquidated = isLiquidated;
        status.isPaused = paused();

        // Price might revert if sequencer is down, handle gracefully in UI,
        // but here we try-catch or just call internal (view will revert entire call)
        try ORACLE.latestRoundData() returns (uint80, int256 price, uint256, uint256, uint80) {
            status.currentPrice = price > 0 ? uint256(price) : 0;
        } catch {
            status.currentPrice = 0; // Indicate error
        }

        // Assets/Liabilities
        status.totalAssets = _getTotalAssets();
        status.totalLiabilities = _getTotalLiabilities();

        if (status.totalLiabilities > 0) {
            status.collateralRatio = (status.totalAssets * 1e4) / status.totalLiabilities;
        } else {
            status.collateralRatio = 0; // Infinite/Unset
        }

        // Adapter assets for UI APY calculation
        if (address(yieldAdapter) != address(0)) {
            uint256 myShares = yieldAdapter.balanceOf(address(this));
            status.adapterAssets = yieldAdapter.convertToAssets(myShares);
        }
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    /// @dev Calculates total liabilities based on BEAR supply at CAP price.
    function _getTotalLiabilities() internal view returns (uint256) {
        return (BEAR.totalSupply() * CAP) / USDC_MULTIPLIER;
    }

    /// @dev Calculates total assets (local USDC + adapter value).
    function _getTotalAssets() internal view returns (uint256) {
        uint256 adapterValue = 0;
        if (address(yieldAdapter) != address(0)) {
            uint256 myShares = yieldAdapter.balanceOf(address(this));
            adapterValue = yieldAdapter.convertToAssets(myShares);
        }
        return USDC.balanceOf(address(this)) + adapterValue;
    }

    /// @dev Reverts if paused and insolvent (assets < liabilities).
    function _requireSolventIfPaused() internal view {
        if (paused()) {
            uint256 totalAssets = _getTotalAssets();
            uint256 totalLiabilities = _getTotalLiabilities();
            if (totalAssets < totalLiabilities) {
                revert Splitter__Insolvent();
            }
        }
    }

    /// @dev Oracle price validation using OracleLib.
    function _getOraclePrice() internal view returns (uint256) {
        return OracleLib.getValidatedPrice(ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);
    }

}
