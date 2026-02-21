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

    function getSettlementPrices(
        uint256 expiry,
        uint80[] calldata roundHints
    ) external view returns (uint256 bearPrice, uint256 bullPrice);

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
        uint256 settlementShareRate;
        bool isSettled;
        uint256 mintShareRate; // Share rate snapshot from first mint — informational only.
            // Settlement uses a fresh vault rate at settle time for economically correct payouts.
    }

    ISyntheticSplitter public immutable SPLITTER;
    ISettlementOracle public immutable ORACLE;
    IERC4626 public immutable STAKED_BEAR;
    IERC4626 public immutable STAKED_BULL;
    address public immutable OPTION_IMPLEMENTATION;
    uint256 public immutable CAP;

    uint256 public nextSeriesId = 1;
    mapping(uint256 => Series) public series;

    // seriesId => writer => amount of splDXY shares locked
    mapping(uint256 => mapping(address => uint256)) public writerLockedShares;

    // seriesId => writer => amount of options minted
    mapping(uint256 => mapping(address => uint256)) public writerOptions;

    // Per-series collateral tracking for exercise cap (prevents cross-series drain from negative yield)
    mapping(uint256 => uint256) public totalSeriesShares;
    mapping(uint256 => uint256) public totalSeriesMinted;
    mapping(uint256 => uint256) public totalSeriesExercisedShares;
    mapping(uint256 => uint256) public settlementTimestamp;

    event SeriesCreated(uint256 indexed seriesId, address optionToken, bool isBull, uint256 strike, uint256 expiry);
    event OptionsMinted(uint256 indexed seriesId, address indexed writer, uint256 optionsAmount, uint256 sharesLocked);
    event SeriesSettled(uint256 indexed seriesId, uint256 settlementPrice, uint256 settlementShareRate);
    event OptionsExercised(
        uint256 indexed seriesId, address indexed buyer, uint256 optionsAmount, uint256 sharesReceived
    );
    event CollateralUnlocked(
        uint256 indexed seriesId, address indexed writer, uint256 optionsAmount, uint256 sharesReturned
    );
    event UnclaimedSharesSwept(uint256 indexed seriesId, uint256 sharesSwept);

    error MarginEngine__InvalidParams();
    error MarginEngine__Expired();
    error MarginEngine__NotExpired();
    error MarginEngine__AlreadySettled();
    error MarginEngine__NotSettled();
    error MarginEngine__OptionIsOTM();
    error MarginEngine__ZeroAmount();
    error MarginEngine__SplitterNotActive();
    error MarginEngine__AdminSettleTooEarly();
    error MarginEngine__SweepTooEarly();

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
        if (strike == 0 || strike >= CAP || expiry <= block.timestamp) {
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
            isSettled: false,
            mintShareRate: 0
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

        if (s.mintShareRate == 0) {
            uint256 oneShare = 10 ** IERC20Metadata(address(vault)).decimals();
            s.mintShareRate = vault.convertToAssets(oneShare);
            if (s.mintShareRate == 0) {
                s.mintShareRate = oneShare;
            }
        }

        uint256 sharesToLock = vault.previewWithdraw(optionsAmount);

        // State accounting
        writerLockedShares[seriesId][msg.sender] += sharesToLock;
        writerOptions[seriesId][msg.sender] += optionsAmount;
        totalSeriesShares[seriesId] += sharesToLock;
        totalSeriesMinted[seriesId] += optionsAmount;

        // Pull collateral from writer
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), sharesToLock);

        // Mint Option Tokens to Writer
        IOptionToken(s.optionToken).mint(msg.sender, optionsAmount);

        emit OptionsMinted(seriesId, msg.sender, optionsAmount, sharesToLock);
    }

    /// @notice Locks the settlement price and exchange rate at expiration.
    /// @dev Callable by anyone. Triggers "Early Acceleration" if protocol liquidates mid-cycle.
    /// @param roundHints Chainlink round IDs for oracle lookup (one per feed component).
    function settle(
        uint256 seriesId,
        uint80[] calldata roundHints
    ) external {
        Series storage s = series[seriesId];
        if (s.isSettled) {
            revert MarginEngine__AlreadySettled();
        }

        bool isLiquidated = SPLITTER.currentStatus() == ISyntheticSplitter.Status.SETTLED;
        if (block.timestamp < s.expiry && !isLiquidated) {
            revert MarginEngine__NotExpired();
        }

        uint256 price;
        if (isLiquidated && SPLITTER.liquidationTimestamp() <= s.expiry) {
            price = s.isBull ? 0 : CAP;
        } else {
            (uint256 bearPrice, uint256 bullPrice) = ORACLE.getSettlementPrices(s.expiry, roundHints);
            price = s.isBull ? bullPrice : bearPrice;
        }

        s.settlementPrice = price;
        IERC4626 vault = s.isBull ? STAKED_BULL : STAKED_BEAR;
        uint256 oneShare = 10 ** IERC20Metadata(address(vault)).decimals();
        uint256 currentRate = vault.convertToAssets(oneShare);
        s.settlementShareRate = currentRate > 0 ? currentRate : oneShare;
        s.isSettled = true;
        settlementTimestamp[seriesId] = block.timestamp;

        emit SeriesSettled(seriesId, price, s.settlementShareRate);
    }

    /// @notice Admin fallback for oracle failures — settles with a manually provided price.
    /// @dev 2-day grace period after expiry gives the oracle time to recover first.
    function adminSettle(
        uint256 seriesId,
        uint256 settlementPrice
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Series storage s = series[seriesId];
        if (s.isSettled) {
            revert MarginEngine__AlreadySettled();
        }
        if (block.timestamp < s.expiry + 2 days) {
            revert MarginEngine__AdminSettleTooEarly();
        }
        if (settlementPrice > CAP) {
            revert MarginEngine__InvalidParams();
        }

        s.settlementPrice = settlementPrice;
        IERC4626 vault = s.isBull ? STAKED_BULL : STAKED_BEAR;
        uint256 oneShare = 10 ** IERC20Metadata(address(vault)).decimals();
        uint256 currentRate = vault.convertToAssets(oneShare);
        s.settlementShareRate = currentRate > 0 ? currentRate : oneShare;
        s.isSettled = true;
        settlementTimestamp[seriesId] = block.timestamp;

        emit SeriesSettled(seriesId, settlementPrice, s.settlementShareRate);
    }

    /// @notice Buyers burn ITM Options to extract their fractional payout of the collateral pool.
    /// @dev Share conversion uses the settlement-time rate for economically correct payouts.
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
        if (block.timestamp >= settlementTimestamp[seriesId] + 90 days) {
            revert MarginEngine__Expired();
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

        // Cap payout to this series' pro-rata share of collateral (prevents cross-series drain on negative yield)
        uint256 maxPayout = (optionsAmount * totalSeriesShares[seriesId]) / totalSeriesMinted[seriesId];
        if (sharePayout > maxPayout) {
            sharePayout = maxPayout;
        }

        totalSeriesExercisedShares[seriesId] += sharePayout;

        IERC20 vault = s.isBull ? IERC20(address(STAKED_BULL)) : IERC20(address(STAKED_BEAR));
        vault.safeTransfer(msg.sender, sharePayout);

        emit OptionsExercised(seriesId, msg.sender, optionsAmount, sharePayout);
    }

    /// @notice Writers unlock their remaining splDXY shares post-settlement.
    /// @dev Uses global debt pro-rata to stay consistent with the exercise cap.
    ///      `globalDebtShares` represents the theoretical max debt assuming 100% exercise.
    ///      If some option holders don't exercise, their unclaimed share of `globalDebtShares`
    ///      remains locked until `sweepUnclaimedShares` is called after 90 days.
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

        writerLockedShares[seriesId][msg.sender] = 0;
        writerOptions[seriesId][msg.sender] = 0;

        uint256 totalMinted = totalSeriesMinted[seriesId];
        uint256 totalShares = totalSeriesShares[seriesId];
        uint256 globalDebtShares = 0;

        if (s.settlementPrice > s.strike) {
            uint256 assetPayout = (totalMinted * (s.settlementPrice - s.strike)) / s.settlementPrice;
            uint256 oneShare = 10 ** IERC20Metadata(s.isBull ? address(STAKED_BULL) : address(STAKED_BEAR)).decimals();
            globalDebtShares = (assetPayout * oneShare) / s.settlementShareRate;
            if (globalDebtShares > totalShares) {
                globalDebtShares = totalShares;
            }
        }

        uint256 remainingPool = totalShares - globalDebtShares;
        uint256 sharesToReturn = (remainingPool * lockedShares) / totalShares;

        if (sharesToReturn > 0) {
            IERC20 vault = s.isBull ? IERC20(address(STAKED_BULL)) : IERC20(address(STAKED_BEAR));
            vault.safeTransfer(msg.sender, sharesToReturn);
        }

        emit CollateralUnlocked(seriesId, msg.sender, optionsMinted, sharesToReturn);
    }

    /// @notice Sweeps unclaimed exercise shares 90 days after settlement.
    /// @dev Returns shares reserved for unexercised ITM options to the admin for distribution.
    function sweepUnclaimedShares(
        uint256 seriesId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        Series storage s = series[seriesId];
        if (!s.isSettled) {
            revert MarginEngine__NotSettled();
        }
        if (block.timestamp < settlementTimestamp[seriesId] + 90 days) {
            revert MarginEngine__SweepTooEarly();
        }

        uint256 totalMinted = totalSeriesMinted[seriesId];
        uint256 totalShares = totalSeriesShares[seriesId];
        uint256 globalDebtShares = 0;

        if (s.settlementPrice > s.strike) {
            uint256 assetPayout = (totalMinted * (s.settlementPrice - s.strike)) / s.settlementPrice;
            uint256 oneShare = 10 ** IERC20Metadata(s.isBull ? address(STAKED_BULL) : address(STAKED_BEAR)).decimals();
            globalDebtShares = (assetPayout * oneShare) / s.settlementShareRate;
            if (globalDebtShares > totalShares) {
                globalDebtShares = totalShares;
            }
        }

        uint256 unclaimedShares = globalDebtShares - totalSeriesExercisedShares[seriesId];
        if (unclaimedShares == 0) {
            revert MarginEngine__ZeroAmount();
        }

        totalSeriesExercisedShares[seriesId] += unclaimedShares;

        IERC20 vault = s.isBull ? IERC20(address(STAKED_BULL)) : IERC20(address(STAKED_BEAR));
        vault.safeTransfer(msg.sender, unclaimedShares);

        emit UnclaimedSharesSwept(seriesId, unclaimedShares);
    }

}
