// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ISyntheticSplitter} from "../interfaces/ISyntheticSplitter.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ISettlementOracle {

    function getSettlementPrices() external view returns (uint256 bearPrice, uint256 bullPrice);

}

interface IOptionToken {

    function initialize(
        string memory name,
        string memory symbol,
        address marginEngine
    ) external;
    function mint(
        address to,
        uint256 amount
    ) external;
    function burn(
        address from,
        uint256 amount
    ) external;
    function totalSupply() external view returns (uint256);

}

/// @title MarginEngine
/// @custom:security-contact contact@plether.com
/// @notice Core options clearinghouse for Plether DOVs.
/// @dev Enforces 100% margin requirements and Fractional In-Kind Settlement via StakedTokens.
contract MarginEngine is ReentrancyGuard, AccessControl {

    using SafeERC20 for IERC20;

    bytes32 public constant SERIES_CREATOR_ROLE = keccak256("SERIES_CREATOR_ROLE");

    struct Series {
        bool isBull;
        uint256 strike;
        uint256 expiry;
        address optionToken;
        uint256 settlementPrice;
        uint256 settlementShareRate; // Exchange rate of the vault locked at expiration
        bool isSettled;
    }

    ISyntheticSplitter public immutable SPLITTER;
    ISettlementOracle public immutable ORACLE;
    IERC4626 public immutable STAKED_BEAR;
    IERC4626 public immutable STAKED_BULL;
    address public immutable OPTION_IMPLEMENTATION;
    uint256 public immutable CAP;
    uint256 public constant SETTLEMENT_WINDOW = 1 hours;

    uint256 public nextSeriesId = 1;
    mapping(uint256 => Series) public series;

    // seriesId => writer => amount of splDXY shares locked
    mapping(uint256 => mapping(address => uint256)) public writerLockedShares;

    // seriesId => writer => amount of options minted
    mapping(uint256 => mapping(address => uint256)) public writerOptions;

    event SeriesCreated(uint256 indexed seriesId, address optionToken, bool isBull, uint256 strike, uint256 expiry);
    event OptionsMinted(uint256 indexed seriesId, address indexed writer, uint256 optionsAmount, uint256 sharesLocked);
    event SeriesSettled(uint256 indexed seriesId, uint256 settlementPrice, uint256 settlementShareRate);
    event OptionsExercised(
        uint256 indexed seriesId, address indexed buyer, uint256 optionsAmount, uint256 sharesReceived
    );
    event CollateralUnlocked(
        uint256 indexed seriesId, address indexed writer, uint256 optionsAmount, uint256 sharesReturned
    );

    error MarginEngine__InvalidParams();
    error MarginEngine__Expired();
    error MarginEngine__NotExpired();
    error MarginEngine__AlreadySettled();
    error MarginEngine__NotSettled();
    error MarginEngine__OptionIsOTM();
    error MarginEngine__ZeroAmount();
    error MarginEngine__SplitterNotActive();
    error MarginEngine__SettlementWindowClosed();

    constructor(
        address _splitter,
        address _oracle,
        address _stakedBear,
        address _stakedBull,
        address _optionImplementation
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        SPLITTER = ISyntheticSplitter(_splitter);
        ORACLE = ISettlementOracle(_oracle);
        STAKED_BEAR = IERC4626(_stakedBear);
        STAKED_BULL = IERC4626(_stakedBull);
        OPTION_IMPLEMENTATION = _optionImplementation;
        CAP = ISyntheticSplitter(_splitter).CAP();
    }

    /// @notice Admin function to deploy a new Option Token Series via EIP-1167.
    function createSeries(
        bool isBull,
        uint256 strike,
        uint256 expiry,
        string memory name,
        string memory symbol
    ) external onlyRole(SERIES_CREATOR_ROLE) returns (uint256 seriesId) {
        if (strike >= CAP || expiry <= block.timestamp) {
            revert MarginEngine__InvalidParams();
        }

        address proxy = Clones.clone(OPTION_IMPLEMENTATION);
        IOptionToken(proxy).initialize(name, symbol, address(this));

        seriesId = nextSeriesId++;
        series[seriesId] = Series({
            isBull: isBull,
            strike: strike,
            expiry: expiry,
            optionToken: proxy,
            settlementPrice: 0,
            settlementShareRate: 0,
            isSettled: false
        });

        emit SeriesCreated(seriesId, proxy, isBull, strike, expiry);
    }

    /// @notice Writers (DOVs) call this to lock splDXY yield-bearing shares and mint options.
    /// @dev Ensures exact 1:1 backing of the underlying asset capacity.
    function mintOptions(
        uint256 seriesId,
        uint256 optionsAmount
    ) external nonReentrant {
        if (optionsAmount == 0) {
            revert MarginEngine__ZeroAmount();
        }
        Series storage s = series[seriesId];

        if (s.isSettled || block.timestamp >= s.expiry || SPLITTER.currentStatus() == ISyntheticSplitter.Status.SETTLED)
        {
            revert MarginEngine__Expired();
        }

        IERC4626 vault = s.isBull ? STAKED_BULL : STAKED_BEAR;

        // Exact 1:1 Backing: calculate how many shares are needed to fully collateralize `optionsAmount` of underlying assets.
        // previewWithdraw rounds UP natively in ERC4626, ensuring the MarginEngine is always mathematically fully collateralized.
        uint256 sharesToLock = vault.previewWithdraw(optionsAmount);

        // State accounting
        writerLockedShares[seriesId][msg.sender] += sharesToLock;
        writerOptions[seriesId][msg.sender] += optionsAmount;

        // Pull collateral from writer
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), sharesToLock);

        // Mint Option Tokens to Writer
        IOptionToken(s.optionToken).mint(msg.sender, optionsAmount);

        emit OptionsMinted(seriesId, msg.sender, optionsAmount, sharesToLock);
    }

    /// @notice Locks the settlement price and exchange rate at expiration.
    /// @dev Callable by anyone. Triggers "Early Acceleration" if protocol liquidates mid-cycle.
    function settle(
        uint256 seriesId
    ) external {
        Series storage s = series[seriesId];
        if (s.isSettled) {
            revert MarginEngine__AlreadySettled();
        }

        bool isLiquidated = SPLITTER.currentStatus() == ISyntheticSplitter.Status.SETTLED;
        if (block.timestamp < s.expiry && !isLiquidated) {
            revert MarginEngine__NotExpired();
        }
        if (!isLiquidated && block.timestamp > s.expiry + SETTLEMENT_WINDOW) {
            revert MarginEngine__SettlementWindowClosed();
        }

        uint256 price;
        if (isLiquidated) {
            // Early Acceleration logic: Hard boundaries take effect immediately
            price = s.isBull ? 0 : CAP;
        } else {
            (uint256 bearPrice, uint256 bullPrice) = ORACLE.getSettlementPrices();
            price = s.isBull ? bullPrice : bearPrice;
        }

        s.settlementPrice = price;

        // Lock the exchange rate exactly at settlement to cleanly partition post-expiry yield
        IERC4626 vault = s.isBull ? STAKED_BULL : STAKED_BEAR;

        // StakedTokens have 21 decimals (18 underlying + 3 offset).
        uint256 oneShare = 10 ** IERC20Metadata(address(vault)).decimals();
        s.settlementShareRate = vault.convertToAssets(oneShare);

        if (s.settlementShareRate == 0) {
            s.settlementShareRate = 1e18; // Fallback math safety
        }
        s.isSettled = true;

        emit SeriesSettled(seriesId, price, s.settlementShareRate);
    }

    /// @notice Buyers burn ITM Options to extract their fractional payout of the collateral pool.
    function exercise(
        uint256 seriesId,
        uint256 optionsAmount
    ) external nonReentrant {
        if (optionsAmount == 0) {
            revert MarginEngine__ZeroAmount();
        }
        Series storage s = series[seriesId];
        if (!s.isSettled) {
            revert MarginEngine__NotSettled();
        }
        if (s.settlementPrice <= s.strike) {
            revert MarginEngine__OptionIsOTM();
        }

        // Burn Option Tokens
        IOptionToken(s.optionToken).burn(msg.sender, optionsAmount);

        // Fractional Payout Math
        // Calculate the raw underlying asset value owed to the buyer:
        uint256 assetPayout = (optionsAmount * (s.settlementPrice - s.strike)) / s.settlementPrice;

        // Convert the asset payout into equivalent shares using the locked settlement exchange rate:
        uint256 oneShare = 10 ** IERC20Metadata(s.isBull ? address(STAKED_BULL) : address(STAKED_BEAR)).decimals();
        uint256 sharePayout = (assetPayout * oneShare) / s.settlementShareRate;

        IERC20 vault = s.isBull ? IERC20(address(STAKED_BULL)) : IERC20(address(STAKED_BEAR));
        vault.safeTransfer(msg.sender, sharePayout);

        emit OptionsExercised(seriesId, msg.sender, optionsAmount, sharePayout);
    }

    /// @notice Writers unlock their remaining splDXY shares post-settlement.
    /// @dev If OTM, writer retains 100% of their shares + 100% of the accrued Morpho yield.
    function unlockCollateral(
        uint256 seriesId
    ) external nonReentrant {
        Series storage s = series[seriesId];
        if (!s.isSettled) {
            revert MarginEngine__NotSettled();
        }

        uint256 lockedShares = writerLockedShares[seriesId][msg.sender];
        uint256 optionsMinted = writerOptions[seriesId][msg.sender];

        if (lockedShares == 0) {
            revert MarginEngine__ZeroAmount();
        }

        // Checks-Effects
        writerLockedShares[seriesId][msg.sender] = 0;
        writerOptions[seriesId][msg.sender] = 0;

        uint256 sharesOwedToBuyers = 0;
        if (s.settlementPrice > s.strike) {
            uint256 assetPayout = (optionsMinted * (s.settlementPrice - s.strike)) / s.settlementPrice;

            uint256 oneShare = 10 ** IERC20Metadata(s.isBull ? address(STAKED_BULL) : address(STAKED_BEAR)).decimals();
            sharesOwedToBuyers = (assetPayout * oneShare) / s.settlementShareRate;
        }

        // Writer retains exactly what is left after fulfilling their buyer obligations
        uint256 sharesToReturn = lockedShares > sharesOwedToBuyers ? lockedShares - sharesOwedToBuyers : 0;

        if (sharesToReturn > 0) {
            IERC20 vault = s.isBull ? IERC20(address(STAKED_BULL)) : IERC20(address(STAKED_BEAR));
            vault.safeTransfer(msg.sender, sharesToReturn);
        }

        emit CollateralUnlocked(seriesId, msg.sender, optionsMinted, sharesToReturn);
    }

}
