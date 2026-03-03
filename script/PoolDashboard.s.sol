// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

interface ICurvePoolView {

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);
    function price_oracle() external view returns (uint256);
    function last_prices() external view returns (uint256);
    function price_scale() external view returns (uint256);
    function balances(
        uint256 i
    ) external view returns (uint256);

}

/// @title PoolDashboard
/// @notice Read-only dashboard: Oracle vs Curve pool price + rebalance estimate.
/// @dev Usage: source .env && forge script script/PoolDashboard.s.sol --fork-url $MAINNET_RPC_URL
contract PoolDashboard is Script {

    AggregatorV3Interface constant ORACLE = AggregatorV3Interface(0xfFc35FD33C2acF241F6e46625C7571D64f8AddbD);
    ICurvePoolView constant POOL = ICurvePoolView(0x2354579380cAd0518C6518e5Ee2A66d30d0149bE);

    function run() external view {
        console2.log("");
        console2.log("===========================================");
        console2.log("  PLETHER POOL DASHBOARD");
        console2.log("===========================================");

        (, int256 rawPrice,, uint256 updatedAt,) = ORACLE.latestRoundData();
        require(rawPrice > 0, "Oracle price <= 0");
        uint256 oraclePrice8 = uint256(rawPrice);
        uint256 oracleAge = block.timestamp - updatedAt;

        console2.log("");
        console2.log("--- Oracle (BasketOracle) ---");
        console2.log(string.concat("  BEAR price:    ", _fmtPrice(oraclePrice8, 8)));
        console2.log(string.concat("  BULL price:    ", _fmtPrice(2e8 - oraclePrice8, 8)));
        console2.log(
            string.concat(
                "  Last updated:  ", vm.toString(oracleAge / 3600), "h ", vm.toString((oracleAge % 3600) / 60), "m ago"
            )
        );

        uint256 usdcBal = POOL.balances(0);
        uint256 bearBal = POOL.balances(1);
        uint256 priceOracle18 = POOL.price_oracle();
        uint256 lastPrices18 = POOL.last_prices();
        uint256 priceScale18 = POOL.price_scale();

        uint256 spotBuy = POOL.get_dy(0, 1, 1e6);
        uint256 spotSell = POOL.get_dy(1, 0, 1e18);

        uint256 buyPrice18 = 1e36 / spotBuy;
        uint256 mid18 = (buyPrice18 + spotSell * 1e12) / 2;

        console2.log("");
        console2.log("--- Curve Pool ---");
        console2.log(string.concat("  EMA oracle:    ", _fmtPrice(priceOracle18, 18)));
        console2.log(string.concat("  Last trade:    ", _fmtPrice(lastPrices18, 18)));
        console2.log(string.concat("  Spot buy:      ", _fmtPrice(buyPrice18, 18), "  (1 USDC -> BEAR)"));
        console2.log(string.concat("  Spot sell:     ", _fmtPrice(spotSell * 1e12, 18), "  (1 BEAR -> USDC)"));
        console2.log(string.concat("  Mid-market:    ", _fmtPrice(mid18, 18)));
        console2.log(string.concat("  Price scale:   ", _fmtPrice(priceScale18, 18)));
        console2.log("");
        console2.log(string.concat("  USDC balance:  ", _fmtAmount(usdcBal, 6)));
        console2.log(string.concat("  BEAR balance:  ", _fmtAmount(bearBal, 18)));

        uint256 tvl = usdcBal + (bearBal / 1e12) * mid18 / 1e18;
        console2.log(string.concat("  ~TVL (USDC):   ", _fmtAmount(tvl, 6)));

        console2.log("");
        console2.log("--- Price Comparison ---");

        uint256 oracle18 = oraclePrice8 * 1e10;
        if (mid18 > oracle18) {
            uint256 diff = mid18 - oracle18;
            uint256 diffBps = diff * 10_000 / oracle18;
            console2.log(string.concat("  Pool premium:  ", _fmtPrice(diff, 18), " (", vm.toString(diffBps), " bps)"));
            console2.log("  -> BEAR is OVERPRICED in pool. Sell BEAR to rebalance.");
        } else {
            uint256 diff = oracle18 - mid18;
            uint256 diffBps = diff * 10_000 / oracle18;
            console2.log(string.concat("  Pool discount: ", _fmtPrice(diff, 18), " (", vm.toString(diffBps), " bps)"));
            console2.log("  -> BEAR is UNDERPRICED in pool. Buy BEAR to rebalance.");
        }

        console2.log("");
        console2.log("--- Rebalance Estimate ---");

        (bool found, uint256 amount, bool isSell) = _findRebalanceAmount(oraclePrice8);
        if (!found) {
            console2.log("  Could not converge on rebalance amount.");
        } else if (amount < 1e18) {
            console2.log("  Pool is already balanced (< 1 BEAR difference).");
        } else {
            console2.log(string.concat("  Action:        ", isSell ? "Sell" : "Buy", " BEAR"));
            console2.log(string.concat("  Amount:        ", _fmtAmount(amount, 18), " BEAR"));

            if (isSell) {
                uint256 usdcOut = POOL.get_dy(1, 0, amount);
                console2.log(string.concat("  You receive:   ", _fmtAmount(usdcOut, 6), " USDC"));
                console2.log(string.concat("  Avg exec price:", _fmtPrice(usdcOut * 1e12 * 1e18 / amount, 18)));
            } else {
                uint256 bearOut = POOL.get_dy(0, 1, amount);
                console2.log(string.concat("  You spend:     ", _fmtAmount(amount, 6), " USDC"));
                console2.log(string.concat("  You receive:   ", _fmtAmount(bearOut, 18), " BEAR"));
                console2.log(string.concat("  Avg exec price:", _fmtPrice(amount * 1e12 * 1e18 / bearOut, 18)));
            }
        }

        console2.log("");
        console2.log("===========================================");
    }

    /// @dev Binary search for trade amount so post-trade marginal price matches oracle.
    function _findRebalanceAmount(
        uint256 oraclePrice8
    ) internal view returns (bool found, uint256 amount, bool isSell) {
        uint256 target6 = oraclePrice8 / 100;

        uint256 currentMarginalSell = POOL.get_dy(1, 0, 1e18);
        isSell = currentMarginalSell > target6;

        uint256 lo = 0;
        uint256 hi = isSell ? POOL.balances(1) / 2 : POOL.balances(0) / 2;

        for (uint256 i = 0; i < 64; i++) {
            uint256 mid = (lo + hi) / 2;
            if (mid == lo) {
                break;
            }

            uint256 marginal = _marginalAfter(mid, isSell);
            if (isSell) {
                if (marginal > target6) {
                    lo = mid;
                } else {
                    hi = mid;
                }
            } else {
                if (marginal < target6) {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
        }

        return (true, (lo + hi) / 2, isSell);
    }

    /// @dev Marginal price of the next BEAR after a cumulative trade of `cumAmount`.
    function _marginalAfter(
        uint256 cumAmount,
        bool isSell
    ) internal view returns (uint256) {
        if (isSell) {
            return POOL.get_dy(1, 0, cumAmount + 1e18) - POOL.get_dy(1, 0, cumAmount);
        } else {
            uint256 bearDelta = POOL.get_dy(0, 1, cumAmount + 1e6) - POOL.get_dy(0, 1, cumAmount);
            return 1e24 / bearDelta;
        }
    }

    // ── Formatting helpers ──────────────────────────────────────────────

    function _fmtPrice(
        uint256 value,
        uint256 dec
    ) internal pure returns (string memory) {
        uint256 whole = value / (10 ** dec);
        uint256 frac = (value % (10 ** dec)) * 1e6 / (10 ** dec);
        return string.concat("$", vm.toString(whole), ".", _padLeft(vm.toString(frac), 6));
    }

    function _fmtAmount(
        uint256 value,
        uint256 dec
    ) internal pure returns (string memory) {
        uint256 whole = value / (10 ** dec);
        uint256 frac = (value % (10 ** dec)) * 100 / (10 ** dec);
        return string.concat(vm.toString(whole), ".", _padLeft(vm.toString(frac), 2));
    }

    function _padLeft(
        string memory s,
        uint256 width
    ) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) {
            return s;
        }
        uint256 pad = width - b.length;
        bytes memory zeros = new bytes(pad);
        for (uint256 i = 0; i < pad; i++) {
            zeros[i] = "0";
        }
        return string.concat(string(zeros), s);
    }

}
