// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
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

    IWithdrawGuard public withdrawGuard;

    mapping(address => bool) public isProtocolOperator;

    address public immutable settlementAsset;

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    address public pendingOperatorAddress;
    bool public pendingOperatorStatus;
    uint256 public operatorActivationTime;

    address public pendingWithdrawGuard;
    uint256 public withdrawGuardActivationTime;

    address public pendingAsset;
    uint8 public pendingAssetDecimals;
    uint16 public pendingAssetLtvBps;
    address public pendingAssetOracle;
    uint256 public assetConfigActivationTime;

    error MarginClearinghouse__NotOperator();
    error MarginClearinghouse__InvalidLTV();
    error MarginClearinghouse__NotAccountOwner();
    error MarginClearinghouse__AssetNotSupported();
    error MarginClearinghouse__ZeroAmount();
    error MarginClearinghouse__InsufficientBalance();
    error MarginClearinghouse__InsufficientFreeEquity();
    error MarginClearinghouse__InsufficientUsdcForSettlement();
    error MarginClearinghouse__InsufficientAssetToSeize();
    error MarginClearinghouse__TimelockNotReady();
    error MarginClearinghouse__NoProposal();

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

    /// @param _settlementAsset USDC address used for PnL settlement and margin backing
    constructor(
        address _settlementAsset
    ) Ownable(msg.sender) {
        settlementAsset = _settlementAsset;
    }

    // ==========================================
    // CONFIGURATION
    // ==========================================

    /// @notice Proposes granting or revoking operator privileges (48h timelock)
    function proposeOperator(
        address operator,
        bool status
    ) external onlyOwner {
        pendingOperatorAddress = operator;
        pendingOperatorStatus = status;
        operatorActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    /// @notice Finalizes the pending operator proposal after timelock expires
    function finalizeOperator() external onlyOwner {
        if (operatorActivationTime == 0) {
            revert MarginClearinghouse__NoProposal();
        }
        if (block.timestamp < operatorActivationTime) {
            revert MarginClearinghouse__TimelockNotReady();
        }
        isProtocolOperator[pendingOperatorAddress] = pendingOperatorStatus;
        pendingOperatorAddress = address(0);
        pendingOperatorStatus = false;
        operatorActivationTime = 0;
    }

    /// @notice Cancels the pending operator proposal
    function cancelOperatorProposal() external onlyOwner {
        pendingOperatorAddress = address(0);
        pendingOperatorStatus = false;
        operatorActivationTime = 0;
    }

    /// @notice Proposes a new withdraw guard contract (48h timelock)
    function proposeWithdrawGuard(
        address _guard
    ) external onlyOwner {
        pendingWithdrawGuard = _guard;
        withdrawGuardActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    /// @notice Finalizes the pending withdraw guard proposal after timelock expires
    function finalizeWithdrawGuard() external onlyOwner {
        if (withdrawGuardActivationTime == 0) {
            revert MarginClearinghouse__NoProposal();
        }
        if (block.timestamp < withdrawGuardActivationTime) {
            revert MarginClearinghouse__TimelockNotReady();
        }
        withdrawGuard = IWithdrawGuard(pendingWithdrawGuard);
        pendingWithdrawGuard = address(0);
        withdrawGuardActivationTime = 0;
    }

    /// @notice Cancels the pending withdraw guard proposal
    function cancelWithdrawGuardProposal() external onlyOwner {
        pendingWithdrawGuard = address(0);
        withdrawGuardActivationTime = 0;
    }

    /// @notice Proposes adding or updating a collateral asset configuration (48h timelock)
    /// @param ltvBps Loan-to-value haircut in basis points (max 10000)
    /// @param oracle Price feed returning 8-decimal USD price, or address(0) for stablecoins
    function proposeAssetConfig(
        address asset,
        uint8 decimals,
        uint16 ltvBps,
        address oracle
    ) external onlyOwner {
        if (ltvBps > 10_000) {
            revert MarginClearinghouse__InvalidLTV();
        }
        pendingAsset = asset;
        pendingAssetDecimals = decimals;
        pendingAssetLtvBps = ltvBps;
        pendingAssetOracle = oracle;
        assetConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    /// @notice Finalizes the pending asset config proposal after timelock expires
    function finalizeAssetConfig() external onlyOwner {
        if (assetConfigActivationTime == 0) {
            revert MarginClearinghouse__NoProposal();
        }
        if (block.timestamp < assetConfigActivationTime) {
            revert MarginClearinghouse__TimelockNotReady();
        }
        address asset = pendingAsset;
        if (!assetConfigs[asset].isSupported) {
            supportedAssetsList.push(asset);
        }
        assetConfigs[asset] = AssetConfig({
            isSupported: true, decimals: pendingAssetDecimals, ltvBps: pendingAssetLtvBps, oracle: pendingAssetOracle
        });
        pendingAsset = address(0);
        pendingAssetDecimals = 0;
        pendingAssetLtvBps = 0;
        pendingAssetOracle = address(0);
        assetConfigActivationTime = 0;
    }

    /// @notice Cancels the pending asset config proposal
    function cancelAssetConfigProposal() external onlyOwner {
        pendingAsset = address(0);
        pendingAssetDecimals = 0;
        pendingAssetLtvBps = 0;
        pendingAssetOracle = address(0);
        assetConfigActivationTime = 0;
    }

    // ==========================================
    // USER ACTIONS
    // ==========================================

    /// @notice Deposits a supported asset into the specified margin account.
    ///         Uses balance-before/after pattern to support fee-on-transfer tokens.
    /// @param accountId Deterministic account ID derived from msg.sender address
    /// @param asset ERC20 token to deposit (must be in supportedAssetsList)
    /// @param amount Token amount to transfer in (actual credited amount may differ for fee-on-transfer)
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
    /// @param accountId Deterministic account ID derived from msg.sender address
    /// @param asset ERC20 token to withdraw
    /// @param amount Token amount to withdraw
    function withdraw(
        bytes32 accountId,
        address asset,
        uint256 amount
    ) external {
        if (bytes32(uint256(uint160(msg.sender))) != accountId) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (address(withdrawGuard) != address(0)) {
            withdrawGuard.checkWithdraw(accountId);
        }
        if (balances[accountId][asset] < amount) {
            revert MarginClearinghouse__InsufficientBalance();
        }

        balances[accountId][asset] -= amount;

        if (address(withdrawGuard) != address(0)) {
            withdrawGuard.checkWithdraw(accountId);
        }

        uint256 remainingEquity = getAccountEquityUsdc(accountId);
        if (remainingEquity < lockedMarginUsdc[accountId]) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (balances[accountId][settlementAsset] < lockedMarginUsdc[accountId]) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdraw(accountId, asset, amount);
    }

    // ==========================================
    // VALUATION ENGINE
    // ==========================================

    /// @notice Returns the total USD Buying Power of the account (6 decimals)
    /// @param accountId Account to value
    /// @return totalEquityUsdc Sum of all asset balances valued in USDC with LTV haircuts applied
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
                    usdValue = bal * 1e6 / (10 ** uint256(config.decimals));
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
    /// @param accountId Account to query
    /// @return Equity minus locked margin, floored at zero (6 decimals)
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

    /// @notice Locks margin to back a new CFD trade.
    ///         Requires sufficient USDC to back settlement (non-USDC equity alone is insufficient).
    /// @param accountId Account to lock margin on
    /// @param amountUsdc USDC amount to lock (6 decimals)
    function lockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (getFreeBuyingPowerUsdc(accountId) < amountUsdc) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (balances[accountId][settlementAsset] < lockedMarginUsdc[accountId] + amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        lockedMarginUsdc[accountId] += amountUsdc;
        emit MarginLocked(accountId, amountUsdc);
    }

    /// @notice Unlocks margin when a CFD trade closes
    /// @param accountId Account to unlock margin on
    /// @param amountUsdc USDC amount to unlock (6 decimals), clamped to current locked amount
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
    /// @param accountId Account to settle
    /// @param usdc Settlement token address (must match settlementAsset in practice)
    /// @param amount Signed USDC delta: positive credits, negative debits (6 decimals)
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
    /// @param accountId Account to seize from
    /// @param asset ERC20 token to seize
    /// @param amount Token amount to seize
    /// @param recipient Address to receive the seized tokens
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
