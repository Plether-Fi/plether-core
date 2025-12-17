// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "./SyntheticToken.sol";
import "./interfaces/AggregatorV3Interface.sol";

contract SyntheticSplitter is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ==========================================
    // STATE
    // ==========================================
    
    // Assets
    SyntheticToken public immutable tokenA; // Bear (mInvDXY) - Tracks Basket
    SyntheticToken public immutable tokenB; // Bull (mDXY)    - Tracks Inverse
    IERC20 public immutable usdc;
    
    // Logic
    AggregatorV3Interface public immutable oracle;
    uint256 public immutable CAP; // $2.00 (8 decimals)
    uint256 public immutable USDC_MULTIPLIER;
    
    // The Bank (Set in Constructor)
    IERC4626 public yieldAdapter;

    // Governance / Time-Lock
    address public pendingAdapter;
    uint256 public adapterActivationTime;
    uint256 public constant TIMELOCK_DELAY = 7 days;

    // Liquidation State
    bool public isLiquidated; 

    // Events
    event Minted(address indexed user, uint256 amount);
    event Burned(address indexed user, uint256 amount);
    event AdapterProposed(address indexed newAdapter, uint256 activationTime);
    event AdapterMigrated(address indexed oldAdapter, address indexed newAdapter, uint256 transferredAmount);
    event LiquidationTriggered(uint256 price);
    event EmergencyRedeemed(address indexed user, uint256 amount);

    // Errors
    error Splitter__ZeroAmount();
    error Splitter__AdapterNotSet();
    error Splitter__LiquidationActive();
    error Splitter__NotLiquidated();
    error Splitter__TimelockActive();
    error Splitter__InvalidProposal();

    constructor(
        address _oracle,
        address _usdc,
        address _yieldAdapter,
        uint256 _cap
    ) Ownable(msg.sender) {
        require(_oracle != address(0), "Invalid Oracle");
        require(_usdc != address(0), "Invalid USDC");
        require(_yieldAdapter != address(0), "Invalid Adapter");
        require(_cap > 0, "Invalid Cap");

        oracle = AggregatorV3Interface(_oracle);
        usdc = IERC20(_usdc);
        yieldAdapter = IERC4626(_yieldAdapter);
        CAP = _cap;

        uint256 decimals = ERC20(_usdc).decimals();
        // If USDC is 6 decimals: 10^(18 + 8 - 6) = 10^20
        USDC_MULTIPLIER = 10**(18 + 8 - decimals);

        // Atomic Deployment of Tokens
        tokenA = new SyntheticToken("Bear DXY", "mInvDXY", address(this));
        tokenB = new SyntheticToken("Bull DXY", "mDXY", address(this));
    }

    // ==========================================
    // 1. MINTING (Normal Mode)
    // ==========================================

    function mint(uint256 amount) external whenNotPaused {
        if (amount == 0) revert Splitter__ZeroAmount();
        if (isLiquidated) revert Splitter__LiquidationActive();
        // Adapter check is technically redundant if set in constructor, but good for safety
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        // 1. Check Oracle Price
        uint256 price = _getOraclePrice();
        if (price >= CAP) {
            isLiquidated = true;
            emit LiquidationTriggered(price);
            revert Splitter__LiquidationActive();
        }

        // 2. Calculate Cost
        uint256 usdcNeeded = (amount * CAP) / USDC_MULTIPLIER;
        require(usdcNeeded > 0, "Amount too small");

        // 3. Move Funds: User -> Splitter -> Adapter
        usdc.safeTransferFrom(msg.sender, address(this), usdcNeeded);
        
        usdc.approve(address(yieldAdapter), usdcNeeded);
        yieldAdapter.deposit(usdcNeeded, address(this));

        // 4. Mint Pair
        tokenA.mint(msg.sender, amount);
        tokenB.mint(msg.sender, amount);

        emit Minted(msg.sender, amount);
    }

    // ==========================================
    // 2. BURNING (Normal Mode)
    // ==========================================

    function burn(uint256 amount) external whenNotPaused {
        if (amount == 0) revert Splitter__ZeroAmount();
        if (address(yieldAdapter) == address(0)) revert Splitter__AdapterNotSet();

        tokenA.burn(msg.sender, amount);
        tokenB.burn(msg.sender, amount);

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;

        // Withdraw directly to User
        yieldAdapter.withdraw(usdcRefund, msg.sender, address(this));

        emit Burned(msg.sender, amount);
    }

    // ==========================================
    // 3. LIQUIDATION MODE (Emergency)
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

        tokenA.burn(msg.sender, amount);

        uint256 usdcRefund = (amount * CAP) / USDC_MULTIPLIER;

        yieldAdapter.withdraw(usdcRefund, msg.sender, address(this));

        emit EmergencyRedeemed(msg.sender, amount);
    }

    // ==========================================
    // 4. ADAPTER MIGRATION (Time-Locked & Atomic)
    // ==========================================

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

        // ATOMIC MIGRATION
        if (address(oldAdapter) != address(0)) {
            uint256 shares = oldAdapter.balanceOf(address(this));
            if (shares > 0) {
                // Redeem Shares -> USDC to Splitter
                movedAmount = oldAdapter.redeem(shares, address(this), address(this));
            }
        }

        if (movedAmount > 0) {
            // Deposit USDC -> New Adapter
            usdc.approve(address(newAdapter), movedAmount);
            newAdapter.deposit(movedAmount, address(this));
        }

        yieldAdapter = newAdapter;
        pendingAdapter = address(0);
        adapterActivationTime = 0;

        emit AdapterMigrated(address(oldAdapter), address(newAdapter), movedAmount);
    }

    // ==========================================
    // EMERGENCY CONTROLS
    // ==========================================

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _getOraclePrice() internal view returns (uint256) {
        (, int256 price,,,) = oracle.latestRoundData();
        if (price <= 0) return 0;
        return uint256(price);
    }
}
