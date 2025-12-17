// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./SyntheticToken.sol";
import "./interfaces/AggregatorV3Interface.sol";

contract SyntheticSplitter is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ==========================================
    // STATE
    // ==========================================
    
    // Assets
    SyntheticToken public immutable tokenA; // Bear
    SyntheticToken public immutable tokenB; // Bull
    IERC20 public immutable usdc;
    
    // Logic
    AggregatorV3Interface public immutable oracle;
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
        address treasury;
        address staking;
    }
    FeeConfig public pendingFees;
    uint256 public feesActivationTime;

    uint256 public constant ORACLE_TIMEOUT = 24 hours;
    uint256 public constant TIMELOCK_DELAY = 7 days;
    uint256 public lastUnpauseTime;

    uint256 public harvestRewardPercent = 1;
    uint256 public constant MIN_SURPLUS_THRESHOLD = 50 * 1e6;

    // Liquidation State
    bool public isLiquidated; 

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

    constructor(
        address _oracle,
        address _usdc,
        address _yieldAdapter,
        uint256 _cap,
        address _treasury
    ) Ownable(msg.sender) {
        require(_oracle != address(0), "Invalid Oracle");
        require(_usdc != address(0), "Invalid USDC");
        require(_yieldAdapter != address(0), "Invalid Adapter");
        require(_cap > 0, "Invalid Cap");
        require(_treasury != address(0), "Invalid Treasury");

        oracle = AggregatorV3Interface(_oracle);
        usdc = IERC20(_usdc);
        yieldAdapter = IERC4626(_yieldAdapter);
        CAP = _cap;
        treasury = _treasury;

        tokenA = new SyntheticToken("Bear DXY", "mInvDXY", address(this));
        tokenB = new SyntheticToken("Bull DXY", "mDXY", address(this));

        // OPTIMIZATION: Calculate scaler ONCE
        uint256 decimals = ERC20(_usdc).decimals();
        USDC_MULTIPLIER = 10**(18 + 8 - decimals);
    }

    // ==========================================
    // 1. MINTING (With Buffer)
    // ==========================================

    function mint(uint256 amount) external whenNotPaused {
        if (amount == 0) revert Splitter__ZeroAmount();
        if (isLiquidated) revert Splitter__LiquidationActive();
        // Check adapter unless we are in emergency mode, 
        // but generally we shouldn't mint if no adapter is connected.
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        uint256 price = _getOraclePrice();
        if (price >= CAP) {
            isLiquidated = true;
            emit LiquidationTriggered(price);
            revert Splitter__LiquidationActive();
        }

        uint256 usdcNeeded = (amount * CAP) / USDC_MULTIPLIER;
        require(usdcNeeded > 0, "Amount too small");

        // 1. Pull USDC: User -> Splitter
        usdc.safeTransferFrom(msg.sender, address(this), usdcNeeded);

        // 2. Buffer Logic
        // Keep 10% in Splitter, Send 90% to Adapter
        uint256 keepAmount = (usdcNeeded * BUFFER_PERCENT) / 100;
        uint256 depositAmount = usdcNeeded - keepAmount;

        if (depositAmount > 0) {
            usdc.approve(address(yieldAdapter), depositAmount);
            yieldAdapter.deposit(depositAmount, address(this));
        }

        tokenA.mint(msg.sender, amount);
        tokenB.mint(msg.sender, amount);

        emit Minted(msg.sender, amount);
    }

    // ==========================================
    // 2. BURNING (Smart Withdrawal)
    // ==========================================

    function burn(uint256 amount) external whenNotPaused {
        if (amount == 0) revert Splitter__ZeroAmount();
        
        tokenA.burn(msg.sender, amount);
        tokenB.burn(msg.sender, amount);

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;

        // 1. Check Local Buffer First
        uint256 localBalance = usdc.balanceOf(address(this));

        if (localBalance >= usdcRefund) {
            // A. Pay from Buffer (Cheap Gas & Safe from Freeze)
            usdc.safeTransfer(msg.sender, usdcRefund);
        } else {
            // B. Pay from Adapter (Normal Operation)
            if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();
            // Note: If Adapter is frozen/empty, this will revert.
            // In that case, Admin must call ejectLiquidity().
            yieldAdapter.withdraw(usdcRefund, msg.sender, address(this));
        }

        emit Burned(msg.sender, amount);
    }

    // ==========================================
    // 3. LIQUIDATION & EMERGENCY
    // ==========================================

    function emergencyRedeem(uint256 amount) external {
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

        tokenA.burn(msg.sender, amount); // Burn Bear Only
        
        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;
        
        // Smart Withdrawal Logic for Emergency too
        uint256 localBalance = usdc.balanceOf(address(this));
        if (localBalance >= usdcRefund) {
            usdc.safeTransfer(msg.sender, usdcRefund);
        } else {
            yieldAdapter.withdraw(usdcRefund, msg.sender, address(this));
        }

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

    function harvestYield() external whenNotPaused {
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        uint256 totalAssets = yieldAdapter.convertToAssets(yieldAdapter.balanceOf(address(this)));
        uint256 localBuffer = usdc.balanceOf(address(this));
        uint256 totalHoldings = totalAssets + localBuffer;
        
        uint256 requiredBacking = (tokenA.totalSupply() * CAP) / USDC_MULTIPLIER;

        if (totalHoldings <= requiredBacking + MIN_SURPLUS_THRESHOLD) revert Splitter__NoSurplus();

        uint256 surplus = totalHoldings - requiredBacking;

        // Withdraw from adapter
        if (totalAssets >= surplus) {
             yieldAdapter.withdraw(surplus, address(this), address(this));
        } else {
             yieldAdapter.withdraw(totalAssets, address(this), address(this));
        }

        uint256 callerCut = (surplus * harvestRewardPercent) / 100;
        uint256 remaining = surplus - callerCut;
        uint256 treasuryShare = (remaining * 20) / 100;
        uint256 stakingShare = remaining - treasuryShare;

        if (callerCut > 0) usdc.safeTransfer(msg.sender, callerCut);
        if (treasury != address(0)) usdc.safeTransfer(treasury, treasuryShare);

        if (staking != address(0)) {
            usdc.safeTransfer(staking, stakingShare);
        } else {
            usdc.safeTransfer(treasury, stakingShare);
        }

        emit YieldHarvested(surplus, treasuryShare, stakingShare);
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

        treasury = pendingFees.treasury;
        staking = pendingFees.staking;

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

    function finalizeAdapter() external onlyOwner {
        if (pendingAdapter == address(0)) revert Splitter__InvalidProposal();
        if (block.timestamp < adapterActivationTime) revert Splitter__TimelockActive();

        _checkLiveness();

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
            usdc.approve(address(newAdapter), movedAmount);
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
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner {
      lastUnpauseTime = block.timestamp; // START 7 DAY COUNTDOWN
      _unpause();
    }

    function _getOraclePrice() internal view returns (uint256) {
        (
            /* uint80 roundID */,
            int256 price,
            /* uint startedAt */,
            uint256 updatedAt,
            /* uint80 answeredInRound */
        ) = oracle.latestRoundData();

        if (updatedAt < block.timestamp - ORACLE_TIMEOUT) revert Splitter__StalePrice();
        if (price <= 0) return 0;
        return uint256(price);
    }
}
