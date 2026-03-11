// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CfdEngine
/// @notice The core mathematical ledger for Plether CFDs.
/// @dev Settles all funds through the MarginClearinghouse and CfdVault.
/// @custom:security-contact contact@plether.com
contract CfdEngine is IWithdrawGuard, Ownable2Step, ReentrancyGuard {

    uint256 public immutable CAP_PRICE;

    IERC20 public immutable USDC;
    IMarginClearinghouse public clearinghouse;
    ICfdVault public vault;

    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    uint256 public globalBullMaxProfit;
    uint256 public globalBearMaxProfit;

    uint256 public bullOI;
    uint256 public bearOI;

    uint256 public globalBullEntryNotional;
    uint256 public globalBearEntryNotional;
    uint256 public lastMarkPrice;
    uint64 public lastMarkTime;

    uint256 public totalBullMargin;
    uint256 public totalBearMargin;

    uint256 public accumulatedFeesUsdc;

    // ==========================================
    // FUNDING ACCUMULATORS
    // ==========================================

    int256 public bullFundingIndex;
    int256 public bearFundingIndex;
    uint64 public lastFundingTime;
    int256 public globalBullEntryFunding;
    int256 public globalBearEntryFunding;

    CfdTypes.RiskParams public riskParams;
    mapping(bytes32 => CfdTypes.Position) public positions;

    address public orderRouter;

    mapping(uint256 => bool) public fadDayOverrides;
    uint256 public fadMaxStaleness = 3 days;
    uint256 public fadRunwaySeconds = 3 hours;

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    CfdTypes.RiskParams public pendingRiskParams;
    uint256 public riskParamsActivationTime;

    uint256[] private _pendingAddFadDays;
    uint256 public addFadDaysActivationTime;

    uint256[] private _pendingRemoveFadDays;
    uint256 public removeFadDaysActivationTime;

    uint256 public pendingFadMaxStaleness;
    uint256 public fadMaxStalenessActivationTime;

    uint256 public pendingFadRunway;
    uint256 public fadRunwayActivationTime;

    error CfdEngine__Unauthorized();
    error CfdEngine__VaultAlreadySet();
    error CfdEngine__RouterAlreadySet();
    error CfdEngine__NoFeesToWithdraw();
    error CfdEngine__MustCloseOpposingPosition();
    error CfdEngine__FundingExceedsMargin();
    error CfdEngine__VaultSolvencyExceeded();
    error CfdEngine__MarginDrainedByFees();
    error CfdEngine__CloseSizeExceedsPosition();
    error CfdEngine__NoPositionToLiquidate();
    error CfdEngine__PositionIsSolvent();
    error CfdEngine__PostOpSolvencyBreach();
    error CfdEngine__InsufficientInitialMargin();
    error CfdEngine__PositionTooSmall();
    error CfdEngine__WithdrawBlockedByOpenPosition();
    error CfdEngine__EmptyDays();
    error CfdEngine__ZeroStaleness();
    error CfdEngine__RunwayTooLong();
    error CfdEngine__PartialCloseUnderwaterFunding();
    error CfdEngine__DustPosition();
    error CfdEngine__TimelockNotReady();
    error CfdEngine__NoProposal();

    event FundingUpdated(int256 bullIndex, int256 bearIndex, uint256 absSkewUsdc);
    event PositionOpened(
        bytes32 indexed accountId, CfdTypes.Side side, uint256 sizeDelta, uint256 price, uint256 marginDelta
    );
    event PositionClosed(bytes32 indexed accountId, CfdTypes.Side side, uint256 sizeDelta, uint256 price, int256 pnl);
    event PositionLiquidated(
        bytes32 indexed accountId, CfdTypes.Side side, uint256 size, uint256 price, uint256 keeperBounty
    );
    event FadDaysAdded(uint256[] timestamps);
    event FadDaysRemoved(uint256[] timestamps);
    event FadMaxStalenessUpdated(uint256 newStaleness);
    event FadRunwayUpdated(uint256 newRunway);
    event RiskParamsProposed(uint256 activationTime);
    event RiskParamsFinalized();
    event AddFadDaysProposed(uint256[] timestamps, uint256 activationTime);
    event AddFadDaysFinalized();
    event RemoveFadDaysProposed(uint256[] timestamps, uint256 activationTime);
    event RemoveFadDaysFinalized();
    event FadMaxStalenessProposed(uint256 newStaleness, uint256 activationTime);
    event FadMaxStalenessFinalized();
    event FadRunwayProposed(uint256 newRunway, uint256 activationTime);
    event FadRunwayFinalized();

    function _requireTimelockReady(
        uint256 activationTime
    ) internal view {
        if (activationTime == 0) {
            revert CfdEngine__NoProposal();
        }
        if (block.timestamp < activationTime) {
            revert CfdEngine__TimelockNotReady();
        }
    }

    modifier onlyRouter() {
        if (msg.sender != orderRouter) {
            revert CfdEngine__Unauthorized();
        }
        _;
    }

    /// @param _usdc USDC token used as margin and settlement currency
    /// @param _clearinghouse Margin clearinghouse that custodies trader balances
    /// @param _capPrice Maximum oracle price — positions are clamped here (also determines BULL max profit)
    /// @param _riskParams Initial risk parameters (margin requirements, funding curve, bounty config)
    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams
    ) Ownable(msg.sender) {
        USDC = IERC20(_usdc);
        clearinghouse = IMarginClearinghouse(_clearinghouse);
        CAP_PRICE = _capPrice;
        riskParams = _riskParams;
        lastFundingTime = uint64(block.timestamp);
    }

    /// @notice One-time setter for the HousePool vault backing all positions
    function setVault(
        address _vault
    ) external onlyOwner {
        if (address(vault) != address(0)) {
            revert CfdEngine__VaultAlreadySet();
        }
        vault = ICfdVault(_vault);
    }

    /// @notice One-time setter for the authorized OrderRouter
    function setOrderRouter(
        address _router
    ) external onlyOwner {
        if (orderRouter != address(0)) {
            revert CfdEngine__RouterAlreadySet();
        }
        orderRouter = _router;
    }

    /// @notice Proposes new risk parameters (margin BPS, funding curve, bounty config) subject to timelock
    function proposeRiskParams(
        CfdTypes.RiskParams memory _riskParams
    ) external onlyOwner {
        pendingRiskParams = _riskParams;
        riskParamsActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RiskParamsProposed(riskParamsActivationTime);
    }

    /// @notice Applies proposed risk parameters after timelock expires; settles funding first
    function finalizeRiskParams() external onlyOwner {
        _requireTimelockReady(riskParamsActivationTime);
        _updateFunding(lastMarkPrice, vault.totalAssets());
        riskParams = pendingRiskParams;
        delete pendingRiskParams;
        riskParamsActivationTime = 0;
        emit RiskParamsFinalized();
    }

    /// @notice Cancels a pending risk parameters proposal
    function cancelRiskParamsProposal() external onlyOwner {
        delete pendingRiskParams;
        riskParamsActivationTime = 0;
    }

    /// @notice Proposes adding FAD (Friday Afternoon Deleverage) override days — elevated margin on those dates
    function proposeAddFadDays(
        uint256[] calldata timestamps
    ) external onlyOwner {
        if (timestamps.length == 0) {
            revert CfdEngine__EmptyDays();
        }
        _pendingAddFadDays = timestamps;
        addFadDaysActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit AddFadDaysProposed(timestamps, addFadDaysActivationTime);
    }

    /// @notice Applies proposed FAD day additions after timelock expires
    function finalizeAddFadDays() external onlyOwner {
        _requireTimelockReady(addFadDaysActivationTime);
        uint256[] memory timestamps = _pendingAddFadDays;
        for (uint256 i; i < timestamps.length; i++) {
            fadDayOverrides[timestamps[i] / 86_400] = true;
        }
        delete _pendingAddFadDays;
        addFadDaysActivationTime = 0;
        emit FadDaysAdded(timestamps);
        emit AddFadDaysFinalized();
    }

    /// @notice Cancels a pending add-FAD-days proposal
    function cancelAddFadDaysProposal() external onlyOwner {
        delete _pendingAddFadDays;
        addFadDaysActivationTime = 0;
    }

    /// @notice Proposes removing FAD override days (restores normal margin on those dates)
    function proposeRemoveFadDays(
        uint256[] calldata timestamps
    ) external onlyOwner {
        if (timestamps.length == 0) {
            revert CfdEngine__EmptyDays();
        }
        _pendingRemoveFadDays = timestamps;
        removeFadDaysActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RemoveFadDaysProposed(timestamps, removeFadDaysActivationTime);
    }

    /// @notice Applies proposed FAD day removals after timelock expires
    function finalizeRemoveFadDays() external onlyOwner {
        _requireTimelockReady(removeFadDaysActivationTime);
        uint256[] memory timestamps = _pendingRemoveFadDays;
        for (uint256 i; i < timestamps.length; i++) {
            delete fadDayOverrides[timestamps[i] / 86_400];
        }
        delete _pendingRemoveFadDays;
        removeFadDaysActivationTime = 0;
        emit FadDaysRemoved(timestamps);
        emit RemoveFadDaysFinalized();
    }

    /// @notice Cancels a pending remove-FAD-days proposal
    function cancelRemoveFadDaysProposal() external onlyOwner {
        delete _pendingRemoveFadDays;
        removeFadDaysActivationTime = 0;
    }

    /// @notice Proposes a new fadMaxStaleness — max age of the last mark price before FAD kicks in
    function proposeFadMaxStaleness(
        uint256 _seconds
    ) external onlyOwner {
        if (_seconds == 0) {
            revert CfdEngine__ZeroStaleness();
        }
        pendingFadMaxStaleness = _seconds;
        fadMaxStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FadMaxStalenessProposed(_seconds, fadMaxStalenessActivationTime);
    }

    /// @notice Applies proposed fadMaxStaleness after timelock expires
    function finalizeFadMaxStaleness() external onlyOwner {
        _requireTimelockReady(fadMaxStalenessActivationTime);
        fadMaxStaleness = pendingFadMaxStaleness;
        pendingFadMaxStaleness = 0;
        fadMaxStalenessActivationTime = 0;
        emit FadMaxStalenessUpdated(fadMaxStaleness);
        emit FadMaxStalenessFinalized();
    }

    /// @notice Cancels a pending fadMaxStaleness proposal
    function cancelFadMaxStalenessProposal() external onlyOwner {
        pendingFadMaxStaleness = 0;
        fadMaxStalenessActivationTime = 0;
    }

    /// @notice Proposes a new fadRunway — how many seconds before an FAD day the elevated margin activates
    function proposeFadRunway(
        uint256 _seconds
    ) external onlyOwner {
        if (_seconds > 24 hours) {
            revert CfdEngine__RunwayTooLong();
        }
        pendingFadRunway = _seconds;
        fadRunwayActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FadRunwayProposed(_seconds, fadRunwayActivationTime);
    }

    /// @notice Applies proposed fadRunway after timelock expires
    function finalizeFadRunway() external onlyOwner {
        _requireTimelockReady(fadRunwayActivationTime);
        fadRunwaySeconds = pendingFadRunway;
        pendingFadRunway = 0;
        fadRunwayActivationTime = 0;
        emit FadRunwayUpdated(fadRunwaySeconds);
        emit FadRunwayFinalized();
    }

    /// @notice Cancels a pending fadRunway proposal
    function cancelFadRunwayProposal() external onlyOwner {
        pendingFadRunway = 0;
        fadRunwayActivationTime = 0;
    }

    /// @notice Withdraws accumulated execution fees from the vault to a recipient
    function withdrawFees(
        address recipient
    ) external onlyOwner {
        uint256 fees = accumulatedFeesUsdc;
        if (fees == 0) {
            revert CfdEngine__NoFeesToWithdraw();
        }
        accumulatedFeesUsdc = 0;
        vault.payOut(recipient, fees);
        _assertPostSolvency();
    }

    // ==========================================
    // WITHDRAW GUARD (IWithdrawGuard)
    // ==========================================

    /// @notice Reverts if the account has an open position that would be undercollateralized after withdrawal
    /// @param accountId Clearinghouse account to check
    function checkWithdraw(
        bytes32 accountId
    ) external view override {
        CfdTypes.Position memory pos = positions[accountId];
        if (pos.size == 0) {
            return;
        }

        uint256 price = lastMarkPrice;
        if (price == 0) {
            return;
        }

        int256 pendingFunding = getPendingFunding(pos);
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, CAP_PRICE);

        int256 equity = int256(pos.margin) + pendingFunding;
        equity = isProfit ? equity + int256(pnlAbs) : equity - int256(pnlAbs);

        uint256 mmr = getMaintenanceMarginUsdc(pos.size, price);
        if (equity < int256(mmr)) {
            revert CfdEngine__WithdrawBlockedByOpenPosition();
        }
    }

    // ==========================================
    // 1. CONTINUOUS FUNDING SYSTEM
    // ==========================================

    function _updateFunding(
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) internal {
        uint256 timeDelta = block.timestamp - lastFundingTime;
        if (timeDelta == 0) {
            return;
        }

        uint256 bullUsdc = (bullOI * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bearOI * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;

        uint256 absSkew;
        bool bullMajority;

        if (bullUsdc > bearUsdc) {
            absSkew = bullUsdc - bearUsdc;
            bullMajority = true;
        } else {
            absSkew = bearUsdc - bullUsdc;
            bullMajority = false;
        }

        if (absSkew > 0 && vaultDepthUsdc > 0) {
            uint256 annRate = CfdMath.getAnnualizedFundingRate(absSkew, vaultDepthUsdc, riskParams);
            uint256 fundingDelta = (annRate * timeDelta) / CfdMath.SECONDS_PER_YEAR;
            int256 step = int256((currentOraclePrice * fundingDelta) / 1e8);

            if (step > 0) {
                if (bullMajority) {
                    bullFundingIndex -= step;
                    bearFundingIndex += step;
                } else {
                    bearFundingIndex -= step;
                    bullFundingIndex += step;
                }
            }
        }

        lastFundingTime = uint64(block.timestamp);
        emit FundingUpdated(bullFundingIndex, bearFundingIndex, absSkew);
    }

    /// @notice Returns unsettled funding owed to (+) or by (-) a position in USDC (6 decimals)
    /// @param pos The position to compute pending funding for
    /// @return fundingUsdc Positive if the position is owed funding, negative if it owes
    function getPendingFunding(
        CfdTypes.Position memory pos
    ) public view returns (int256 fundingUsdc) {
        if (pos.size == 0) {
            return 0;
        }
        int256 currentIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        int256 indexDelta = currentIndex - pos.entryFundingIndex;
        fundingUsdc = (int256(pos.size) * indexDelta) / int256(CfdMath.FUNDING_INDEX_SCALE);
    }

    // ==========================================
    // 2. ORDER PROCESSING & NETTING
    // ==========================================

    /// @notice Executes an order: settles funding, then increases or decreases the position.
    ///         Called exclusively by OrderRouter after MEV and slippage checks pass.
    /// @param order The order to execute (account, side, size delta, margin delta, isClose)
    /// @param currentOraclePrice Pyth oracle price (8 decimals), clamped to CAP_PRICE
    /// @param vaultDepthUsdc HousePool total assets — used to scale funding rate
    /// @param publishTime Pyth publish timestamp, stored as lastMarkTime
    /// @return Always 0 (reserved for future use)
    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external onlyRouter nonReentrant returns (int256) {
        uint256 price = currentOraclePrice > CAP_PRICE ? CAP_PRICE : currentOraclePrice;
        lastMarkPrice = price;
        lastMarkTime = publishTime;

        _updateFunding(price, vaultDepthUsdc);

        CfdTypes.Position storage pos = positions[order.accountId];
        uint256 marginSnapshot = pos.margin;
        CfdTypes.Side marginSide = pos.size > 0 ? pos.side : order.side;

        uint256 preSkewUsdc = _getAbsSkewUsdc(price);

        if (pos.size > 0 && pos.side != order.side) {
            if (!order.isClose) {
                revert CfdEngine__MustCloseOpposingPosition();
            }
        }

        uint256 unsettledFundingDebt = _settleFunding(order, pos);

        if (order.isClose) {
            _processDecrease(order, pos, price, preSkewUsdc, vaultDepthUsdc, unsettledFundingDebt);
        } else {
            _processIncrease(order, pos, price, preSkewUsdc, vaultDepthUsdc);
        }

        if (!order.isClose) {
            _assertPostSolvency();
        }

        uint256 marginAfter = pos.margin;
        if (marginAfter > marginSnapshot) {
            if (marginSide == CfdTypes.Side.BULL) {
                totalBullMargin += marginAfter - marginSnapshot;
            } else {
                totalBearMargin += marginAfter - marginSnapshot;
            }
        } else if (marginSnapshot > marginAfter) {
            if (marginSide == CfdTypes.Side.BULL) {
                totalBullMargin -= marginSnapshot - marginAfter;
            } else {
                totalBearMargin -= marginSnapshot - marginAfter;
            }
        }

        pos.lastUpdateTime = uint64(block.timestamp);
        return 0;
    }

    // ==========================================
    // 3. INTERNAL LEDGER UPDATES
    // ==========================================

    function _settleFunding(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos
    ) internal returns (uint256 unsettledFundingDebt) {
        int256 pendingFunding = getPendingFunding(pos);
        if (pos.size > 0 && pendingFunding != 0) {
            if (pendingFunding > 0) {
                uint256 gain = uint256(pendingFunding);
                pos.margin += gain;
                vault.payOut(address(clearinghouse), gain);
                clearinghouse.settleUsdc(order.accountId, address(USDC), pendingFunding);
                clearinghouse.lockMargin(order.accountId, gain);
            } else {
                uint256 loss = uint256(-pendingFunding);
                if (pos.margin < loss) {
                    if (!order.isClose) {
                        revert CfdEngine__FundingExceedsMargin();
                    }
                    if (order.sizeDelta < pos.size) {
                        revert CfdEngine__PartialCloseUnderwaterFunding();
                    }
                    unsettledFundingDebt = loss - pos.margin;
                    if (pos.margin > 0) {
                        clearinghouse.seizeAsset(order.accountId, address(USDC), pos.margin, address(vault));
                        clearinghouse.unlockMargin(order.accountId, pos.margin);
                    }
                    pos.margin = 0;
                } else {
                    pos.margin -= loss;
                    clearinghouse.seizeAsset(order.accountId, address(USDC), loss, address(vault));
                    clearinghouse.unlockMargin(order.accountId, loss);
                }
            }
        }
        if (pos.size > 0) {
            int256 newIdx = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
            int256 fundingDelta = int256(pos.size) * (newIdx - pos.entryFundingIndex);
            if (pos.side == CfdTypes.Side.BULL) {
                globalBullEntryFunding += fundingDelta;
            } else {
                globalBearEntryFunding += fundingDelta;
            }
            pos.entryFundingIndex = newIdx;
        }
    }

    function _processIncrease(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos,
        uint256 price,
        uint256 preSkewUsdc,
        uint256 vaultDepthUsdc
    ) internal {
        uint256 newMaxProfit = CfdMath.calculateMaxProfit(order.sizeDelta, price, order.side, CAP_PRICE);
        _addGlobalLiability(order.side, newMaxProfit, order.sizeDelta);
        pos.maxProfitUsdc += newMaxProfit;

        uint256 oldNotional = pos.size * pos.entryPrice;

        if (pos.size == 0) {
            pos.entryPrice = price;
            pos.side = order.side;
            pos.entryFundingIndex = order.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        } else {
            uint256 totalValue = oldNotional + (order.sizeDelta * price);
            pos.entryPrice = totalValue / (pos.size + order.sizeDelta);
        }

        pos.size += order.sizeDelta;
        uint256 newNotional = pos.size * pos.entryPrice;

        if (order.side == CfdTypes.Side.BULL) {
            globalBullEntryNotional += newNotional - oldNotional;
            globalBullEntryFunding += int256(order.sizeDelta) * pos.entryFundingIndex;
        } else {
            globalBearEntryNotional += newNotional - oldNotional;
            globalBearEntryFunding += int256(order.sizeDelta) * pos.entryFundingIndex;
        }

        CfdTypes.RiskParams memory rp = riskParams;

        uint256 postSkewUsdc = _getAbsSkewUsdc(price);
        int256 vpiUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, rp.vpiFactor);
        pos.vpiAccrued += vpiUsdc;

        uint256 notionalUsdc = (order.sizeDelta * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        if (notionalUsdc * rp.bountyBps < rp.minBountyUsdc * 10_000) {
            revert CfdEngine__PositionTooSmall();
        }
        uint256 execFeeUsdc = (notionalUsdc * 6) / 10_000;

        int256 tradeCost = vpiUsdc + int256(execFeeUsdc);
        int256 netMarginChange = int256(order.marginDelta) - tradeCost;

        if (tradeCost > 0) {
            clearinghouse.seizeAsset(order.accountId, address(USDC), uint256(tradeCost), address(vault));
        } else if (tradeCost < 0) {
            uint256 rebate = uint256(-tradeCost);
            vault.payOut(address(clearinghouse), rebate);
            clearinghouse.settleUsdc(order.accountId, address(USDC), int256(rebate));
        }

        if (netMarginChange > 0) {
            clearinghouse.lockMargin(order.accountId, uint256(netMarginChange));
            pos.margin += uint256(netMarginChange);
        } else if (netMarginChange < 0) {
            uint256 deficit = uint256(-netMarginChange);
            if (pos.margin < deficit) {
                revert CfdEngine__MarginDrainedByFees();
            }
            clearinghouse.unlockMargin(order.accountId, deficit);
            pos.margin -= deficit;
        }

        accumulatedFeesUsdc += execFeeUsdc;

        uint256 mmr = getMaintenanceMarginUsdc(pos.size, price);
        uint256 imr = (mmr * 150) / 100;
        if (imr < rp.minBountyUsdc) {
            imr = rp.minBountyUsdc;
        }
        uint256 effectiveMargin = pos.margin;
        if (tradeCost < 0) {
            uint256 rebate = uint256(-tradeCost);
            effectiveMargin = effectiveMargin > rebate ? effectiveMargin - rebate : 0;
        }
        if (effectiveMargin < imr) {
            revert CfdEngine__InsufficientInitialMargin();
        }

        emit PositionOpened(order.accountId, order.side, order.sizeDelta, price, order.marginDelta);
    }

    function _processDecrease(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos,
        uint256 price,
        uint256 preSkewUsdc,
        uint256 vaultDepthUsdc,
        uint256 unsettledFundingDebt
    ) internal {
        if (pos.size < order.sizeDelta) {
            revert CfdEngine__CloseSizeExceedsPosition();
        }

        CfdTypes.Position memory closedPart = pos;
        closedPart.size = order.sizeDelta;
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, price, CAP_PRICE);
        int256 realizedPnl = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        uint256 marginToFree = (pos.margin * order.sizeDelta) / pos.size;
        pos.margin -= marginToFree;

        uint256 maxProfitReduction = (pos.maxProfitUsdc * order.sizeDelta) / pos.size;
        pos.maxProfitUsdc -= maxProfitReduction;
        _reduceGlobalLiability(pos.side, maxProfitReduction, order.sizeDelta);

        uint256 entryNotionalReduction = order.sizeDelta * pos.entryPrice;
        if (pos.side == CfdTypes.Side.BULL) {
            globalBullEntryNotional -= entryNotionalReduction;
            globalBullEntryFunding -= int256(order.sizeDelta) * pos.entryFundingIndex;
        } else {
            globalBearEntryNotional -= entryNotionalReduction;
            globalBearEntryFunding -= int256(order.sizeDelta) * pos.entryFundingIndex;
        }

        pos.size -= order.sizeDelta;

        if (pos.size > 0 && pos.margin < riskParams.minBountyUsdc) {
            revert CfdEngine__DustPosition();
        }

        clearinghouse.unlockMargin(order.accountId, marginToFree);

        uint256 postSkewUsdc = _getAbsSkewUsdc(price);
        int256 vpiUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, riskParams.vpiFactor);

        uint256 originalSize = pos.size + order.sizeDelta;
        int256 proportionalAccrual = (pos.vpiAccrued * int256(order.sizeDelta)) / int256(originalSize);
        pos.vpiAccrued -= proportionalAccrual;

        if (proportionalAccrual + vpiUsdc < 0) {
            vpiUsdc = -proportionalAccrual;
        }

        uint256 notionalUsdc = (order.sizeDelta * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 execFeeUsdc = (notionalUsdc * 6) / 10_000;

        int256 netSettlement = realizedPnl - vpiUsdc - int256(execFeeUsdc) - int256(unsettledFundingDebt);

        uint256 actualFee = execFeeUsdc;
        if (netSettlement > 0) {
            vault.payOut(address(clearinghouse), uint256(netSettlement));
            clearinghouse.settleUsdc(order.accountId, address(USDC), netSettlement);
        } else if (netSettlement < 0) {
            uint256 owed = uint256(-netSettlement);
            uint256 chBalance = clearinghouse.balances(order.accountId, address(USDC));
            uint256 locked = clearinghouse.lockedMarginUsdc(order.accountId);
            uint256 available = chBalance > locked ? chBalance - locked : 0;
            uint256 toSeize = available < owed ? available : owed;
            if (toSeize > 0) {
                clearinghouse.seizeAsset(order.accountId, address(USDC), toSeize, address(vault));
            }
            uint256 shortfall = owed - toSeize;
            actualFee = execFeeUsdc > shortfall ? execFeeUsdc - shortfall : 0;
        }

        accumulatedFeesUsdc += actualFee;

        emit PositionClosed(order.accountId, pos.side, order.sizeDelta, price, realizedPnl);

        if (pos.size == 0) {
            delete positions[order.accountId];
        }
    }

    function _getAbsSkewUsdc(
        uint256 currentOraclePrice
    ) internal view returns (uint256) {
        uint256 bullUsdc = (bullOI * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bearOI * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        return bullUsdc > bearUsdc ? bullUsdc - bearUsdc : bearUsdc - bullUsdc;
    }

    function _addGlobalLiability(
        CfdTypes.Side side,
        uint256 maxProfitUsdc,
        uint256 sizeDelta
    ) internal {
        if (side == CfdTypes.Side.BULL) {
            globalBullMaxProfit += maxProfitUsdc;
            bullOI += sizeDelta;
        } else {
            globalBearMaxProfit += maxProfitUsdc;
            bearOI += sizeDelta;
        }
        uint256 maxLiability = globalBullMaxProfit > globalBearMaxProfit ? globalBullMaxProfit : globalBearMaxProfit;
        if (_getEffectiveAssets() < maxLiability) {
            revert CfdEngine__VaultSolvencyExceeded();
        }
    }

    function _reduceGlobalLiability(
        CfdTypes.Side side,
        uint256 maxProfitUsdc,
        uint256 sizeDelta
    ) internal {
        if (side == CfdTypes.Side.BULL) {
            globalBullMaxProfit -= maxProfitUsdc;
            bullOI -= sizeDelta;
        } else {
            globalBearMaxProfit -= maxProfitUsdc;
            bearOI -= sizeDelta;
        }
    }

    // ==========================================
    // LIQUIDATIONS & FAD
    // ==========================================

    /// @notice Returns true during the Friday Afternoon Deleverage (FAD) window
    ///         (Friday 19:00 UTC → Sunday 22:00 UTC), on admin-configured FAD days,
    ///         or within fadRunwaySeconds before an admin FAD day (deleverage runway).
    function isFadWindow() public view returns (bool) {
        uint256 dayOfWeek = ((block.timestamp / 86_400) + 4) % 7;
        uint256 hourOfDay = (block.timestamp % 86_400) / 3600;

        if (dayOfWeek == 5 && hourOfDay >= 19) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && hourOfDay < 22) {
            return true;
        }

        uint256 today = block.timestamp / 86_400;

        if (fadDayOverrides[today]) {
            return true;
        }

        uint256 runway = fadRunwaySeconds;
        if (runway > 0) {
            uint256 secondsUntilTomorrow = 86_400 - (block.timestamp % 86_400);
            if (secondsUntilTomorrow <= runway && fadDayOverrides[today + 1]) {
                return true;
            }
        }

        return false;
    }

    /// @notice Returns the maintenance margin requirement in USDC (6 decimals).
    ///         Uses fadMarginBps during the FAD window, maintMarginBps otherwise.
    /// @param size Position size in tokens (18 decimals)
    /// @param currentOraclePrice Oracle price (8 decimals)
    function getMaintenanceMarginUsdc(
        uint256 size,
        uint256 currentOraclePrice
    ) public view returns (uint256) {
        uint256 notionalUsdc = (size * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 requiredBps = isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps;
        return (notionalUsdc * requiredBps) / 10_000;
    }

    /// @notice Liquidates an undercollateralized position.
    ///         Surplus equity (after bounty) is returned to the user.
    ///         In bad-debt cases (equity < bounty), all remaining margin is seized by the vault.
    /// @param accountId Clearinghouse account that owns the position
    /// @param currentOraclePrice Pyth oracle price (8 decimals), clamped to CAP_PRICE
    /// @param vaultDepthUsdc HousePool total assets — used to scale funding rate
    /// @param publishTime Pyth publish timestamp, stored as lastMarkTime
    /// @return keeperBountyUsdc Bounty paid to the liquidation keeper (USDC, 6 decimals)
    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external onlyRouter nonReentrant returns (uint256 keeperBountyUsdc) {
        uint256 price = currentOraclePrice > CAP_PRICE ? CAP_PRICE : currentOraclePrice;
        lastMarkPrice = price;
        lastMarkTime = publishTime;
        _updateFunding(price, vaultDepthUsdc);

        CfdTypes.Position storage pos = positions[accountId];
        if (pos.size == 0) {
            revert CfdEngine__NoPositionToLiquidate();
        }

        int256 pendingFunding = getPendingFunding(pos);
        if (pos.side == CfdTypes.Side.BULL) {
            globalBullEntryFunding -= int256(pos.size) * pos.entryFundingIndex;
        } else {
            globalBearEntryFunding -= int256(pos.size) * pos.entryFundingIndex;
        }

        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, CAP_PRICE);

        int256 equityUsdc = int256(pos.margin) + pendingFunding;
        equityUsdc = isProfit ? equityUsdc + int256(pnlAbs) : equityUsdc - int256(pnlAbs);

        uint256 mmUsdc = getMaintenanceMarginUsdc(pos.size, price);
        if (equityUsdc >= int256(mmUsdc)) {
            revert CfdEngine__PositionIsSolvent();
        }

        _reduceGlobalLiability(pos.side, pos.maxProfitUsdc, pos.size);

        uint256 liqEntryNotional = pos.size * pos.entryPrice;
        if (pos.side == CfdTypes.Side.BULL) {
            globalBullEntryNotional -= liqEntryNotional;
        } else {
            globalBearEntryNotional -= liqEntryNotional;
        }

        CfdTypes.RiskParams memory rp = riskParams;

        uint256 notionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        keeperBountyUsdc = (notionalUsdc * rp.bountyBps) / 10_000;
        if (keeperBountyUsdc < rp.minBountyUsdc) {
            keeperBountyUsdc = rp.minBountyUsdc;
        }
        uint256 posMargin = pos.margin;
        if (equityUsdc <= 0) {
            if (keeperBountyUsdc > posMargin) {
                keeperBountyUsdc = posMargin;
            }
        } else if (keeperBountyUsdc > uint256(equityUsdc)) {
            keeperBountyUsdc = uint256(equityUsdc);
        }
        clearinghouse.unlockMargin(accountId, posMargin);

        int256 residual = equityUsdc - int256(keeperBountyUsdc);

        if (residual >= 0) {
            if (uint256(residual) <= posMargin) {
                uint256 toSeize = posMargin - uint256(residual);
                if (toSeize > 0) {
                    clearinghouse.seizeAsset(accountId, address(USDC), toSeize, address(vault));
                }
            } else {
                uint256 toPay = uint256(residual) - posMargin;
                vault.payOut(address(clearinghouse), toPay);
                clearinghouse.settleUsdc(accountId, address(USDC), int256(toPay));
            }
        } else {
            if (posMargin > 0) {
                clearinghouse.seizeAsset(accountId, address(USDC), posMargin, address(vault));
            }
            uint256 deficit = uint256(-residual);
            uint256 chBalance = clearinghouse.balances(accountId, address(USDC));
            uint256 locked = clearinghouse.lockedMarginUsdc(accountId);
            uint256 freeUsdc = chBalance > locked ? chBalance - locked : 0;
            if (freeUsdc > 0) {
                uint256 toSeize = freeUsdc < deficit ? freeUsdc : deficit;
                clearinghouse.seizeAsset(accountId, address(USDC), toSeize, address(vault));
            }
        }

        if (pos.side == CfdTypes.Side.BULL) {
            totalBullMargin -= posMargin;
        } else {
            totalBearMargin -= posMargin;
        }

        emit PositionLiquidated(accountId, pos.side, pos.size, price, keeperBountyUsdc);
        delete positions[accountId];
    }

    function _assertPostSolvency() internal view {
        uint256 maxLiability = globalBullMaxProfit > globalBearMaxProfit ? globalBullMaxProfit : globalBearMaxProfit;
        uint256 effectiveAssets = _getEffectiveAssets();
        if (effectiveAssets < maxLiability) {
            revert CfdEngine__PostOpSolvencyBreach();
        }
    }

    function _getEffectiveAssets() internal view returns (uint256 effectiveAssets) {
        effectiveAssets = vault.totalAssets();
        uint256 fees = accumulatedFeesUsdc;
        effectiveAssets = effectiveAssets > fees ? effectiveAssets - fees : 0;
        int256 cappedFunding = _getCappedFundingPnl();
        if (cappedFunding > 0) {
            effectiveAssets = effectiveAssets > uint256(cappedFunding) ? effectiveAssets - uint256(cappedFunding) : 0;
        } else if (cappedFunding < 0) {
            effectiveAssets += uint256(-cappedFunding);
        }
    }

    /// @notice Per-side funding PnL capped at deposited margin.
    ///         Used by solvency checks — the vault can count funding receivables as economic
    ///         assets, but only up to the physical margin that backs them.
    function _computeGlobalFundingPnl() internal view returns (int256 bullFunding, int256 bearFunding) {
        bullFunding = (int256(bullOI) * bullFundingIndex - globalBullEntryFunding) / int256(CfdMath.FUNDING_INDEX_SCALE);
        bearFunding = (int256(bearOI) * bearFundingIndex - globalBearEntryFunding) / int256(CfdMath.FUNDING_INDEX_SCALE);
    }

    function _getCappedFundingPnl() internal view returns (int256) {
        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();

        if (bullFunding < -int256(totalBullMargin)) {
            bullFunding = -int256(totalBullMargin);
        }
        if (bearFunding < -int256(totalBearMargin)) {
            bearFunding = -int256(totalBearMargin);
        }

        return bullFunding + bearFunding;
    }

    function _getUnrealizedFundingPnl() internal view returns (int256) {
        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();
        return bullFunding + bearFunding;
    }

    /// @notice Aggregate unsettled funding across all positions (uncapped, for reporting only)
    /// @return Net funding PnL in USDC (6 decimals), positive = traders are owed funding
    function getUnrealizedFundingPnl() external view returns (int256) {
        return _getUnrealizedFundingPnl();
    }

    /// @notice Updates the cached mark price without settling funding or processing trades
    /// @param price Oracle price (8 decimals), clamped to CAP_PRICE
    /// @param publishTime Pyth publish timestamp
    function updateMarkPrice(
        uint256 price,
        uint64 publishTime
    ) external onlyRouter {
        uint256 clamped = price > CAP_PRICE ? CAP_PRICE : price;
        _updateFunding(lastMarkPrice, vault.totalAssets());
        lastMarkPrice = clamped;
        lastMarkTime = publishTime;
    }

    // ==========================================
    // MARK-TO-MARKET
    // ==========================================

    /// @notice Aggregate unrealized PnL of all open positions at lastMarkPrice.
    ///         Positive = traders winning (house liability). Negative = traders losing (house asset).
    /// @return Net trader PnL in USDC (6 decimals), sign from the traders' perspective
    function getUnrealizedTraderPnl() external view returns (int256) {
        uint256 price = lastMarkPrice;
        if (price == 0) {
            return 0;
        }

        int256 bullPnl = int256(globalBullEntryNotional) - int256(bullOI * price);
        int256 bearPnl = int256(bearOI * price) - int256(globalBearEntryNotional);

        return (bullPnl + bearPnl) / int256(CfdMath.USDC_TO_TOKEN_SCALE);
    }

    /// @notice Combined MtM: per-side (PnL + funding), clamped at zero.
    ///         Positive = vault owes traders (unrealized liability). Zero = traders losing or neutral.
    ///         The vault never counts unrealized trader losses as assets — realized losses flow
    ///         through physical USDC transfers (settlements, liquidations).
    /// @return Net MtM adjustment the vault must reserve (always >= 0), in USDC (6 decimals)
    function getVaultMtmAdjustment() external view returns (int256) {
        uint256 price = lastMarkPrice;

        int256 bullPnl;
        int256 bearPnl;
        if (price > 0) {
            bullPnl = (int256(globalBullEntryNotional) - int256(bullOI * price)) / int256(CfdMath.USDC_TO_TOKEN_SCALE);
            bearPnl = (int256(bearOI * price) - int256(globalBearEntryNotional)) / int256(CfdMath.USDC_TO_TOKEN_SCALE);
        }

        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();

        int256 bullTotal = bullPnl + bullFunding;
        int256 bearTotal = bearPnl + bearFunding;

        if (bullTotal < 0) {
            bullTotal = 0;
        }
        if (bearTotal < 0) {
            bearTotal = 0;
        }

        return bullTotal + bearTotal;
    }

}
