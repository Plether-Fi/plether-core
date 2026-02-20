// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IMarginEngine {
    function createSeries(bool isBull, uint256 strike, uint256 expiry, string memory name, string memory sym) external returns (uint256);
    function mintOptions(uint256 seriesId, uint256 optionsAmount) external;
    function settle(uint256 seriesId) external;
    function unlockCollateral(uint256 seriesId) external;
    function series(uint256 seriesId) external view returns (bool, uint256, uint256, address, uint256, uint256, bool);
}

/// @title PletherDOV
/// @custom:security-contact contact@plether.com
/// @notice Automated Covered Call Vault for Plether synthetic assets.
/// @dev Natively holds splDXY to prevent weekly AMM slippage. Implements on-chain Dutch Auctions.
contract PletherDOV is ERC20, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    enum State { UNLOCKED, AUCTIONING, LOCKED }

    struct Epoch {
        uint256 seriesId;
        uint256 optionsMinted;
        uint256 auctionStartTime;
        uint256 maxPremium;    // Max USDC price per option (6 decimals)
        uint256 minPremium;    // Min USDC price per option (6 decimals)
        uint256 auctionDuration;
        address winningMaker;
    }

    IMarginEngine public immutable MARGIN_ENGINE;
    IERC4626 public immutable STAKED_TOKEN; // splDXY-BEAR or splDXY-BULL
    IERC20 public immutable USDC;
    bool public immutable IS_BULL;

    State public currentState = State.UNLOCKED;
    uint256 public currentEpochId = 0;
    
    mapping(uint256 => Epoch) public epochs;

    // Queue Accounting
    uint256 public pendingUsdcDeposits;
    mapping(address => uint256) public userUsdcDeposits;

    event DepositQueued(address indexed user, uint256 amount);
    event EpochRolled(uint256 indexed epochId, uint256 seriesId, uint256 optionsMinted);
    event AuctionFilled(uint256 indexed epochId, address indexed buyer, uint256 premiumPaid);
    event EpochSettled(uint256 indexed epochId, uint256 collateralReturned);

    error PletherDOV__WrongState();
    error PletherDOV__ZeroAmount();
    error PletherDOV__AuctionEnded();

    constructor(
        string memory _name,
        string memory _symbol,
        address _marginEngine,
        address _stakedToken,
        address _usdc,
        bool _isBull
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        MARGIN_ENGINE = IMarginEngine(_marginEngine);
        STAKED_TOKEN = IERC4626(_stakedToken);
        USDC = IERC20(_usdc);
        IS_BULL = _isBull;

        IERC20(_stakedToken).safeIncreaseAllowance(_marginEngine, type(uint256).max);
    }

    // ==========================================
    // RETAIL QUEUE 
    // ==========================================

    /// @notice Queue USDC to be deposited into the DOV at the start of the next epoch.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert PletherDOV__ZeroAmount();
        
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        userUsdcDeposits[msg.sender] += amount;
        pendingUsdcDeposits += amount;
        
        emit DepositQueued(msg.sender, amount);
    }

    // Note: A real implementation requires a `processDeposit` function where users claim their DOV shares 
    // based on the execution price of the Friday zap. Omitted for brevity to focus on options logic.

    // ==========================================
    // EPOCH KEEPER LOGIC (Friday Operations)
    // ==========================================

    /// @notice Step 1: Rolls the vault into a new epoch, mints options, and starts the Dutch Auction.
    function startEpochAuction(
        uint256 strike,
        uint256 expiry,
        uint256 maxPremium,
        uint256 minPremium,
        uint256 duration
    ) external onlyOwner nonReentrant {
        if (currentState != State.UNLOCKED) revert PletherDOV__WrongState();
        
        currentEpochId++;
        
        // 1. (External Zap Logic Goes Here)
        // Convert all USDC (queued deposits + last week's premium) into splDXY.

        // 2. Calculate Active Collateral
        uint256 sharesBalance = STAKED_TOKEN.balanceOf(address(this));
        
        // MarginEngine requires underlying asset amounts. Convert our ERC4626 shares to assets.
        uint256 optionsToMint = STAKED_TOKEN.convertToAssets(sharesBalance);
        
        // Rounding protection: ensure previewWithdraw doesn't try to pull 1 wei more than we have
        uint256 requiredShares = STAKED_TOKEN.previewWithdraw(optionsToMint);
        if (requiredShares > sharesBalance) {
            optionsToMint -= 1;
        }

        // 3. Create Option Series & Mint
        uint256 seriesId = MARGIN_ENGINE.createSeries(IS_BULL, strike, expiry, "Plether DOV Option", "oDOV");
        MARGIN_ENGINE.mintOptions(seriesId, optionsToMint);

        epochs[currentEpochId] = Epoch({
            seriesId: seriesId,
            optionsMinted: optionsToMint,
            auctionStartTime: block.timestamp,
            maxPremium: maxPremium,
            minPremium: minPremium,
            auctionDuration: duration,
            winningMaker: address(0)
        });

        currentState = State.AUCTIONING;
        emit EpochRolled(currentEpochId, seriesId, optionsToMint);
    }

    // ==========================================
    // MARKET MAKERS: THE DUTCH AUCTION
    // ==========================================

    /// @notice Calculates the current linearly decaying price per option.
    function getCurrentOptionPrice() public view returns (uint256) {
        Epoch storage e = epochs[currentEpochId];
        if (block.timestamp <= e.auctionStartTime) return e.maxPremium;
        
        uint256 elapsed = block.timestamp - e.auctionStartTime;
        if (elapsed >= e.auctionDuration) return e.minPremium;

        uint256 priceDrop = ((e.maxPremium - e.minPremium) * elapsed) / e.auctionDuration;
        return e.maxPremium - priceDrop;
    }

    /// @notice Step 2: Market Makers call this to buy the entire batch of options.
    function fillAuction() external nonReentrant {
        if (currentState != State.AUCTIONING) revert PletherDOV__WrongState();
        Epoch storage e = epochs[currentEpochId];

        uint256 elapsed = block.timestamp - e.auctionStartTime;
        if (elapsed > e.auctionDuration) revert PletherDOV__AuctionEnded();

        uint256 currentPremium = getCurrentOptionPrice();

        // Calculate total USDC premium required for the batch (6 decimals)
        // optionsMinted is 18 decimals, currentPremium is 6 decimals
        uint256 totalPremiumUsdc = (e.optionsMinted * currentPremium) / 1e18;

        // 1. Pull USDC premium from Market Maker
        USDC.safeTransferFrom(msg.sender, address(this), totalPremiumUsdc);

        // 2. Transfer all Option tokens to the winning Market Maker
        (, , , address optionToken, , , ) = MARGIN_ENGINE.series(e.seriesId);
        IERC20(optionToken).safeTransfer(msg.sender, e.optionsMinted);

        e.winningMaker = msg.sender;
        currentState = State.LOCKED;
        
        emit AuctionFilled(currentEpochId, msg.sender, totalPremiumUsdc);
    }

    // ==========================================
    // KEEPER: EXPIRATION SETTLEMENT
    // ==========================================

    /// @notice Step 3: At expiration, unlocks remaining collateral.
    function settleEpoch() external nonReentrant {
        if (currentState != State.LOCKED) revert PletherDOV__WrongState();
        Epoch storage e = epochs[currentEpochId];
        
        // 1. Reclaim remaining Collateral from Margin Engine
        // (Assumes MarginEngine.settle() was already called by a keeper)
        MARGIN_ENGINE.unlockCollateral(e.seriesId);

        // 2. The DOV now holds USDC (from the MM premium) and splDXY (from the unlocked collateral).
        // This unlocks the vault for the next `startEpochAuction()`, where the USDC will be compounded.

        currentState = State.UNLOCKED;
        emit EpochSettled(currentEpochId, STAKED_TOKEN.balanceOf(address(this)));
    }
}
