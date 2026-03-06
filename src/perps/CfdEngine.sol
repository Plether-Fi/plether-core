// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdMath} from "./CfdMath.sol";
import {CfdTypes} from "./CfdTypes.sol";

/// @title CfdEngine
/// @notice The core mathematical ledger and clearinghouse for Plether CFDs.
/// @dev Holds NO funds. Exclusively manages O(1) Solvency and Funding.
contract CfdEngine {

    uint256 public immutable CAP_PRICE;

    // ==========================================
    // GLOBAL STATE & SOLVENCY BOUNDS
    // ==========================================

    // Max theoretical payouts in USDC (6 decimals)
    uint256 public globalBullMaxProfit;
    uint256 public globalBearMaxProfit;

    // Aggregate user margin held by the engine (6 decimals)
    uint256 public globalMargin;

    // Open Interest in Notional Size (18 decimals)
    uint256 public bullOI;
    uint256 public bearOI;

    // ==========================================
    // FUNDING ACCUMULATORS
    // ==========================================

    // Stored as 6-decimal USDC per 1e18 Size
    int256 public bullFundingIndex;
    int256 public bearFundingIndex;
    uint64 public lastFundingTime;

    CfdTypes.RiskParams public riskParams;
    mapping(bytes32 => CfdTypes.Position) public positions;

    // Auth (Only the MEV-Shield Router can call this)
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
        uint256 _capPrice,
        CfdTypes.RiskParams memory _riskParams
    ) {
        CAP_PRICE = _capPrice;
        riskParams = _riskParams;
        lastFundingTime = uint64(block.timestamp);
    }

    function setOrderRouter(
        address _router
    ) external {
        require(orderRouter == address(0), "CfdEngine: Router already set");
        orderRouter = _router;
    }

    // ==========================================
    // 1. CONTINUOUS FUNDING SYSTEM
    // ==========================================

    /// @notice Lazily updates the dual signed accumulators based on current skew
    function updateFunding(
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) public {
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

            // Multiply first, divide last
            uint256 fundingDelta = (annRate * timeDelta) / CfdMath.SECONDS_PER_YEAR;

            // Convert APY to "USDC per 1e18 Size"
            uint256 stepUsdc = (currentOraclePrice * fundingDelta) / CfdMath.USDC_TO_TOKEN_SCALE;
            int256 step = int256(stepUsdc);

            if (step > 0) {
                if (bullMajority) {
                    bullFundingIndex -= step; // Majority Pays (Index drops)
                    bearFundingIndex += step; // Minority Receives (Index rises)
                } else {
                    bearFundingIndex -= step;
                    bullFundingIndex += step;
                }
            }
        }

        lastFundingTime = uint64(block.timestamp);
        emit FundingUpdated(bullFundingIndex, bearFundingIndex, absSkew);
    }

    /// @notice Calculates pending funding PnL for a specific position
    function getPendingFunding(
        CfdTypes.Position memory pos
    ) public view returns (int256 fundingUsdc) {
        if (pos.size == 0) {
            return 0;
        }
        int256 currentIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        int256 indexDelta = currentIndex - pos.entryFundingIndex;

        // Size(18) * IndexDelta(6) / 1e18 = USDC(6)
        fundingUsdc = (int256(pos.size) * indexDelta) / int256(CfdMath.WAD);
    }

    // ==========================================
    // 2. ORDER PROCESSING & NETTING
    // ==========================================

    /// @notice Executes an intent, updates the ledger, and returns the net cash flow required.
    /// @return settlementUsdc Positive = Protocol pays User. Negative = User pays Protocol.
    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external onlyRouter returns (int256 settlementUsdc) {
        // Clamp oracle price to CAP to enforce O(1) mathematical safety bounds
        uint256 price = currentOraclePrice > CAP_PRICE ? CAP_PRICE : currentOraclePrice;

        // 1. Always update global funding state first
        updateFunding(price, vaultDepthUsdc);

        CfdTypes.Position storage pos = positions[order.accountId];
        uint256 preSkewUsdc = _getAbsSkewUsdc(price);

        // 2. Strict Netting Rule (No-Flip enforcement)
        if (pos.size > 0 && pos.side != order.side) {
            require(order.isClose, "CfdEngine: Must explicitly close opposing position first");
        }

        // 3. Settle accumulated funding PnL directly into the margin
        int256 pendingFunding = getPendingFunding(pos);
        if (pos.size > 0 && pendingFunding != 0) {
            if (pendingFunding > 0) {
                pos.margin += uint256(pendingFunding);
                globalMargin += uint256(pendingFunding);
            } else {
                uint256 loss = uint256(-pendingFunding);
                if (pos.margin >= loss) {
                    pos.margin -= loss;
                    globalMargin -= loss;
                } else {
                    globalMargin -= pos.margin;
                    pos.margin = 0; // Liquidatable
                }
            }
            pos.entryFundingIndex = pos.side == CfdTypes.Side.BULL ? bullFundingIndex : bearFundingIndex;
        }

        // 4. State Transitions
        if (order.isClose) {
            settlementUsdc = _processDecrease(order, pos, price, preSkewUsdc, vaultDepthUsdc);
        } else {
            settlementUsdc = _processIncrease(order, pos, price, preSkewUsdc, vaultDepthUsdc);
        }

        pos.lastUpdateTime = uint64(block.timestamp);
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
    ) internal returns (int256 settlementUsdc) {
        // O(1) Solvency Check
        uint256 newMaxProfit = CfdMath.calculateMaxProfit(order.sizeDelta, price, order.side, CAP_PRICE);
        _addGlobalLiability(order.side, newMaxProfit, order.sizeDelta, vaultDepthUsdc);

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
        uint256 execFeeUsdc = (notionalUsdc * 6) / 10_000; // 6 bps

        // Subtract costs from user's provided margin delta
        int256 tradeCost = vpiUsdc + int256(execFeeUsdc);
        int256 netMarginChange = int256(order.marginDelta) - tradeCost;

        if (netMarginChange > 0) {
            pos.margin += uint256(netMarginChange);
            globalMargin += uint256(netMarginChange);
        } else {
            uint256 deficit = uint256(-netMarginChange);
            require(pos.margin >= deficit, "CfdEngine: Margin drained by fees and VPI");
            pos.margin -= deficit;
            globalMargin -= deficit;
        }

        emit PositionOpened(order.accountId, order.side, order.sizeDelta, price, order.marginDelta);
        return -int256(order.marginDelta); // User pays margin to Protocol
    }

    function _processDecrease(
        CfdTypes.Order memory order,
        CfdTypes.Position storage pos,
        uint256 price,
        uint256 preSkewUsdc,
        uint256 vaultDepthUsdc
    ) internal returns (int256 settlementUsdc) {
        require(pos.size >= order.sizeDelta, "CfdEngine: Close size exceeds open position");

        CfdTypes.Position memory closedPart = pos;
        closedPart.size = order.sizeDelta;
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculatePnL(closedPart, price, CAP_PRICE);
        int256 realizedPnl = isProfit ? int256(pnlAbs) : -int256(pnlAbs);

        // Free proportionate margin
        uint256 marginToFree = (pos.margin * order.sizeDelta) / pos.size;
        pos.margin -= marginToFree;
        globalMargin -= marginToFree;
        pos.size -= order.sizeDelta;

        // Free up Vault Capacity
        uint256 maxProfitReduction = CfdMath.calculateMaxProfit(order.sizeDelta, pos.entryPrice, pos.side, CAP_PRICE);
        _reduceGlobalLiability(pos.side, maxProfitReduction, order.sizeDelta);

        // VPI & Fee Calculations
        uint256 postSkewUsdc = _getAbsSkewUsdc(price);
        int256 vpiUsdc = CfdMath.calculateVPI(preSkewUsdc, postSkewUsdc, vaultDepthUsdc, riskParams.vpiFactor);

        uint256 notionalUsdc = (order.sizeDelta * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 execFeeUsdc = (notionalUsdc * 6) / 10_000;

        int256 totalPayout = int256(marginToFree) + realizedPnl - vpiUsdc - int256(execFeeUsdc);
        require(totalPayout >= 0, "CfdEngine: Close payout cannot be negative");

        emit PositionClosed(order.accountId, pos.side, order.sizeDelta, price, realizedPnl);

        if (pos.size == 0) {
            delete positions[order.accountId];
        }
        return totalPayout; // Protocol pays User
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
        uint256 sizeDelta,
        uint256 vaultDepthUsdc
    ) internal {
        if (side == CfdTypes.Side.BULL) {
            globalBullMaxProfit += maxProfitUsdc;
            bullOI += sizeDelta;
        } else {
            globalBearMaxProfit += maxProfitUsdc;
            bearOI += sizeDelta;
        }
        uint256 maxLiability = globalBullMaxProfit > globalBearMaxProfit ? globalBullMaxProfit : globalBearMaxProfit;
        require(vaultDepthUsdc >= maxLiability, "CfdEngine: Vault Solvency Capacity Exceeded");
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

    /// @notice Determines if the Friday Auto-Deleverage (FAD) is active
    /// @dev Friday 19:00 UTC to Sunday 22:00 UTC
    function isFadWindow() public view returns (bool) {
        // Unix epoch 0 (Jan 1 1970) was a Thursday (Day 4)
        uint256 dayOfWeek = ((block.timestamp / 86_400) + 4) % 7;
        uint256 hourOfDay = (block.timestamp % 86_400) / 3600;

        if (dayOfWeek == 5 && hourOfDay >= 19) {
            return true; // Friday >= 19:00 UTC
        }
        if (dayOfWeek == 6) {
            return true; // Saturday all day
        }
        if (dayOfWeek == 0 && hourOfDay < 22) {
            return true; // Sunday < 22:00 UTC
        }

        return false;
    }

    /// @notice Returns required Maintenance Margin in USDC (6 dec)
    function getMaintenanceMarginUsdc(
        uint256 size,
        uint256 currentOraclePrice
    ) public view returns (uint256) {
        uint256 notionalUsdc = (size * currentOraclePrice) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 requiredBps = isFadWindow() ? riskParams.fadMarginBps : riskParams.maintMarginBps;
        return (notionalUsdc * requiredBps) / 10_000;
    }

    /// @notice Forcefully closes an undercollateralized position
    /// @return keeperBountyUsdc The USDC reward sent to the Liquidator
    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external onlyRouter returns (uint256 keeperBountyUsdc) {
        uint256 price = currentOraclePrice > CAP_PRICE ? CAP_PRICE : currentOraclePrice;
        updateFunding(price, vaultDepthUsdc);

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

        // 3. Free up global liability caps and margin lock
        uint256 maxProfitReduction = CfdMath.calculateMaxProfit(pos.size, pos.entryPrice, pos.side, CAP_PRICE);
        _reduceGlobalLiability(pos.side, maxProfitReduction, pos.size);
        globalMargin -= pos.margin; // Clear isolated margin from Vault lock tracker

        // 4. Calculate Keeper Bounty (Proportional for L2 gas wars)
        uint256 notionalUsdc = (pos.size * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        keeperBountyUsdc = (notionalUsdc * riskParams.bountyBps) / 10_000;

        if (keeperBountyUsdc < riskParams.minBountyUsdc) {
            keeperBountyUsdc = riskParams.minBountyUsdc; // Minimum $5 gas floor
        }

        emit PositionLiquidated(accountId, pos.side, pos.size, price, keeperBountyUsdc);

        // 5. Delete Position
        delete positions[accountId];
    }

}
