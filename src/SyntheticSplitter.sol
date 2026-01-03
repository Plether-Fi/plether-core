// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {SyntheticToken} from "./SyntheticToken.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract SyntheticSplitter is ISyntheticSplitter, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==========================================
    // STATE
    // ==========================================

    // Assets
    SyntheticToken public immutable TOKEN_A; // Bear
    SyntheticToken public immutable TOKEN_B; // Bull
    IERC20 public immutable USDC;

    // Logic
    AggregatorV3Interface public immutable ORACLE;
    uint256 public immutable CAP;
    uint256 public immutable USDC_MULTIPLIER; // Cached math scaler
    uint256 public constant BUFFER_PERCENT = 10; // Keep 10% liquid in Splitter

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

    uint256 public constant ORACLE_TIMEOUT = 8 hours;
    uint256 public constant TIMELOCK_DELAY = 7 days;
    uint256 public lastUnpauseTime;

    uint256 public constant HARVEST_REWARD_PERCENT = 1;
    uint256 public constant MIN_SURPLUS_THRESHOLD = 50 * 1e6;

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
    event FeesProposed(address treasury, address staking, uint256 activationTime);
    event FeesUpdated(address treasury, address staking);
    event EmergencyEjected(uint256 amountRecovered);

    // Errors
    error Splitter__ZeroAmount();
    error Splitter__ZeroRefund();
    error Splitter__AdapterNotSet();
    error Splitter__LiquidationActive();
    error Splitter__NotLiquidated();
    error Splitter__TimelockActive();
    error Splitter__InvalidProposal();
    error Splitter__NoSurplus();
    error Splitter__GovernanceLocked();
    error Splitter__InsufficientHarvest();
    error Splitter__AdapterWithdrawFailed();

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

    constructor(
        address _oracle,
        address _usdc,
        address _yieldAdapter,
        uint256 _cap,
        address _treasury,
        address _sequencerUptimeFeed
    ) Ownable(msg.sender) {
        require(_oracle != address(0), "Invalid Oracle");
        require(_usdc != address(0), "Invalid USDC");
        require(_yieldAdapter != address(0), "Invalid Adapter");
        require(_cap > 0, "Invalid Cap");
        require(_treasury != address(0), "Invalid Treasury");

        ORACLE = AggregatorV3Interface(_oracle);
        USDC = IERC20(_usdc);
        yieldAdapter = IERC4626(_yieldAdapter);
        CAP = _cap;
        treasury = _treasury;
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(_sequencerUptimeFeed);

        TOKEN_A = new SyntheticToken("Bear DXY", "plDXY-BEAR", address(this));
        TOKEN_B = new SyntheticToken("Bull DXY", "plDXY-BULL", address(this));

        // OPTIMIZATION: Calculate scaler ONCE
        uint256 decimals = ERC20(_usdc).decimals();
        USDC_MULTIPLIER = 10 ** (18 + 8 - decimals);
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
    function previewMint(uint256 mintAmount)
        external
        view
        returns (uint256 usdcRequired, uint256 depositToAdapter, uint256 keptInBuffer)
    {
        if (mintAmount == 0) return (0, 0, 0);
        if (isLiquidated) revert Splitter__LiquidationActive();

        // Check Oracle Price to fail fast if over CAP
        uint256 price = _getOraclePrice();
        if (price >= CAP) revert Splitter__LiquidationActive();

        // Calculate USDC required (round UP to favor protocol)
        usdcRequired = Math.mulDiv(mintAmount, CAP, USDC_MULTIPLIER, Math.Rounding.Ceil);

        // Calculate Buffer Split
        keptInBuffer = (usdcRequired * BUFFER_PERCENT) / 100;
        depositToAdapter = usdcRequired - keptInBuffer;
    }

    function mint(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Splitter__ZeroAmount();
        if (isLiquidated) revert Splitter__LiquidationActive();
        // Check adapter unless we are in emergency mode,
        // but generally we shouldn't mint if no adapter is connected.
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        uint256 price = _getOraclePrice();
        if (price >= CAP) {
            revert Splitter__LiquidationActive();
        }

        // Round UP to favor protocol (prevents rounding exploit)
        uint256 usdcNeeded = Math.mulDiv(amount, CAP, USDC_MULTIPLIER, Math.Rounding.Ceil);
        require(usdcNeeded > 0, "Amount too small");

        // 1. Pull USDC: User -> Splitter
        USDC.safeTransferFrom(msg.sender, address(this), usdcNeeded);

        // 2. Buffer Logic
        // Keep 10% in Splitter, Send 90% to Adapter
        uint256 keepAmount = (usdcNeeded * BUFFER_PERCENT) / 100;
        uint256 depositAmount = usdcNeeded - keepAmount;

        if (depositAmount > 0) {
            USDC.forceApprove(address(yieldAdapter), depositAmount);
            yieldAdapter.deposit(depositAmount, address(this));
        }

        TOKEN_A.mint(msg.sender, amount);
        TOKEN_B.mint(msg.sender, amount);

        emit Minted(msg.sender, amount);
    }

    // ==========================================
    // 2. BURNING (Smart Withdrawal)
    // ==========================================

    /**
     * @notice Simulates a burn to see USDC return
     * @param burnAmount The amount of TokenA/B the user wants to burn
     * @return usdcToReturn Total USDC user will receive
     * @return withdrawnFromAdapter Amount pulled from Yield Source to cover shortage
     */
    function previewBurn(uint256 burnAmount)
        external
        view
        returns (uint256 usdcToReturn, uint256 withdrawnFromAdapter)
    {
        if (burnAmount == 0) return (0, 0);

        // 1. Solvency Check (Simulates the paused logic)
        _requireSolventIfPaused();

        // 2. Calculate Refund
        usdcToReturn = (burnAmount * CAP) / USDC_MULTIPLIER;
        if (usdcToReturn == 0) revert Splitter__ZeroRefund();

        // 3. Calculate Liquidity Source
        uint256 localBalance = USDC.balanceOf(address(this));

        if (localBalance < usdcToReturn) {
            withdrawnFromAdapter = usdcToReturn - localBalance;

            // Optional: Check if adapter actually has this liquidity
            // logical constraint to warn frontend if withdrawal will fail
            uint256 maxWithdraw = yieldAdapter.maxWithdraw(address(this));
            require(maxWithdraw >= withdrawnFromAdapter, "Adapter Insufficient Liquidity");
        } else {
            withdrawnFromAdapter = 0;
        }
    }

    function burn(uint256 amount) external nonReentrant {
        if (amount == 0) revert Splitter__ZeroAmount();

        // If paused, enforce 100% solvency to prevent race to exit
        _requireSolventIfPaused();

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;
        if (usdcRefund == 0) revert Splitter__ZeroRefund();

        TOKEN_A.burn(msg.sender, amount);
        TOKEN_B.burn(msg.sender, amount);

        // 1. Check Local Buffer First
        uint256 localBalance = USDC.balanceOf(address(this));

        if (localBalance < usdcRefund) {
            uint256 shortage = usdcRefund - localBalance;
            // Check adapter just in case (though solvency check handles this usually)
            if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

            // Try withdraw first, fall back to redeem if it fails
            _withdrawFromAdapter(shortage);
        }

        // Now localBalance is sufficient (Original + Withdrawn Shortage)
        USDC.safeTransfer(msg.sender, usdcRefund);

        emit Burned(msg.sender, amount);
    }

    /**
     * @dev Internal helper to withdraw from adapter with redeem fallback.
     * Tries withdraw() first, falls back to redeem() if withdraw fails.
     * Reverts with Splitter__AdapterWithdrawFailed if both fail.
     */
    function _withdrawFromAdapter(uint256 amount) internal {
        try yieldAdapter.withdraw(amount, address(this), address(this)) {
        // Success via withdraw
        }
        catch {
            // Fallback: try redeem with equivalent shares
            uint256 sharesToRedeem = yieldAdapter.convertToShares(amount);
            // Add 1 to handle rounding (ensure we get at least `amount`)
            if (sharesToRedeem > 0) {
                sharesToRedeem += 1;
            }
            try yieldAdapter.redeem(sharesToRedeem, address(this), address(this)) {
            // Success via redeem
            }
            catch {
                revert Splitter__AdapterWithdrawFailed();
            }
        }
    }

    // ==========================================
    // 3. LIQUIDATION & EMERGENCY
    // ==========================================

    /**
     * @notice Permissionless function to lock the protocol into Liquidated state.
     * @dev Call this if Price >= CAP to prevent the system from "reviving" if price drops later.
     */
    function triggerLiquidation() external nonReentrant {
        uint256 price = _getOraclePrice();
        if (price < CAP) revert Splitter__NotLiquidated();
        if (isLiquidated) revert Splitter__LiquidationActive();

        isLiquidated = true;
        emit LiquidationTriggered(price);
    }

    function emergencyRedeem(uint256 amount) external nonReentrant {
        if (!isLiquidated) {
            uint256 price = _getOraclePrice();
            if (price >= CAP) {
                isLiquidated = true;
                emit LiquidationTriggered(price);
            } else {
                revert Splitter__NotLiquidated();
            }
        }
        if (amount == 0) revert Splitter__ZeroAmount();

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;
        if (usdcRefund == 0) revert Splitter__ZeroRefund();

        TOKEN_A.burn(msg.sender, amount); // Burn Bear Only

        // Smart Withdrawal Logic for Emergency too
        uint256 localBalance = USDC.balanceOf(address(this));

        if (localBalance < usdcRefund) {
            uint256 shortage = usdcRefund - localBalance;
            _withdrawFromAdapter(shortage);
        }
        USDC.safeTransfer(msg.sender, usdcRefund);

        emit EmergencyRedeemed(msg.sender, amount);
    }

    /**
     * @notice "Ejection Seat": Pulls ALL funds from Aave to Splitter.
     * @dev Bypasses timelock. Used if Aave is buggy or about to pause.
     */
    function ejectLiquidity() external onlyOwner {
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

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

    // ==========================================
    // 4. HARVEST (Permissionless)
    // ==========================================

    /**
     * @notice Checks if there is yield to harvest and calculates distribution
     * @return canHarvest True if surplus > MIN_SURPLUS_THRESHOLD
     * @return totalSurplus Total surplus available (assets - liabilities)
     * @return callerReward Amount sent to msg.sender
     * @return treasuryShare Amount sent to treasury
     * @return stakingShare Amount sent to staking
     */
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
        if (address(yieldAdapter) == address(0)) return (false, 0, 0, 0, 0);

        // 1. Calculate Total Holdings
        uint256 myShares = yieldAdapter.balanceOf(address(this));
        uint256 adapterAssets = yieldAdapter.convertToAssets(myShares);
        uint256 localBuffer = USDC.balanceOf(address(this));
        uint256 totalHoldings = adapterAssets + localBuffer;

        // 2. Calculate Liabilities
        uint256 requiredBacking = (TOKEN_A.totalSupply() * CAP) / USDC_MULTIPLIER;

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

        callerReward = (harvestableAmount * HARVEST_REWARD_PERCENT) / 100;
        uint256 remaining = harvestableAmount - callerReward;
        treasuryShare = (remaining * 20) / 100;
        stakingShare = remaining - treasuryShare;

        canHarvest = true;
    }

    function harvestYield() external nonReentrant whenNotPaused {
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        uint256 myShares = yieldAdapter.balanceOf(address(this));
        uint256 totalAssets = yieldAdapter.convertToAssets(myShares);
        uint256 localBuffer = USDC.balanceOf(address(this));
        uint256 totalHoldings = totalAssets + localBuffer;

        uint256 requiredBacking = (TOKEN_A.totalSupply() * CAP) / USDC_MULTIPLIER;

        if (totalHoldings <= requiredBacking + MIN_SURPLUS_THRESHOLD) revert Splitter__NoSurplus();

        uint256 surplus = totalHoldings - requiredBacking;

        // Withdraw from adapter
        uint256 expectedPull = totalAssets > surplus ? surplus : totalAssets;
        uint256 balanceBefore = USDC.balanceOf(address(this));
        if (totalAssets > surplus) {
            yieldAdapter.withdraw(surplus, address(this), address(this));
        } else {
            yieldAdapter.redeem(myShares, address(this), address(this));
        }
        uint256 harvested = USDC.balanceOf(address(this)) - balanceBefore;

        // Safety check: Ensure we got at least 90% of expected (adjust threshold as needed)
        if (harvested < (expectedPull * 90) / 100) revert Splitter__InsufficientHarvest();

        // Distribute based on actual harvested
        uint256 callerCut = (harvested * HARVEST_REWARD_PERCENT) / 100;
        uint256 remaining = harvested - callerCut;
        uint256 treasuryShare = (remaining * 20) / 100;
        uint256 stakingShare = remaining - treasuryShare;

        emit YieldHarvested(harvested, treasuryShare, stakingShare);

        // Transfers (CEI: All calcs done before interactions)
        if (callerCut > 0) USDC.safeTransfer(msg.sender, callerCut);
        if (treasury != address(0)) USDC.safeTransfer(treasury, treasuryShare);
        if (staking != address(0)) {
            USDC.safeTransfer(staking, stakingShare);
        } else {
            USDC.safeTransfer(treasury, stakingShare);
        }
    }

    // ==========================================
    // 5. GOVERNANCE
    // ==========================================

    // --- Helper: Centralized Security Check ---
    function _checkLiveness() internal view {
        if (paused()) revert Splitter__GovernanceLocked();
        // Using TIMELOCK_DELAY (7 days) as the Cooldown
        if (block.timestamp < lastUnpauseTime + TIMELOCK_DELAY) {
            revert Splitter__GovernanceLocked();
        }
    }

    // --- Fee Receivers ---
    function proposeFeeReceivers(address _treasury, address _staking) external onlyOwner {
        require(_treasury != address(0), "Invalid Treasury");
        pendingFees = FeeConfig(_treasury, _staking);
        feesActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FeesProposed(_treasury, _staking, feesActivationTime);
    }

    function finalizeFeeReceivers() external onlyOwner {
        if (feesActivationTime == 0) revert Splitter__InvalidProposal();
        if (block.timestamp < feesActivationTime) revert Splitter__TimelockActive();

        _checkLiveness();

        treasury = pendingFees.treasuryAddr;
        staking = pendingFees.stakingAddr;

        delete pendingFees;
        feesActivationTime = 0;
        emit FeesUpdated(treasury, staking);
    }

    // --- Adapter Migration ---
    function proposeAdapter(address _newAdapter) external onlyOwner {
        require(_newAdapter != address(0), "Invalid Adapter");
        pendingAdapter = _newAdapter;
        adapterActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit AdapterProposed(_newAdapter, adapterActivationTime);
    }

    function finalizeAdapter() external nonReentrant onlyOwner {
        if (pendingAdapter == address(0)) revert Splitter__InvalidProposal();
        if (block.timestamp < adapterActivationTime) revert Splitter__TimelockActive();

        _checkLiveness();

        IERC4626 oldAdapter = yieldAdapter;
        IERC4626 newAdapter = IERC4626(pendingAdapter);
        yieldAdapter = IERC4626(address(0));

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
        pendingAdapter = address(0);
        adapterActivationTime = 0;
        emit AdapterMigrated(address(oldAdapter), address(newAdapter), movedAmount);
    }

    // ==========================================
    // ADMIN HELPERS
    // ==========================================
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        lastUnpauseTime = block.timestamp; // START 7 DAY COUNTDOWN
        _unpause();
    }

    // ==========================================
    // VIEW HELPERS (DASHBOARD)
    // ==========================================

    /**
     * @notice Returns the current protocol lifecycle status.
     * @return The current Status enum value (ACTIVE, PAUSED, or SETTLED).
     */
    function currentStatus() external view override returns (Status) {
        if (isLiquidated) return Status.SETTLED;
        if (paused()) return Status.PAUSED;
        return Status.ACTIVE;
    }

    /**
     * @notice Returns high-level system metrics for UI dashboards
     */
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

    /// @dev Calculates total liabilities based on TOKEN_A supply at CAP price.
    function _getTotalLiabilities() internal view returns (uint256) {
        return (TOKEN_A.totalSupply() * CAP) / USDC_MULTIPLIER;
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
            require(totalAssets >= totalLiabilities, "Paused & Insolvent");
        }
    }

    /// @dev Oracle price validation using OracleLib.
    function _getOraclePrice() internal view returns (uint256) {
        return OracleLib.getValidatedPrice(ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);
    }
}
