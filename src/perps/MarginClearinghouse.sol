// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
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

    struct SettlementConsumption {
        uint256 freeSettlementConsumedUsdc;
        uint256 activeMarginConsumedUsdc;
        uint256 totalConsumedUsdc;
        uint256 uncoveredUsdc;
    }

    mapping(address => AssetConfig) public assetConfigs;
    address[] public supportedAssetsList;

    mapping(bytes32 => mapping(address => uint256)) public balances;

    mapping(bytes32 => uint256) public lockedMarginUsdc;
    mapping(bytes32 => uint256) public reservedSettlementUsdc;

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
    error MarginClearinghouse__InvalidSeizeRecipient();
    error MarginClearinghouse__TimelockNotReady();
    error MarginClearinghouse__NoProposal();

    event Deposit(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event Withdraw(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event MarginLocked(bytes32 indexed accountId, uint256 amountUsdc);
    event MarginUnlocked(bytes32 indexed accountId, uint256 amountUsdc);
    event SettlementReserved(bytes32 indexed accountId, uint256 amountUsdc);
    event SettlementReserveReleased(bytes32 indexed accountId, uint256 amountUsdc);
    event SettlementReservePaid(bytes32 indexed accountId, uint256 amountUsdc, address recipient);
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
        if (balances[accountId][asset] < amount) {
            revert MarginClearinghouse__InsufficientBalance();
        }
        if (!assetConfigs[asset].isSupported) {
            revert MarginClearinghouse__AssetNotSupported();
        }

        balances[accountId][asset] -= amount;

        if (address(withdrawGuard) != address(0)) {
            withdrawGuard.checkWithdraw(accountId);
        }

        uint256 remainingEquity = getAccountEquityUsdc(accountId);
        uint256 reserved = reservedSettlementUsdc[accountId];
        if (remainingEquity < lockedMarginUsdc[accountId] + reserved) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (balances[accountId][settlementAsset] < lockedMarginUsdc[accountId] + reserved) {
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
        uint256 encumbered = lockedMarginUsdc[accountId] + reservedSettlementUsdc[accountId];
        return equity > encumbered ? equity - encumbered : 0;
    }

    /// @notice Returns free settlement balance after subtracting locked margin.
    /// @dev This is the physically reachable USDC left after backing active positions.
    ///      It differs from `getFreeBuyingPowerUsdc` by ignoring non-USDC collateral value.
    function getAccountUsdcBuckets(
        bytes32 accountId,
        uint256 activePositionMarginUsdc
    ) public view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets = _buildAccountUsdcBuckets(accountId, activePositionMarginUsdc);
    }

    function getFreeSettlementBalanceUsdc(
        bytes32 accountId
    ) public view returns (uint256) {
        return getAccountUsdcBuckets(accountId, 0).freeSettlementUsdc;
    }

    /// @notice Returns settlement balance reachable by a liquidation or other terminal settlement path.
    /// @dev Protects only reserved execution-bounty escrow; same-account committed margin remains reachable.
    function getLiquidationReachableUsdc(
        bytes32 accountId,
        uint256 positionMarginUsdc
    ) public view returns (uint256) {
        return MarginClearinghouseAccountingLib.getLiquidationReachableUsdc(_buildAccountUsdcBuckets(accountId, positionMarginUsdc));
    }

    /// @notice Returns settlement balance reachable after protecting only an explicitly remaining margin bucket.
    /// @dev This is the canonical helper for terminal settlement paths: full closes and liquidations
    ///      should pass zero protected margin, while partial closes should protect only the residual
    ///      position margin that remains open after settlement.
    function getSettlementReachableUsdc(
        bytes32 accountId,
        uint256 protectedLockedMarginUsdc
    ) public view returns (uint256) {
        return MarginClearinghouseAccountingLib.getSettlementReachableUsdc(
            _buildAccountUsdcBuckets(accountId, 0), protectedLockedMarginUsdc
        );
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
        _lockMargin(accountId, amountUsdc);
    }

    /// @notice Unlocks margin when a CFD trade closes
    /// @param accountId Account to unlock margin on
    /// @param amountUsdc USDC amount to unlock (6 decimals), clamped to current locked amount
    function unlockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _unlockMargin(accountId, amountUsdc);
    }

    /// @notice Adjusts USDC balance to settle funding, PnL, and VPI rebates.
    ///         Positive amounts credit the account; negative amounts debit it.
    /// @dev Restricted to the configured settlement asset so operators cannot mutate
    ///      arbitrary asset ledgers via the settlement path.
    /// @param accountId Account to settle
    /// @param usdc Settlement token address (must equal settlementAsset)
    /// @param amount Signed USDC delta: positive credits, negative debits (6 decimals)
    function settleUsdc(
        bytes32 accountId,
        address usdc,
        int256 amount
    ) external onlyOperator {
        if (usdc != settlementAsset || !assetConfigs[usdc].isSupported) {
            revert MarginClearinghouse__AssetNotSupported();
        }
        if (amount > 0) {
            _creditSettlementUsdc(accountId, uint256(amount));
        } else if (amount < 0) {
            _debitSettlementUsdc(accountId, uint256(-amount));
        }
    }

    function reserveSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }
        uint256 balance = balances[accountId][settlementAsset];
        uint256 encumbered = lockedMarginUsdc[accountId] + reservedSettlementUsdc[accountId];
        if (balance < encumbered + amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        reservedSettlementUsdc[accountId] += amountUsdc;
        emit SettlementReserved(accountId, amountUsdc);
    }

    function releaseReservedSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }
        uint256 reserved = reservedSettlementUsdc[accountId];
        reservedSettlementUsdc[accountId] = reserved > amountUsdc ? reserved - amountUsdc : 0;
        emit SettlementReserveReleased(accountId, amountUsdc);
    }

    function payReservedSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc,
        address recipient
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }
        if (reservedSettlementUsdc[accountId] < amountUsdc || balances[accountId][settlementAsset] < amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        reservedSettlementUsdc[accountId] -= amountUsdc;
        balances[accountId][settlementAsset] -= amountUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, amountUsdc);
        emit SettlementReservePaid(accountId, amountUsdc, recipient);
    }

    /// @notice Credits settlement USDC and locks the same amount as active margin.
    function creditSettlementAndLockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }

        _creditSettlementUsdc(accountId, amountUsdc);
        _lockMargin(accountId, amountUsdc);
    }

    /// @notice Applies an open/increase trade cost by debiting or crediting settlement and updating locked margin.
    function applyOpenCost(
        bytes32 accountId,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient
    ) external onlyOperator returns (int256 netMarginChangeUsdc) {
        if (tradeCostUsdc > 0) {
            uint256 costUsdc = uint256(tradeCostUsdc);
            if (costUsdc > getFreeSettlementBalanceUsdc(accountId)) {
                revert MarginClearinghouse__InsufficientFreeEquity();
            }
            balances[accountId][settlementAsset] -= costUsdc;
            IERC20(settlementAsset).safeTransfer(recipient, costUsdc);
            emit AssetSeized(accountId, settlementAsset, costUsdc, recipient);
        } else if (tradeCostUsdc < 0) {
            _creditSettlementUsdc(accountId, uint256(-tradeCostUsdc));
        }

        netMarginChangeUsdc = int256(marginDeltaUsdc) - tradeCostUsdc;
        if (netMarginChangeUsdc > 0) {
            _lockMargin(accountId, uint256(netMarginChangeUsdc));
        } else if (netMarginChangeUsdc < 0) {
            _unlockMargin(accountId, uint256(-netMarginChangeUsdc));
        }
    }

    /// @notice Consumes a funding loss from free settlement first, then from the active position margin bucket.
    /// @dev Reserved settlement and unrelated locked margin remain protected.
    function consumeFundingLoss(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc,
        address recipient
    ) external onlyOperator returns (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc) {
        if (lossUsdc == 0) {
            return (0, 0, 0);
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            _planFundingLossConsumption(accountId, lockedPositionMarginUsdc, lossUsdc);
        freeSettlementConsumedUsdc = consumption.freeSettlementConsumedUsdc;
        marginConsumedUsdc = consumption.activeMarginConsumedUsdc;
        uncoveredUsdc = consumption.uncoveredUsdc;
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = _buildAccountUsdcBuckets(accountId, lockedPositionMarginUsdc);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyFundingLossMutation(buckets, consumption);

        if (mutation.activeMarginUnlockedUsdc > 0) {
            lockedMarginUsdc[accountId] = mutation.resultingLockedMarginUsdc;
            emit MarginUnlocked(accountId, mutation.activeMarginUnlockedUsdc);
        }

        uint256 totalConsumedUsdc = mutation.settlementDebitUsdc;
        if (totalConsumedUsdc == 0) {
            return (marginConsumedUsdc, freeSettlementConsumedUsdc, uncoveredUsdc);
        }

        balances[accountId][settlementAsset] -= totalConsumedUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, totalConsumedUsdc);
        emit AssetSeized(accountId, settlementAsset, totalConsumedUsdc, recipient);
    }

    /// @notice Consumes close-path losses from settlement buckets while preserving reserved settlement and any explicitly protected remaining position margin.
    function consumeCloseLoss(
        bytes32 accountId,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        address recipient
    ) external onlyOperator returns (uint256 seizedUsdc, uint256 shortfallUsdc) {
        if (lossUsdc == 0) {
            return (0, 0);
        }

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = _buildAccountUsdcBuckets(accountId, protectedLockedMarginUsdc);
        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, protectedLockedMarginUsdc, lossUsdc);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyTerminalLossMutation(buckets, protectedLockedMarginUsdc, consumption);
        seizedUsdc = consumption.totalConsumedUsdc;
        shortfallUsdc = consumption.uncoveredUsdc;

        if (seizedUsdc == 0) {
            return (0, shortfallUsdc);
        }

        if (mutation.activeMarginUnlockedUsdc > 0 || mutation.otherLockedMarginUnlockedUsdc > 0) {
            lockedMarginUsdc[accountId] = mutation.resultingLockedMarginUsdc;
            if (mutation.activeMarginUnlockedUsdc > 0) {
                emit MarginUnlocked(accountId, mutation.activeMarginUnlockedUsdc);
            }
            if (mutation.otherLockedMarginUnlockedUsdc > 0) {
                emit MarginUnlocked(accountId, mutation.otherLockedMarginUnlockedUsdc);
            }
        }

        balances[accountId][settlementAsset] -= mutation.settlementDebitUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, mutation.settlementDebitUsdc);
        emit AssetSeized(accountId, settlementAsset, mutation.settlementDebitUsdc, recipient);
    }

    /// @notice Settles liquidation residual against liquidation-reachable collateral while preserving reserved escrow.
    /// @dev Releases the specified active position margin bucket but leaves unrelated committed margin untouched.
    function consumeLiquidationResidual(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        int256 residualUsdc,
        address recipient
    ) external onlyOperator returns (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = _buildAccountUsdcBuckets(accountId, lockedPositionMarginUsdc);
        MarginClearinghouseAccountingLib.LiquidationResidualPlan memory plan =
            MarginClearinghouseAccountingLib.planLiquidationResidual(buckets, residualUsdc);
        seizedUsdc = plan.seizedUsdc;
        payoutUsdc = plan.payoutUsdc;
        badDebtUsdc = plan.badDebtUsdc;

        if (lockedPositionMarginUsdc > 0) {
            lockedMarginUsdc[accountId] = plan.mutation.resultingLockedMarginUsdc;
            emit MarginUnlocked(accountId, plan.mutation.activeMarginUnlockedUsdc);
            if (plan.mutation.otherLockedMarginUnlockedUsdc > 0) {
                emit MarginUnlocked(accountId, plan.mutation.otherLockedMarginUnlockedUsdc);
            }
        }

        if (seizedUsdc > 0) {
            balances[accountId][settlementAsset] -= plan.mutation.settlementDebitUsdc;
            IERC20(settlementAsset).safeTransfer(recipient, plan.mutation.settlementDebitUsdc);
            emit AssetSeized(accountId, settlementAsset, plan.mutation.settlementDebitUsdc, recipient);
        }
    }

    function _buildAccountUsdcBuckets(
        bytes32 accountId,
        uint256 activePositionMarginUsdc
    ) internal view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            balances[accountId][settlementAsset], reservedSettlementUsdc[accountId], lockedMarginUsdc[accountId], activePositionMarginUsdc
        );
    }

    function _planFundingLossConsumption(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc
    ) internal view returns (MarginClearinghouseAccountingLib.SettlementConsumption memory consumption) {
        return MarginClearinghouseAccountingLib.planFundingLossConsumption(
            _buildAccountUsdcBuckets(accountId, lockedPositionMarginUsdc), lossUsdc
        );
    }

    function _creditSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        balances[accountId][settlementAsset] += amountUsdc;
    }

    function _debitSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (balances[accountId][settlementAsset] < amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        balances[accountId][settlementAsset] -= amountUsdc;
    }

    function _lockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (getFreeBuyingPowerUsdc(accountId) < amountUsdc) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (balances[accountId][settlementAsset] < lockedMarginUsdc[accountId] + reservedSettlementUsdc[accountId] + amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        lockedMarginUsdc[accountId] += amountUsdc;
        emit MarginLocked(accountId, amountUsdc);
    }

    function _unlockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (lockedMarginUsdc[accountId] >= amountUsdc) {
            lockedMarginUsdc[accountId] -= amountUsdc;
        } else {
            lockedMarginUsdc[accountId] = 0;
        }
        emit MarginUnlocked(accountId, amountUsdc);
    }

    /// @notice Transfers settlement asset from an account to the calling operator.
    /// @dev The recipient must equal msg.sender, so operators can only pull seized funds
    ///      into their own contract/account and must forward them explicitly afterward.
    ///      This is stricter than `payReservedSettlementUsdc()`, which can route reserved
    ///      execution bounty escrow to an arbitrary recipient chosen by the operator.
    /// @param accountId Account to seize from
    /// @param asset ERC20 token to seize (must equal settlementAsset)
    /// @param amount Token amount to seize
    /// @param recipient Recipient of seized tokens (must equal msg.sender)
    function seizeAsset(
        bytes32 accountId,
        address asset,
        uint256 amount,
        address recipient
    ) external onlyOperator {
        if (asset != settlementAsset || !assetConfigs[asset].isSupported) {
            revert MarginClearinghouse__AssetNotSupported();
        }
        if (recipient != msg.sender) {
            revert MarginClearinghouse__InvalidSeizeRecipient();
        }
        if (balances[accountId][asset] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }
        if (amount > getFreeSettlementBalanceUsdc(accountId)) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        balances[accountId][asset] -= amount;
        IERC20(asset).safeTransfer(recipient, amount);

        emit AssetSeized(accountId, asset, amount, recipient);
    }

}
