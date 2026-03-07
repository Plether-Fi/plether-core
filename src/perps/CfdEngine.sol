// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdVault} from "./ICfdVault.sol";
import {IMarginClearinghouse} from "./IMarginClearinghouse.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CfdEngine
/// @notice The core mathematical ledger for Plether CFDs.
/// @dev Settles all funds through the MarginClearinghouse and CfdVault.
contract CfdEngine is Ownable2Step, ReentrancyGuard {

    uint256 public immutable CAP_PRICE;

    IERC20 public immutable usdc;
    IMarginClearinghouse public clearinghouse;
    ICfdVault public vault;

    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    uint256 public globalBullMaxProfit;
    uint256 public globalBearMaxProfit;

    uint256 public bullOI;
    uint256 public bearOI;

    uint256 public accumulatedFeesUsdc;

    // ==========================================
    // FUNDING ACCUMULATORS
    // ==========================================

    int256 public bullFundingIndex;
    int256 public bearFundingIndex;
    uint64 public lastFundingTime;

    CfdTypes.RiskParams public riskParams;
    mapping(bytes32 => CfdTypes.Position) public positions;

    address public orderRouter;

    // Events
    event FundingUpdated(int256 bullIndex, int256 bearIndex, uint256 absSkewUsdc);
    event PositionOpened(
        bytes32 indexed accountId, CfdTypes.Side side, uint256 sizeDelta, uint256 price, uint256 marginDelta
    );
    event PositionClosed(bytes32 indexed accountId, CfdTypes.Side side, uint256 sizeDelta, uint256 price, int256 pnl);
    event PositionLiquidated(
        bytes32 indexed accountId, CfdTypes.Side side, uint256 size, uint256 price, uint256 keeperBounty
    );

    modifier onlyRouter() {
        require(msg.sender == orderRouter, "CfdEngine: Unauthorized");
        _;
    }

    constructor(
        address _usdc,
        address _clearinghouse,
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams
    ) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        clearinghouse = IMarginClearinghouse(_clearinghouse);
        CAP_PRICE = _capPrice;
        riskParams = _riskParams;
        lastFundingTime = uint64(block.timestamp);
    }

    /// @notice One-time setter for the HousePool vault backing all positions
    function setVault(
        address _vault
    ) external onlyOwner {
        require(address(vault) == address(0), "CfdEngine: Vault already set");
        vault = ICfdVault(_vault);
    }

    /// @notice One-time setter for the authorized OrderRouter
    function setOrderRouter(
        address _router
    ) external onlyOwner {
        require(orderRouter == address(0), "CfdEngine: Router already set");
        orderRouter = _router;
    }

    function setRiskParams(
        CfdTypes.RiskParams memory _riskParams
    ) external onlyOwner {
        riskParams = _riskParams;
    }

    /// @notice Withdraws accumulated execution fees from the vault to a recipient
    function withdrawFees(
        address recipient
    ) external onlyOwner {
        uint256 fees = accumulatedFeesUsdc;
        require(fees > 0, "CfdEngine: No fees to withdraw");
        accumulatedFeesUsdc = 0;
        vault.payOut(recipient, fees);
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
            uint256 stepUsdc = (currentOraclePrice * fundingDelta) / CfdMath.USDC_TO_TOKEN_SCALE;
            int256 step = int256(stepUsdc);

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
    function getPendingFunding(
        CfdTypes.Position memory pos
    ) public view returns (int256 fundingUsdc) {
        if (pos.size == 0) {
            return 0;
        }
        int256 currentIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        int256 indexDelta = currentIndex - pos.entryFundingIndex;
        fundingUsdc = (int256(pos.size) * indexDelta) / int256(CfdMath.WAD);
    }

    // ==========================================
    // 2. ORDER PROCESSING & NETTING
    // ==========================================

    /// @notice Executes an order: settles funding, then increases or decreases the position.
    ///         Called exclusively by OrderRouter after MEV and slippage checks pass.
    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external onlyRouter nonReentrant returns (int256) {
        uint256 price = currentOraclePrice > CAP_PRICE ? CAP_PRICE : currentOraclePrice;

        _updateFunding(price, vaultDepthUsdc);

        CfdTypes.Position storage pos = positions[order.accountId];
        uint256 preSkewUsdc = _getAbsSkewUsdc(price);

        if (pos.size > 0 && pos.side != order.side) {
            require(order.isClose, "CfdEngine: Must explicitly close opposing position first");
        }

        // Settle accumulated funding into pos.margin AND sync clearinghouse
        int256 pendingFunding = getPendingFunding(pos);
        if (pos.size > 0 && pendingFunding != 0) {
            if (pendingFunding > 0) {
                uint256 gain = uint256(pendingFunding);
                pos.margin += gain;
                vault.payOut(address(clearinghouse), gain);
                clearinghouse.settleUsdc(order.accountId, address(usdc), pendingFunding);
                clearinghouse.lockMargin(order.accountId, gain);
            } else {
                uint256 loss = uint256(-pendingFunding);
                require(pos.margin >= loss, "CfdEngine: Funding exceeds margin, liquidate position");
                pos.margin -= loss;
                clearinghouse.seizeAsset(order.accountId, address(usdc), loss, address(vault));
                clearinghouse.unlockMargin(order.accountId, loss);
            }
            pos.entryFundingIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        }

        if (order.isClose) {
            _processDecrease(order, pos, price, preSkewUsdc, vaultDepthUsdc);
        } else {
            _processIncrease(order, pos, price, preSkewUsdc, vaultDepthUsdc);
        }

        _assertPostSolvency();
        pos.lastUpdateTime = uint64(block.timestamp);
        return 0;
    }

    // ==========================================
    // 3. INTERNAL LEDGER UPDATES
    // ==========================================

    function _processIncrease(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos,
        uint256 price,
        uint256 preSkewUsdc,
        uint256 vaultDepthUsdc
    ) internal {
        uint256 newMaxProfit = CfdMath.calculateMaxProfit(order.sizeDelta, price, order.side, CAP_PRICE);
        _addGlobalLiability(order.side, newMaxProfit, order.sizeDelta);

        if (pos.size == 0) {
            pos.entryPrice = price;
            pos.side = order.side;
            pos.entryFundingIndex = order.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        } else {
            uint256 totalValue = (pos.size * pos.entryPrice) + (order.sizeDelta * price);
            pos.entryPrice = totalValue / (pos.size + order.sizeDelta);
        }

        pos.size += order.sizeDelta;

        // VPI & Fee Calculations
        uint256 postSkewUsdc = _getAbsSkewUsdc(price);
        int256 vpiUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, riskParams.vpiFactor);

        uint256 notionalUsdc = (order.sizeDelta * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 execFeeUsdc = (notionalUsdc * 6) / 10_000;

        int256 tradeCost = vpiUsdc + int256(execFeeUsdc);
        int256 netMarginChange = int256(order.marginDelta) - tradeCost;

        // Settle costs between user and vault via clearinghouse
        if (tradeCost > 0) {
            clearinghouse.seizeAsset(order.accountId, address(usdc), uint256(tradeCost), address(vault));
        } else if (tradeCost < 0) {
            uint256 rebate = uint256(-tradeCost);
            vault.payOut(address(clearinghouse), rebate);
            clearinghouse.settleUsdc(order.accountId, address(usdc), int256(rebate));
        }

        // Lock net margin in clearinghouse and track in position
        if (netMarginChange > 0) {
            clearinghouse.lockMargin(order.accountId, uint256(netMarginChange));
            pos.margin += uint256(netMarginChange);
        } else if (netMarginChange < 0) {
            uint256 deficit = uint256(-netMarginChange);
            require(pos.margin >= deficit, "CfdEngine: Margin drained by fees and VPI");
            clearinghouse.unlockMargin(order.accountId, deficit);
            pos.margin -= deficit;
        }

        accumulatedFeesUsdc += execFeeUsdc;
        emit PositionOpened(order.accountId, order.side, order.sizeDelta, price, order.marginDelta);
    }

    function _processDecrease(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos,
        uint256 price,
        uint256 preSkewUsdc,
        uint256 vaultDepthUsdc
    ) internal {
        require(pos.size >= order.sizeDelta, "CfdEngine: Close size exceeds open position");

        CfdTypes.Position memory closedPart = pos;
        closedPart.size = order.sizeDelta;
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, price, CAP_PRICE);
        int256 realizedPnl = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        // Free proportionate margin
        uint256 marginToFree = (pos.margin * order.sizeDelta) / pos.size;
        pos.margin -= marginToFree;

        // Reduce liability BEFORE size mutation
        uint256 maxProfitReduction = CfdMath.calculateMaxProfit(order.sizeDelta, pos.entryPrice, pos.side, CAP_PRICE);
        _reduceGlobalLiability(pos.side, maxProfitReduction, order.sizeDelta);

        pos.size -= order.sizeDelta;

        // Unlock freed margin in clearinghouse
        clearinghouse.unlockMargin(order.accountId, marginToFree);

        // VPI & Fee Calculations
        uint256 postSkewUsdc = _getAbsSkewUsdc(price);
        int256 vpiUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, riskParams.vpiFactor);

        uint256 notionalUsdc = (order.sizeDelta * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 execFeeUsdc = (notionalUsdc * 6) / 10_000;

        // Net settlement = PnL - costs
        int256 netSettlement = realizedPnl - vpiUsdc - int256(execFeeUsdc);

        if (netSettlement > 0) {
            vault.payOut(address(clearinghouse), uint256(netSettlement));
            clearinghouse.settleUsdc(order.accountId, address(usdc), netSettlement);
        } else if (netSettlement < 0) {
            clearinghouse.seizeAsset(order.accountId, address(usdc), uint256(-netSettlement), address(vault));
        }

        accumulatedFeesUsdc += execFeeUsdc;

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
        require(vault.totalAssets() >= maxLiability, "CfdEngine: Vault Solvency Capacity Exceeded");
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

    /// @notice Returns true during the Friday Afternoon Deleverage (FAD) window.
    ///         FAD raises maintenance margin (fadMarginBps) during weekend market closure:
    ///         Friday 19:00 UTC through Sunday 22:00 UTC.
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

        return false;
    }

    /// @notice Returns the maintenance margin requirement in USDC (6 decimals).
    ///         Uses fadMarginBps during the FAD window, maintMarginBps otherwise.
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
    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external onlyRouter nonReentrant returns (uint256 keeperBountyUsdc) {
        uint256 price = currentOraclePrice > CAP_PRICE ? CAP_PRICE : currentOraclePrice;
        _updateFunding(price, vaultDepthUsdc);

        CfdTypes.Position storage pos = positions[accountId];
        require(pos.size > 0, "CfdEngine: No position to liquidate");

        // 1. Calculate Account Equity
        int256 pendingFunding = getPendingFunding(pos);
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(pos, price, CAP_PRICE);

        int256 equityUsdc = int256(pos.margin) + pendingFunding;
        equityUsdc = isProfit ? equityUsdc + int256(pnlAbs) : equityUsdc - int256(pnlAbs);

        // 2. Evaluate Liquidation Condition
        uint256 mmUsdc = getMaintenanceMarginUsdc(pos.size, price);
        require(equityUsdc < int256(mmUsdc), "CfdEngine: Position is solvent");

        // 3. Free global liabilities
        uint256 maxProfitReduction = CfdMath.calculateMaxProfit(pos.size, pos.entryPrice, pos.side, CAP_PRICE);
        _reduceGlobalLiability(pos.side, maxProfitReduction, pos.size);

        // 4. Keeper Bounty
        uint256 notionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        keeperBountyUsdc = (notionalUsdc * riskParams.bountyBps) / 10_000;
        if (keeperBountyUsdc < riskParams.minBountyUsdc) {
            keeperBountyUsdc = riskParams.minBountyUsdc;
        }

        // 5. Ethical settlement via clearinghouse
        uint256 posMargin = pos.margin;
        clearinghouse.unlockMargin(accountId, posMargin);

        int256 residual = equityUsdc - int256(keeperBountyUsdc);

        if (residual >= 0) {
            if (uint256(residual) <= posMargin) {
                uint256 toSeize = posMargin - uint256(residual);
                if (toSeize > 0) {
                    clearinghouse.seizeAsset(accountId, address(usdc), toSeize, address(vault));
                }
            } else {
                uint256 toPay = uint256(residual) - posMargin;
                vault.payOut(address(clearinghouse), toPay);
                clearinghouse.settleUsdc(accountId, address(usdc), int256(toPay));
            }
        } else {
            if (posMargin > 0) {
                clearinghouse.seizeAsset(accountId, address(usdc), posMargin, address(vault));
            }
        }

        emit PositionLiquidated(accountId, pos.side, pos.size, price, keeperBountyUsdc);
        delete positions[accountId];

        _assertPostSolvency();
    }

    function _assertPostSolvency() internal view {
        uint256 maxLiability = globalBullMaxProfit > globalBearMaxProfit ? globalBullMaxProfit : globalBearMaxProfit;
        require(vault.totalAssets() >= maxLiability, "CfdEngine: Post-op solvency breach");
    }

}
