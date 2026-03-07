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
contract MarginClearinghouse is Ownable2Step {

    using SafeERC20 for IERC20;

    struct AssetConfig {
        bool isSupported;
        uint8 decimals;
        uint16 ltvBps; // e.g., 9500 = 95% Loan-to-Value haircut
        address oracle; // Address of the pricing oracle (address(0) for USDC)
    }

    // Asset Whitelist
    mapping(address => AssetConfig) public assetConfigs;
    address[] public supportedAssetsList;

    // accountId => (asset => amount)
    mapping(bytes32 => mapping(address => uint256)) public balances;

    // Total buying power currently locked by active CFD positions (in 6-decimal USDC)
    mapping(bytes32 => uint256) public lockedMarginUsdc;

    // Authorized protocol contracts (Router / Engine)
    mapping(address => bool) public isProtocolOperator;

    event Deposit(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event Withdraw(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event MarginLocked(bytes32 indexed accountId, uint256 amountUsdc);
    event MarginUnlocked(bytes32 indexed accountId, uint256 amountUsdc);
    event AssetSeized(bytes32 indexed accountId, address indexed asset, uint256 amount, address recipient);

    modifier onlyOperator() {
        require(isProtocolOperator[msg.sender], "Clearinghouse: Not Protocol Operator");
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
        require(ltvBps <= 10_000, "Invalid LTV");

        if (!assetConfigs[asset].isSupported) {
            supportedAssetsList.push(asset);
        }

        assetConfigs[asset] = AssetConfig({isSupported: true, decimals: decimals, ltvBps: ltvBps, oracle: oracle});
    }

    // ==========================================
    // USER ACTIONS
    // ==========================================

    function deposit(
        bytes32 accountId,
        address asset,
        uint256 amount
    ) external {
        require(assetConfigs[asset].isSupported, "Clearinghouse: Asset not supported");
        require(amount > 0, "Clearinghouse: Zero amount");

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        balances[accountId][asset] += amount;

        emit Deposit(accountId, asset, amount);
    }

    function withdraw(
        bytes32 accountId,
        address asset,
        uint256 amount
    ) external {
        // V1: Enforce strict identity mapping (msg.sender == accountId)
        require(bytes32(uint256(uint160(msg.sender))) == accountId, "Clearinghouse: Not account owner");
        require(balances[accountId][asset] >= amount, "Clearinghouse: Insufficient balance");

        // Optimistically deduct balance to check resulting buying power
        balances[accountId][asset] -= amount;

        // Ensure withdrawal doesn't push equity below locked margin requirements
        uint256 remainingEquity = getAccountEquityUsdc(accountId);
        require(remainingEquity >= lockedMarginUsdc[accountId], "Clearinghouse: Insufficient free equity");

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

                // Fast-path for Pristine USDC (1:1 valuation, no oracle needed)
                if (config.oracle == address(0)) {
                    // Assuming asset is 6 decimals like USDC
                    usdValue = bal;
                } else {
                    // Fetch oracle price (8 decimals)
                    uint256 price8 = IAssetOracle(config.oracle).getPriceUnsafe();

                    // Normalize to 6-decimal USD Value
                    // Decimal Math: Token(D) * Price(8) / 10^(D + 8 - 6) => USDC(6)
                    usdValue = (bal * price8) / (10 ** (uint256(config.decimals) + 2));
                }

                // Apply LTV Haircut (e.g., 9500 = 95%)
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
        require(getFreeBuyingPowerUsdc(accountId) >= amountUsdc, "Clearinghouse: Insufficient free equity");
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

    /// @notice Directly alters USDC balances to settle Funding Rates and Realized PnL
    function settleUsdc(
        bytes32 accountId,
        address usdc,
        int256 amount
    ) external onlyOperator {
        if (amount > 0) {
            balances[accountId][usdc] += uint256(amount);
        } else if (amount < 0) {
            uint256 loss = uint256(-amount);
            require(balances[accountId][usdc] >= loss, "Clearinghouse: Insufficient USDC for settlement");
            balances[accountId][usdc] -= loss;
        }
    }

    /// @notice Seizes raw assets from the account to pay House Pool bad debt
    function seizeAsset(
        bytes32 accountId,
        address asset,
        uint256 amount,
        address recipient
    ) external onlyOperator {
        require(balances[accountId][asset] >= amount, "Clearinghouse: Insufficient asset balance to seize");

        balances[accountId][asset] -= amount;
        IERC20(asset).safeTransfer(recipient, amount);

        emit AssetSeized(accountId, asset, amount, recipient);
    }

}
