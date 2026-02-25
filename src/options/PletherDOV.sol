// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ISyntheticSplitter} from "../interfaces/ISyntheticSplitter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMarginEngine {

    error MarginEngine__ZeroAmount();

    function createSeries(
        bool isBull,
        uint256 strike,
        uint256 expiry,
        string memory name,
        string memory sym
    ) external returns (uint256);
    function mintOptions(
        uint256 seriesId,
        uint256 optionsAmount
    ) external;
    function settle(
        uint256 seriesId,
        uint80[] calldata roundHints
    ) external;
    function unlockCollateral(
        uint256 seriesId
    ) external;
    function exercise(
        uint256 seriesId,
        uint256 optionsAmount
    ) external;
    function series(
        uint256 seriesId
    ) external view returns (bool, uint256, uint256, address, uint256, uint256, bool);
    function SPLITTER() external view returns (address);

}

/// @title PletherDOV
/// @custom:security-contact contact@plether.com
/// @notice Automated Covered Call Vault for Plether synthetic assets.
/// @dev Natively holds splDXY to prevent weekly AMM slippage. Implements on-chain Dutch Auctions.
contract PletherDOV is ERC20, ReentrancyGuard, Ownable2Step {

    using SafeERC20 for IERC20;

    enum State {
        UNLOCKED,
        AUCTIONING,
        LOCKED
    }

    struct Epoch {
        uint256 seriesId;
        uint256 optionsMinted;
        uint256 auctionStartTime;
        uint256 maxPremium; // Max USDC price per option (6 decimals)
        uint256 minPremium; // Min USDC price per option (6 decimals)
        uint256 auctionDuration;
        address winningMaker;
    }

    IMarginEngine public immutable MARGIN_ENGINE;
    IERC4626 public immutable STAKED_TOKEN; // splDXY-BEAR or splDXY-BULL
    IERC20 public immutable USDC;
    bool public immutable IS_BULL;

    State public currentState = State.UNLOCKED;
    uint256 public currentEpochId = 0;
    address public zapKeeper;

    mapping(uint256 => Epoch) public epochs;

    // Queue Accounting
    uint256 public pendingUsdcDeposits;
    mapping(address => uint256) public userUsdcDeposits;
    mapping(address => uint256) public userDepositEpoch;

    // Share Accounting
    struct EpochDeposits {
        uint256 totalUsdc;
        uint256 sharesMinted;
    }

    mapping(uint256 => EpochDeposits) public epochDeposits;

    uint256 internal _preZapSplDXYBalance;
    uint256 internal _preZapDepositUsdc;
    uint256 internal _preZapPremiumUsdc;
    bool internal _zapSnapshotTaken;

    event DepositQueued(address indexed user, uint256 amount);
    event DepositWithdrawn(address indexed user, uint256 amount);
    event EpochRolled(uint256 indexed epochId, uint256 seriesId, uint256 optionsMinted);
    event AuctionFilled(uint256 indexed epochId, address indexed buyer, uint256 premiumPaid);
    event AuctionCancelled(uint256 indexed epochId);
    event EpochSettled(uint256 indexed epochId, uint256 collateralReturned);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event ZapKeeperSet(address indexed keeper);
    event SharesInitialized(address indexed owner, uint256 shares);
    event DepositSharesMinted(uint256 indexed epochId, uint256 totalShares, uint256 totalDepositsUsdc);
    event SharesClaimed(address indexed user, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 splDXYAmount, uint256 usdcAmount);

    error PletherDOV__WrongState();
    error PletherDOV__ZeroAmount();
    error PletherDOV__AuctionEnded();
    error PletherDOV__AuctionNotExpired();
    error PletherDOV__SplitterNotSettled();
    error PletherDOV__InvalidParams();
    error PletherDOV__InsufficientDeposit();
    error PletherDOV__DepositProcessed();
    error PletherDOV__Unauthorized();
    error PletherDOV__AlreadyInitialized();
    error PletherDOV__NotInitialized();
    error PletherDOV__DepositsNotZapped();
    error PletherDOV__NothingToClaim();

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
    // SHARE INITIALIZATION
    // ==========================================

    /// @notice Mints initial shares to the owner for seed capital already held by the vault.
    /// @dev Must be called before the first epoch if the vault holds pre-seeded splDXY.
    function initializeShares() external onlyOwner {
        if (totalSupply() > 0) {
            revert PletherDOV__AlreadyInitialized();
        }
        uint256 balance = STAKED_TOKEN.balanceOf(address(this));
        if (balance == 0) {
            revert PletherDOV__ZeroAmount();
        }
        uint256 assets = STAKED_TOKEN.convertToAssets(balance);
        _mint(msg.sender, assets);
        emit SharesInitialized(msg.sender, assets);
    }

    // ==========================================
    // RETAIL QUEUE
    // ==========================================

    /// @notice Queue USDC to be deposited into the DOV at the start of the next epoch.
    /// @dev Auto-claims shares from any previous epoch deposit before recording the new one.
    function deposit(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) {
            revert PletherDOV__ZeroAmount();
        }

        _claimShares(msg.sender);

        if (userDepositEpoch[msg.sender] < currentEpochId) {
            userUsdcDeposits[msg.sender] = 0;
            userDepositEpoch[msg.sender] = currentEpochId;
        }

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        userUsdcDeposits[msg.sender] += amount;
        pendingUsdcDeposits += amount;

        emit DepositQueued(msg.sender, amount);
    }

    /// @notice Withdraw queued USDC that has not yet been processed into an epoch.
    function withdrawDeposit(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) {
            revert PletherDOV__ZeroAmount();
        }
        if (userDepositEpoch[msg.sender] < currentEpochId) {
            revert PletherDOV__DepositProcessed();
        }
        if (userUsdcDeposits[msg.sender] < amount) {
            revert PletherDOV__InsufficientDeposit();
        }

        userUsdcDeposits[msg.sender] -= amount;
        pendingUsdcDeposits -= amount;

        USDC.safeTransfer(msg.sender, amount);
        emit DepositWithdrawn(msg.sender, amount);
    }

    /// @notice Claims DOV shares earned from a previous epoch's processed deposit.
    function claimShares() external nonReentrant {
        uint256 before = balanceOf(msg.sender);
        _claimShares(msg.sender);
        if (balanceOf(msg.sender) == before) {
            revert PletherDOV__NothingToClaim();
        }
    }

    /// @notice Redeems vault shares for proportional splDXY (and any premium USDC).
    /// @dev Only callable during UNLOCKED. Auto-claims pending deposit shares first.
    function withdraw(
        uint256 shares
    ) external nonReentrant {
        if (currentState != State.UNLOCKED) {
            revert PletherDOV__WrongState();
        }
        if (shares == 0) {
            revert PletherDOV__ZeroAmount();
        }

        _claimShares(msg.sender);

        uint256 supply = totalSupply();
        uint256 splDXYBalance = STAKED_TOKEN.balanceOf(address(this));
        uint256 splDXYOut = (splDXYBalance * shares) / supply;

        uint256 usdcBal = USDC.balanceOf(address(this));
        uint256 redeemableUsdc = usdcBal > pendingUsdcDeposits ? usdcBal - pendingUsdcDeposits : 0;
        uint256 usdcOut = supply > 0 ? (redeemableUsdc * shares) / supply : 0;

        _burn(msg.sender, shares);

        if (splDXYOut > 0) {
            IERC20(address(STAKED_TOKEN)).safeTransfer(msg.sender, splDXYOut);
        }
        if (usdcOut > 0) {
            USDC.safeTransfer(msg.sender, usdcOut);
        }

        emit Withdrawn(msg.sender, shares, splDXYOut, usdcOut);
    }

    // ==========================================
    // ZAP KEEPER
    // ==========================================

    function setZapKeeper(
        address _keeper
    ) external onlyOwner {
        zapKeeper = _keeper;
        emit ZapKeeperSet(_keeper);
    }

    /// @notice Releases all USDC held by this DOV to the caller (zapKeeper only).
    /// @dev Snapshots pre-zap state for share calculation in startEpochAuction.
    function releaseUsdcForZap() external returns (uint256 amount) {
        if (msg.sender != zapKeeper) {
            revert PletherDOV__Unauthorized();
        }
        if (currentState != State.UNLOCKED) {
            revert PletherDOV__WrongState();
        }

        _preZapSplDXYBalance = STAKED_TOKEN.balanceOf(address(this));
        _preZapDepositUsdc = pendingUsdcDeposits;

        amount = USDC.balanceOf(address(this));
        _preZapPremiumUsdc = amount > pendingUsdcDeposits ? amount - pendingUsdcDeposits : 0;
        _zapSnapshotTaken = true;

        if (amount > 0) {
            USDC.safeTransfer(msg.sender, amount);
        }
    }

    // ==========================================
    // EPOCH KEEPER LOGIC (Friday Operations)
    // ==========================================

    /// @notice Step 1: Rolls the vault into a new epoch, mints options, starts Dutch Auction.
    /// @dev If deposits are pending, releaseUsdcForZap must have been called first to snapshot
    ///      pre-zap state. Deposit shares are minted proportionally based on the zap conversion.
    function startEpochAuction(
        uint256 strike,
        uint256 expiry,
        uint256 maxPremium,
        uint256 minPremium,
        uint256 duration
    ) external nonReentrant {
        if (msg.sender != owner() && msg.sender != zapKeeper) {
            revert PletherDOV__Unauthorized();
        }
        if (currentState != State.UNLOCKED) {
            revert PletherDOV__WrongState();
        }
        if (duration == 0 || minPremium == 0 || minPremium > maxPremium) {
            revert PletherDOV__InvalidParams();
        }
        if (pendingUsdcDeposits > 0 && !_zapSnapshotTaken) {
            revert PletherDOV__DepositsNotZapped();
        }

        if (currentEpochId > 0) {
            Epoch storage prev = epochs[currentEpochId];
            if (prev.seriesId != 0) {
                (,,,,,, bool isSettled) = MARGIN_ENGINE.series(prev.seriesId);
                if (!isSettled) {
                    revert PletherDOV__WrongState();
                }
            }
        }

        currentEpochId++;

        if (_zapSnapshotTaken) {
            _mintDepositShares();
            _zapSnapshotTaken = false;
        }
        pendingUsdcDeposits = 0;

        uint256 sharesBalance = STAKED_TOKEN.balanceOf(address(this));

        uint256 optionsToMint = STAKED_TOKEN.previewRedeem(sharesBalance);

        if (optionsToMint == 0) {
            revert PletherDOV__ZeroAmount();
        }

        // Rounding protection: previewWithdraw rounds up, so the shares needed
        // to withdraw optionsToMint assets may exceed our balance. Decrement
        // until the required shares fit within what we hold.
        while (STAKED_TOKEN.previewWithdraw(optionsToMint) > sharesBalance) {
            optionsToMint -= 1;
        }

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
        if (block.timestamp <= e.auctionStartTime) {
            return e.maxPremium;
        }

        uint256 elapsed = block.timestamp - e.auctionStartTime;
        if (elapsed >= e.auctionDuration) {
            return e.minPremium;
        }

        uint256 priceDrop = ((e.maxPremium - e.minPremium) * elapsed) / e.auctionDuration;
        return e.maxPremium - priceDrop;
    }

    /// @notice Step 2: Market Makers call this to buy the entire batch of options.
    /// @dev Premium calculation: optionsMinted (18 decimals) * currentPremium (6 decimals) / 1e18
    ///      = totalPremiumUsdc (6 decimals). Relies on OptionToken.decimals() == 18.
    function fillAuction() external nonReentrant {
        if (currentState != State.AUCTIONING) {
            revert PletherDOV__WrongState();
        }
        Epoch storage e = epochs[currentEpochId];

        uint256 elapsed = block.timestamp - e.auctionStartTime;
        if (elapsed >= e.auctionDuration) {
            revert PletherDOV__AuctionEnded();
        }

        (,,,,,, bool isSettled) = MARGIN_ENGINE.series(e.seriesId);
        if (
            isSettled
                || ISyntheticSplitter(MARGIN_ENGINE.SPLITTER()).currentStatus() == ISyntheticSplitter.Status.SETTLED
        ) {
            revert PletherDOV__WrongState();
        }

        uint256 currentPremium = getCurrentOptionPrice();

        // Calculate total USDC premium required for the batch (6 decimals)
        // optionsMinted is 18 decimals, currentPremium is 6 decimals
        uint256 totalPremiumUsdc = (e.optionsMinted * currentPremium) / 1e18;

        // 1. Pull USDC premium from Market Maker
        USDC.safeTransferFrom(msg.sender, address(this), totalPremiumUsdc);

        // 2. Transfer all Option tokens to the winning Market Maker
        (,,, address optionToken,,,) = MARGIN_ENGINE.series(e.seriesId);
        IERC20(optionToken).safeTransfer(msg.sender, e.optionsMinted);

        e.winningMaker = msg.sender;
        currentState = State.LOCKED;

        emit AuctionFilled(currentEpochId, msg.sender, totalPremiumUsdc);
    }

    /// @notice Cancels an expired auction that received no fill, returning the vault to UNLOCKED.
    /// @dev Also allows immediate cancellation when the Splitter has liquidated.
    function cancelAuction() external nonReentrant {
        if (currentState != State.AUCTIONING) {
            revert PletherDOV__WrongState();
        }

        bool isLiquidated =
            ISyntheticSplitter(MARGIN_ENGINE.SPLITTER()).currentStatus() == ISyntheticSplitter.Status.SETTLED;

        if (!isLiquidated) {
            Epoch storage e = epochs[currentEpochId];
            uint256 elapsed = block.timestamp - e.auctionStartTime;
            if (elapsed < e.auctionDuration) {
                revert PletherDOV__AuctionNotExpired();
            }
        }

        currentState = State.UNLOCKED;
        emit AuctionCancelled(currentEpochId);
    }

    /// @notice Exercises unsold option tokens held by the DOV after a cancelled auction.
    /// @dev Skips exercise for OTM options so keeper batch transactions don't revert.
    function exerciseUnsoldOptions(
        uint256 epochId
    ) external nonReentrant {
        Epoch storage e = epochs[epochId];
        if (e.winningMaker != address(0)) {
            revert PletherDOV__WrongState();
        }

        (bool isBull, uint256 strike,, address optionToken, uint256 settlementPrice,,) =
            MARGIN_ENGINE.series(e.seriesId);
        if (isBull != IS_BULL) {
            revert PletherDOV__InvalidParams();
        }
        uint256 balance = IERC20(optionToken).balanceOf(address(this));
        if (balance > 0 && settlementPrice > strike) {
            MARGIN_ENGINE.exercise(e.seriesId, balance);
        }
    }

    /// @notice Reclaims collateral from an unsold series after it has been settled.
    function reclaimCollateral(
        uint256 epochId
    ) external nonReentrant {
        Epoch storage e = epochs[epochId];
        if (e.winningMaker != address(0)) {
            revert PletherDOV__WrongState();
        }
        MARGIN_ENGINE.unlockCollateral(e.seriesId);
    }

    // ==========================================
    // KEEPER: EXPIRATION SETTLEMENT
    // ==========================================

    /// @notice Step 3: At expiration, settles the series and unlocks remaining collateral.
    /// @param roundHints Chainlink round IDs for oracle lookup (one per feed component).
    ///        Ignored if the series is already settled.
    function settleEpoch(
        uint80[] calldata roundHints
    ) external nonReentrant {
        if (currentState != State.LOCKED) {
            revert PletherDOV__WrongState();
        }
        Epoch storage e = epochs[currentEpochId];

        (,,,,,, bool isSettled) = MARGIN_ENGINE.series(e.seriesId);
        if (!isSettled) {
            MARGIN_ENGINE.settle(e.seriesId, roundHints);
        }

        try MARGIN_ENGINE.unlockCollateral(e.seriesId) {}
        catch (bytes memory reason) {
            bytes4 expected = IMarginEngine.MarginEngine__ZeroAmount.selector;
            if (reason.length < 4 || bytes4(reason) != expected) {
                assembly { revert(add(reason, 32), mload(reason)) }
            }
        }

        currentState = State.UNLOCKED;
        emit EpochSettled(currentEpochId, STAKED_TOKEN.balanceOf(address(this)));
    }

    // ==========================================
    // EMERGENCY
    // ==========================================

    /// @notice Recovers stranded funds after Splitter liquidation (protocol end-of-life).
    /// @dev Only callable by owner when the Splitter has permanently settled.
    function emergencyWithdraw(
        IERC20 token
    ) external onlyOwner {
        if (ISyntheticSplitter(MARGIN_ENGINE.SPLITTER()).currentStatus() != ISyntheticSplitter.Status.SETTLED) {
            revert PletherDOV__SplitterNotSettled();
        }
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) {
            revert PletherDOV__ZeroAmount();
        }
        token.safeTransfer(msg.sender, balance);
        emit EmergencyWithdraw(address(token), balance);
    }

    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================

    /// @notice Returns the number of shares a user can claim from a processed deposit.
    function pendingSharesOf(
        address user
    ) external view returns (uint256) {
        uint256 depositEpoch = userDepositEpoch[user];
        uint256 depositAmount = userUsdcDeposits[user];

        if (depositAmount == 0 || depositEpoch >= currentEpochId) {
            return 0;
        }

        uint256 claimEpoch = depositEpoch + 1;
        EpochDeposits storage ed = epochDeposits[claimEpoch];

        if (ed.sharesMinted == 0 || ed.totalUsdc == 0) {
            return 0;
        }

        return (depositAmount * ed.sharesMinted) / ed.totalUsdc;
    }

    /// @notice Returns the vault's total assets excluding pending deposits.
    function totalVaultAssets() external view returns (uint256 splDXYShares, uint256 usdcBalance) {
        splDXYShares = STAKED_TOKEN.balanceOf(address(this));
        uint256 usdcBal = USDC.balanceOf(address(this));
        usdcBalance = usdcBal > pendingUsdcDeposits ? usdcBal - pendingUsdcDeposits : 0;
    }

    // ==========================================
    // INTERNAL
    // ==========================================

    /// @dev Claims DOV shares for a user whose deposit was processed in a previous epoch.
    function _claimShares(
        address user
    ) internal {
        uint256 depositEpoch = userDepositEpoch[user];
        uint256 depositAmount = userUsdcDeposits[user];

        if (depositAmount == 0 || depositEpoch >= currentEpochId) {
            return;
        }

        uint256 claimEpoch = depositEpoch + 1;
        EpochDeposits storage ed = epochDeposits[claimEpoch];

        if (ed.totalUsdc == 0) {
            return;
        }

        uint256 shares = (depositAmount * ed.sharesMinted) / ed.totalUsdc;

        userUsdcDeposits[user] = 0;
        userDepositEpoch[user] = currentEpochId;

        if (shares > 0) {
            _transfer(address(this), user, shares);
            emit SharesClaimed(user, shares);
        }
    }

    /// @dev Computes and mints aggregate shares for all depositors whose USDC was zapped.
    ///      Uses the pre-zap snapshot from releaseUsdcForZap to attribute splDXY proportionally
    ///      between existing shareholders (premium) and new depositors (deposit USDC).
    function _mintDepositShares() internal {
        uint256 totalDeposits = _preZapDepositUsdc;
        if (totalDeposits == 0) {
            return;
        }

        uint256 postZapBalance = STAKED_TOKEN.balanceOf(address(this));
        uint256 deltaSplDXY = postZapBalance - _preZapSplDXYBalance;
        uint256 totalZappedUsdc = totalDeposits + _preZapPremiumUsdc;

        uint256 depositSplDXY;
        if (totalZappedUsdc > 0) {
            depositSplDXY = (deltaSplDXY * totalDeposits) / totalZappedUsdc;
        }

        uint256 sharesToMint;
        uint256 supply = totalSupply();

        if (supply == 0) {
            if (_preZapSplDXYBalance > 0) {
                revert PletherDOV__NotInitialized();
            }
            sharesToMint = STAKED_TOKEN.convertToAssets(postZapBalance);
        } else {
            uint256 existingSplDXY = postZapBalance - depositSplDXY;
            if (existingSplDXY > 0) {
                sharesToMint = (depositSplDXY * supply) / existingSplDXY;
            }
        }

        if (sharesToMint > 0) {
            _mint(address(this), sharesToMint);
            epochDeposits[currentEpochId] = EpochDeposits({totalUsdc: totalDeposits, sharesMinted: sharesToMint});
            emit DepositSharesMinted(currentEpochId, sharesToMint, totalDeposits);
        }
    }

}
