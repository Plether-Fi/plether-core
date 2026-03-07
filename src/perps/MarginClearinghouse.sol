// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAssetOracle {

    /// @notice Returns the price of the asset in 8-decimal USD
    function getPriceUnsafe() external view returns (uint256);

}

/// @title MarginClearinghouse
/// @notice Universal cross-margin account manager for Plether.
/// @dev Calculates total Account Equity using LTV haircuts. V1 strictly uses USDC.
/// @custom:security-contact contact@plether.com
contract MarginClearinghouse is Ownable2Step {

    using SafeERC20 for IERC20;

    struct AssetConfig {
        bool isSupported;
        uint8 decimals;
        uint16 ltvBps;
        address oracle;
    }

    mapping(address => AssetConfig) public assetConfigs;
    address[] public supportedAssetsList;

    mapping(bytes32 => mapping(address => uint256)) public balances;

    mapping(bytes32 => uint256) public lockedMarginUsdc;

    mapping(address => bool) public isProtocolOperator;

    error MarginClearinghouse__NotOperator();
    error MarginClearinghouse__InvalidLTV();
    error MarginClearinghouse__NotAccountOwner();
    error MarginClearinghouse__AssetNotSupported();
    error MarginClearinghouse__ZeroAmount();
    error MarginClearinghouse__InsufficientBalance();
    error MarginClearinghouse__InsufficientFreeEquity();
    error MarginClearinghouse__InsufficientUsdcForSettlement();
    error MarginClearinghouse__InsufficientAssetToSeize();

    event Deposit(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event Withdraw(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event MarginLocked(bytes32 indexed accountId, uint256 amountUsdc);
    event MarginUnlocked(bytes32 indexed accountId, uint256 amountUsdc);
    event AssetSeized(bytes32 indexed accountId, address indexed asset, uint256 amount, address recipient);

    modifier onlyOperator() {
        if (!isProtocolOperator[msg.sender]) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    constructor() Ownable(msg.sender) {}

    // ==========================================
    // CONFIGURATION
    // ==========================================

    function setOperator(
        address operator,
        bool status
    ) external onlyOwner {
        isProtocolOperator[operator] = status;
    }

    function supportAsset(
        address asset,
        uint8 decimals,
        uint16 ltvBps,
        address oracle
    ) external onlyOwner {
        if (ltvBps > 10_000) {
            revert MarginClearinghouse__InvalidLTV();
        }

        if (!assetConfigs[asset].isSupported) {
            supportedAssetsList.push(asset);
        }

        assetConfigs[asset] = AssetConfig({isSupported: true, decimals: decimals, ltvBps: ltvBps, oracle: oracle});
    }

    // ==========================================
    // USER ACTIONS
    // ==========================================

    /// @notice Deposits a supported asset into the specified margin account.
    ///         Uses balance-before/after pattern to support fee-on-transfer tokens.
    function deposit(
        bytes32 accountId,
        address asset,
        uint256 amount
    ) external {
        if (bytes32(uint256(uint160(msg.sender))) != accountId) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (!assetConfigs[asset].isSupported) {
            revert MarginClearinghouse__AssetNotSupported();
        }
        if (amount == 0) {
            revert MarginClearinghouse__ZeroAmount();
        }

        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
        balances[accountId][asset] += received;

        emit Deposit(accountId, asset, received);
    }

    /// @notice Withdraws assets from a margin account. Only callable by the account owner.
    ///         Reverts if withdrawal would push equity below locked margin requirements.
    function withdraw(
        bytes32 accountId,
        address asset,
        uint256 amount
    ) external {
        if (bytes32(uint256(uint160(msg.sender))) != accountId) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (balances[accountId][asset] < amount) {
            revert MarginClearinghouse__InsufficientBalance();
        }

        balances[accountId][asset] -= amount;

        uint256 remainingEquity = getAccountEquityUsdc(accountId);
        if (remainingEquity < lockedMarginUsdc[accountId]) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdraw(accountId, asset, amount);
    }

    // ==========================================
    // VALUATION ENGINE
    // ==========================================

    /// @notice Returns the total USD Buying Power of the account (6 decimals)
    function getAccountEquityUsdc(
        bytes32 accountId
    ) public view returns (uint256 totalEquityUsdc) {
        uint256 length = supportedAssetsList.length;

        for (uint256 i = 0; i < length; i++) {
            address asset = supportedAssetsList[i];
            uint256 bal = balances[accountId][asset];

            if (bal > 0) {
                AssetConfig memory config = assetConfigs[asset];
                uint256 usdValue;

                if (config.oracle == address(0)) {
                    usdValue = bal;
                } else {
                    uint256 price8 = IAssetOracle(config.oracle).getPriceUnsafe();
                    usdValue = (bal * price8) / (10 ** (uint256(config.decimals) + 2));
                }

                uint256 discountedValue = (usdValue * config.ltvBps) / 10_000;
                totalEquityUsdc += discountedValue;
            }
        }
    }

    /// @notice Returns strictly unencumbered purchasing power
    function getFreeBuyingPowerUsdc(
        bytes32 accountId
    ) public view returns (uint256) {
        uint256 equity = getAccountEquityUsdc(accountId);
        uint256 locked = lockedMarginUsdc[accountId];
        return equity > locked ? equity - locked : 0;
    }

    // ==========================================
    // PROTOCOL INTEGRATION (OrderRouter / Engine)
    // ==========================================

    /// @notice Locks margin to back a new CFD trade
    function lockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (getFreeBuyingPowerUsdc(accountId) < amountUsdc) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        lockedMarginUsdc[accountId] += amountUsdc;
        emit MarginLocked(accountId, amountUsdc);
    }

    /// @notice Unlocks margin when a CFD trade closes
    function unlockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (lockedMarginUsdc[accountId] >= amountUsdc) {
            lockedMarginUsdc[accountId] -= amountUsdc;
        } else {
            lockedMarginUsdc[accountId] = 0;
        }
        emit MarginUnlocked(accountId, amountUsdc);
    }

    /// @notice Adjusts USDC balance to settle funding, PnL, and VPI rebates.
    ///         Positive amounts credit the account; negative amounts debit it.
    function settleUsdc(
        bytes32 accountId,
        address usdc,
        int256 amount
    ) external onlyOperator {
        if (amount > 0) {
            balances[accountId][usdc] += uint256(amount);
        } else if (amount < 0) {
            uint256 loss = uint256(-amount);
            if (balances[accountId][usdc] < loss) {
                revert MarginClearinghouse__InsufficientUsdcForSettlement();
            }
            balances[accountId][usdc] -= loss;
        }
    }

    /// @notice Transfers assets from an account to a recipient (losses, fees, VPI charges, or bad debt)
    function seizeAsset(
        bytes32 accountId,
        address asset,
        uint256 amount,
        address recipient
    ) external onlyOperator {
        if (balances[accountId][asset] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        balances[accountId][asset] -= amount;
        IERC20(asset).safeTransfer(recipient, amount);

        emit AssetSeized(accountId, asset, amount, recipient);
    }

}
