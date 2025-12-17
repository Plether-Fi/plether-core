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
    SyntheticToken public immutable tokenA; 
    SyntheticToken public immutable tokenB; 
    IERC20 public immutable usdc;
    
    // Logic
    AggregatorV3Interface public immutable oracle;
    uint256 public immutable CAP; 
    uint256 public immutable USDC_MULTIPLIER; // Cached math scaler

    // The Bank
    IERC4626 public yieldAdapter;

    // Governance / Time-Lock
    address public pendingAdapter;
    uint256 public adapterActivationTime;
    uint256 public constant TIMELOCK_DELAY = 7 days;

    // Fee Receivers
    address public treasury;
    address public staking;

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
    event FeeReceiversUpdated(address treasury, address staking);

    // Errors
    error Splitter__ZeroAmount();
    error Splitter__AdapterNotSet();
    error Splitter__LiquidationActive();
    error Splitter__NotLiquidated();
    error Splitter__TimelockActive();
    error Splitter__InvalidProposal();
    error Splitter__NoSurplus();

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

        // Atomic Deployment of Tokens
        tokenA = new SyntheticToken("Bear DXY", "mInvDXY", address(this));
        tokenB = new SyntheticToken("Bull DXY", "mDXY", address(this));

        uint256 decimals = ERC20(_usdc).decimals();
        USDC_MULTIPLIER = 10**(18 + 8 - decimals);
    }

    function mint(uint256 amount) external whenNotPaused {
        if (amount == 0) revert Splitter__ZeroAmount();
        if (isLiquidated) revert Splitter__LiquidationActive();
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        uint256 price = _getOraclePrice();
        if (price >= CAP) {
            isLiquidated = true;
            emit LiquidationTriggered(price);
            revert Splitter__LiquidationActive();
        }

        uint256 usdcNeeded = (amount * CAP) / USDC_MULTIPLIER;
        require(usdcNeeded > 0, "Amount too small");

        usdc.safeTransferFrom(msg.sender, address(this), usdcNeeded);
        
        usdc.approve(address(yieldAdapter), usdcNeeded);
        yieldAdapter.deposit(usdcNeeded, address(this));

        tokenA.mint(msg.sender, amount);
        tokenB.mint(msg.sender, amount);

        emit Minted(msg.sender, amount);
    }

    function burn(uint256 amount) external whenNotPaused {
        if (amount == 0) revert Splitter__ZeroAmount();
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        tokenA.burn(msg.sender, amount);
        tokenB.burn(msg.sender, amount);

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;

        yieldAdapter.withdraw(usdcRefund, msg.sender, address(this));

        emit Burned(msg.sender, amount);
    }

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

        tokenA.burn(msg.sender, amount);
        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;
        yieldAdapter.withdraw(usdcRefund, msg.sender, address(this));
        emit EmergencyRedeemed(msg.sender, amount);
    }

    // ==========================================
    // YIELD HARVESTING
    // ==========================================

    /**
     * @notice Skims excess USDC generated by the Yield Adapter.
     * @dev Surplus = AdapterBalance - RequiredCollateral.
     */
    function harvestYield() external onlyOwner {
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        // 1. Get total value held in the vault (Principal + Interest)
        uint256 totalAssets = yieldAdapter.totalAssets();

        // 2. Calculate Required Collateral
        // We only need to check Token A supply because A & B are always equal.
        // Formula: (Supply * Cap) / Scaler
        uint256 requiredBacking = (tokenA.totalSupply() * CAP) / USDC_MULTIPLIER;

        // 3. Check for Surplus
        if (totalAssets <= requiredBacking) {
            revert Splitter__NoSurplus();
        }

        uint256 surplus = totalAssets - requiredBacking;

        // 4. Withdraw Surplus from Vault to Splitter
        // receiver = address(this)
        // owner = address(this)
        yieldAdapter.withdraw(surplus, address(this), address(this));

        // 5. Split Logic
        uint256 treasuryShare = (surplus * 20) / 100; // 20%
        uint256 stakingShare = surplus - treasuryShare; // 80%

        // 6. Transfer
        if (treasury != address(0)) {
            usdc.safeTransfer(treasury, treasuryShare);
        }

        if (staking != address(0)) {
            usdc.safeTransfer(staking, stakingShare);
        } else {
            // Fallback: If Staking contract isn't built yet,
            // send the staking share to Treasury to avoid stuck funds.
            usdc.safeTransfer(treasury, stakingShare);
        }

        emit YieldHarvested(surplus, treasuryShare, stakingShare);
    }

    // ==========================================
    // ADMIN SETTERS
    // ==========================================

    struct FeeConfig {
        address treasury;
        address staking;
    }

    FeeConfig public pendingFees;
    uint256 public feesActivationTime;
    
    // Reuse the same delay or a different one? 
    // Usually same delay is fine.
    
    event FeesProposed(address treasury, address staking, uint256 activationTime);
    event FeesUpdated(address treasury, address staking);

    /**
     * @notice Step 1: Propose new destinations for the revenue.
     * Starts the 7-day timer.
     */
    function proposeFeeReceivers(address _treasury, address _staking) external onlyOwner {
        require(_treasury != address(0), "Invalid Treasury");
        // Staking can be 0 (fallback logic handles it)
        
        pendingFees = FeeConfig(_treasury, _staking);
        feesActivationTime = block.timestamp + TIMELOCK_DELAY;
        
        emit FeesProposed(_treasury, _staking, feesActivationTime);
    }

    /**
     * @notice Step 2: Finalize the change after the delay.
     */
    function finalizeFeeReceivers() external onlyOwner {
        if (feesActivationTime == 0) revert Splitter__InvalidProposal();
        if (block.timestamp < feesActivationTime) revert Splitter__TimelockActive();

        treasury = pendingFees.treasury;
        staking = pendingFees.staking;

        // Reset
        delete pendingFees;
        feesActivationTime = 0;

        emit FeesUpdated(treasury, staking);
    }
    
    function proposeAdapter(address _newAdapter) external onlyOwner {
        require(_newAdapter != address(0), "Invalid Adapter");
        pendingAdapter = _newAdapter;
        adapterActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit AdapterProposed(_newAdapter, adapterActivationTime);
    }

    function finalizeAdapter() external onlyOwner {
        if (pendingAdapter == address(0)) revert Splitter__InvalidProposal();
        if (block.timestamp < adapterActivationTime) revert Splitter__TimelockActive();

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
    
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function _getOraclePrice() internal view returns (uint256) {
        (, int256 price,,,) = oracle.latestRoundData();
        if (price <= 0) return 0;
        return uint256(price);
    }
}
