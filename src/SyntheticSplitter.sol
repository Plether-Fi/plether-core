// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {SyntheticToken} from "./SyntheticToken.sol";

contract SyntheticSplitter is Ownable, Pausable, ReentrancyGuard {
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
    error Splitter__AdapterNotSet();
    error Splitter__LiquidationActive();
    error Splitter__NotLiquidated();
    error Splitter__TimelockActive();
    error Splitter__InvalidProposal();
    error Splitter__NoSurplus();
    error Splitter__StalePrice();
    error Splitter__GovernanceLocked();
    error Splitter__SequencerDown();
    error Splitter__SequencerGracePeriod();
    error Splitter__InsufficientHarvest();

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

        // Calculate USDC required
        usdcRequired = (mintAmount * CAP) / USDC_MULTIPLIER;

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

        uint256 usdcNeeded = (amount * CAP) / USDC_MULTIPLIER;
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
        if (paused()) {
            uint256 totalLiabilities = (TOKEN_A.totalSupply() * CAP) / USDC_MULTIPLIER;
            uint256 myShares = yieldAdapter.balanceOf(address(this));
            uint256 adapterValue = yieldAdapter.convertToAssets(myShares);
            uint256 totalAssets = USDC.balanceOf(address(this)) + adapterValue;

            require(totalAssets >= totalLiabilities, "Paused & Insolvent");
        }

        // 2. Calculate Refund
        usdcToReturn = (burnAmount * CAP) / USDC_MULTIPLIER;

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

        if (paused()) {
            // If paused, we strictly enforce 100% solvency.
            // If we are even 1 USDC short, we keep the lock to prevent a race to exit.

            uint256 totalLiabilities = (TOKEN_A.totalSupply() * CAP) / USDC_MULTIPLIER;

            // Calculate Total Assets (Local + Adapter)
            // Note: We use the SAFE 'convertToAssets' calculation we fixed earlier
            uint256 myShares = yieldAdapter.balanceOf(address(this));
            uint256 adapterValue = yieldAdapter.convertToAssets(myShares);
            uint256 totalAssets = USDC.balanceOf(address(this)) + adapterValue;

            require(totalAssets >= totalLiabilities, "Paused & Insolvent: Burn Locked");
        }

        TOKEN_A.burn(msg.sender, amount);
        TOKEN_B.burn(msg.sender, amount);

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;

        // 1. Check Local Buffer First
        uint256 localBalance = USDC.balanceOf(address(this));

        if (localBalance < usdcRefund) {
            uint256 shortage = usdcRefund - localBalance;
            // Check adapter just in case (though solvency check handles this usually)
            if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

            // Withdraw shortage to THIS contract first
            yieldAdapter.withdraw(shortage, address(this), address(this));
        }

        // Now localBalance is sufficient (Original + Withdrawn Shortage)
        USDC.safeTransfer(msg.sender, usdcRefund);

        emit Burned(msg.sender, amount);
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

        TOKEN_A.burn(msg.sender, amount); // Burn Bear Only

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;

        // Smart Withdrawal Logic for Emergency too
        uint256 localBalance = USDC.balanceOf(address(this));

        if (localBalance < usdcRefund) {
            uint256 shortage = usdcRefund - localBalance;
            yieldAdapter.withdraw(shortage, address(this), address(this));
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

        // Transfers (CEI: All calcs done before interactions)
        if (callerCut > 0) USDC.safeTransfer(msg.sender, callerCut);
        if (treasury != address(0)) USDC.safeTransfer(treasury, treasuryShare);
        if (staking != address(0)) {
            USDC.safeTransfer(staking, stakingShare);
        } else {
            USDC.safeTransfer(treasury, stakingShare);
        }

        emit YieldHarvested(harvested, treasuryShare, stakingShare); // Update event to use harvested
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
        uint256 myShares = 0;
        uint256 adapterVal = 0;
        if (address(yieldAdapter) != address(0)) {
            myShares = yieldAdapter.balanceOf(address(this));
            adapterVal = yieldAdapter.convertToAssets(myShares);
        }

        status.totalAssets = USDC.balanceOf(address(this)) + adapterVal;
        status.totalLiabilities = (TOKEN_A.totalSupply() * CAP) / USDC_MULTIPLIER;

        if (status.totalLiabilities > 0) {
            status.collateralRatio = (status.totalAssets * 1e4) / status.totalLiabilities;
        } else {
            status.collateralRatio = 0; // Infinite/Unset
        }

        // To help UI calc APY history
        status.adapterAssets = adapterVal;
    }

    // Sequencer Check Logic
    function _checkSequencer() internal view {
        // Skip check if no feed address is provided (e.g. Mainnet/Testnet without feed)
        if (address(SEQUENCER_UPTIME_FEED) == address(0)) return;

        (
            /*uint80 roundID*/,
            int256 answer,
            uint256 startedAt,
            /*uint256 updatedAt*/,
            /*uint80 answeredInRound*/
        ) = SEQUENCER_UPTIME_FEED.latestRoundData();

        // Answer == 0: Sequencer is UP
        // Answer == 1: Sequencer is DOWN
        bool isSequencerUp = answer == 0;
        if (!isSequencerUp) {
            revert Splitter__SequencerDown();
        }

        // Check if Grace Period has passed since it came back up
        // "startedAt" on the Sequencer Feed is the timestamp when the status changed
        if (block.timestamp - startedAt < SEQUENCER_GRACE_PERIOD) {
            revert Splitter__SequencerGracePeriod();
        }
    }

    function _getOraclePrice() internal view returns (uint256) {
        _checkSequencer();
        (
            /* uint80 roundID */,
            int256 price,
            /* uint startedAt */,
            uint256 updatedAt,
            /* uint80 answeredInRound */
        ) = ORACLE.latestRoundData();

        if (updatedAt < block.timestamp - ORACLE_TIMEOUT) revert Splitter__StalePrice();
        if (price <= 0) return 0;
        return uint256(price);
    }
}
