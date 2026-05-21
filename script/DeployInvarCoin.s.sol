// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {InvarCoin} from "../src/InvarCoin.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "forge-std/Script.sol";

interface IMainnetCurvePoolPreflight is IERC20 {

    function coins(
        uint256 index
    ) external view returns (address);
    function get_virtual_price() external view returns (uint256);
    function lp_price() external view returns (uint256);
    function price_oracle() external view returns (uint256);

}

interface IMainnetOraclePreflight {

    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);

}

/// @title DeployInvarCoin
/// @notice Deploys InvarCoin (INVAR) and StakedInvarCoin (sINVAR) with mainnet addresses.
/// @dev Run (dry):
///        source .env && forge script script/DeployInvarCoin.s.sol --tc DeployInvarCoin \
///          --rpc-url $MAINNET_RPC_URL
///
///      Run (broadcast):
///        source .env && forge script script/DeployInvarCoin.s.sol --tc DeployInvarCoin \
///          --rpc-url $MAINNET_RPC_URL --broadcast
contract DeployInvarCoin is Script {

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PLDXY_BEAR = 0x5503FB45370a03909dFfEB207483a2832A9171aD;
    address constant CURVE_LP_TOKEN = CURVE_POOL;
    address constant CURVE_POOL = 0x95D51D6F312DbE66BACC2ed677aD64790f48aa87;
    address constant BASKET_ORACLE = 0x4f798422388484F2139717A8cE0115De3B06b1DF;
    address constant SEQUENCER_UPTIME_FEED = address(0); // L1: no sequencer feed
    address constant CRV_MINTER = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0; // L1 Curve Minter

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deployer:", deployer);
        console.log("");

        _preflight();

        vm.startBroadcast(privateKey);

        InvarCoin ic = new InvarCoin(
            USDC, PLDXY_BEAR, CURVE_LP_TOKEN, CURVE_POOL, BASKET_ORACLE, SEQUENCER_UPTIME_FEED, CRV_MINTER
        );

        StakedToken sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");
        ic.proposeStakedInvarCoin(address(sInvar));

        vm.stopBroadcast();

        require(address(ic.USDC()) == USDC, "USDC mismatch");
        require(address(ic.CURVE_POOL()) == CURVE_POOL, "CURVE_POOL mismatch");
        require(sInvar.asset() == address(ic), "sINVAR asset mismatch");

        console.log("");
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("  InvarCoin (INVAR):", address(ic));
        console.log("  StakedInvarCoin (sINVAR):", address(sInvar));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Verify both contracts on Etherscan");
        console.log("  2. Wait 7 days, then call finalizeStakedInvarCoin()");
        console.log("  3. Propose/finalize a gaugeRewardsReceiver before sweeping rewards");
        console.log("  4. Transfer ownership if needed");
        console.log("  5. Test deposit/deploy/harvest cycle");
        console.log("========================================");
    }

    function _preflight() internal view {
        require(USDC.code.length > 0, "USDC has no code");
        require(PLDXY_BEAR.code.length > 0, "PLDXY_BEAR has no code");
        require(CURVE_POOL.code.length > 0, "CURVE_POOL has no code");
        require(BASKET_ORACLE.code.length > 0, "BASKET_ORACLE has no code");
        require(CRV_MINTER.code.length > 0, "CRV_MINTER has no code");

        require(IERC20Metadata(USDC).decimals() == 6, "USDC decimals mismatch");
        require(IERC20Metadata(PLDXY_BEAR).decimals() == 18, "PLDXY_BEAR decimals mismatch");

        IMainnetCurvePoolPreflight pool = IMainnetCurvePoolPreflight(CURVE_POOL);
        require(pool.coins(0) == USDC, "Curve coin0 mismatch");
        require(pool.coins(1) == PLDXY_BEAR, "Curve coin1 mismatch");
        require(pool.totalSupply() > 0, "Curve pool is not seeded");
        require(pool.price_oracle() > 0, "Curve price_oracle is zero");
        require(pool.lp_price() > 0, "Curve lp_price is zero");
        try pool.get_virtual_price() returns (uint256 virtualPrice) {
            require(virtualPrice > 0, "Curve virtual price is zero");
        } catch {
            revert("Curve get_virtual_price reverts");
        }

        IMainnetOraclePreflight oracle = IMainnetOraclePreflight(BASKET_ORACLE);
        require(oracle.decimals() == 8, "BasketOracle decimals mismatch");
        try oracle.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            require(answer > 0, "BasketOracle answer <= 0");
            require(updatedAt > 0, "BasketOracle updatedAt is zero");
        } catch {
            revert("BasketOracle latestRoundData reverts");
        }
    }

}
