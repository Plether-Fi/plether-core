// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Script.sol";

interface IMintable {

    function mint(
        address to,
        uint256 amount
    ) external;

}

/**
 * @title SeedMorphoMarkets
 * @notice Creates and seeds Morpho markets with USDC on Anvil (mainnet fork)
 *
 * Prerequisites: Protocol already deployed with StakedTokens and StakedOracles
 *
 * Usage:
 *   1. Start anvil: anvil --fork-url $MAINNET_RPC_URL
 *   2. Update addresses below to match your deployment
 *   3. Run: forge script script/SeedMorphoMarkets.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract SeedMorphoMarkets is Script {

    // ==========================================
    // MORPHO CONSTANTS (same across all chains)
    // ==========================================

    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    uint256 constant LLTV = 0.77e18; // 77%
    uint256 constant SEED_AMOUNT = 1_000_000 * 1e6; // 1M USDC per market

    // ==========================================
    // YOUR DEPLOYED ADDRESSES (update these)
    // ==========================================

    address constant USDC = address(0);
    address constant STAKED_BEAR = address(0); // sDXY-BEAR
    address constant STAKED_BULL = address(0); // sDXY-BULL
    address constant STAKED_ORACLE_BEAR = address(0);
    address constant STAKED_ORACLE_BULL = address(0);

    function run() external {
        require(USDC != address(0), "Set USDC address");
        require(STAKED_BEAR != address(0), "Set STAKED_BEAR address");
        require(STAKED_BULL != address(0), "Set STAKED_BULL address");
        require(STAKED_ORACLE_BEAR != address(0), "Set STAKED_ORACLE_BEAR address");
        require(STAKED_ORACLE_BULL != address(0), "Set STAKED_ORACLE_BULL address");

        uint256 pk =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);

        console.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        deal(USDC, deployer, SEED_AMOUNT * 2);

        MarketParams memory bearParams = MarketParams({
            loanToken: USDC, collateralToken: STAKED_BEAR, oracle: STAKED_ORACLE_BEAR, irm: MORPHO_IRM, lltv: LLTV
        });

        MarketParams memory bullParams = MarketParams({
            loanToken: USDC, collateralToken: STAKED_BULL, oracle: STAKED_ORACLE_BULL, irm: MORPHO_IRM, lltv: LLTV
        });

        IMorpho morpho = IMorpho(MORPHO);

        morpho.createMarket(bearParams);
        morpho.createMarket(bullParams);

        IERC20(USDC).approve(MORPHO, SEED_AMOUNT * 2);
        morpho.supply(bearParams, SEED_AMOUNT, 0, deployer, "");
        morpho.supply(bullParams, SEED_AMOUNT, 0, deployer, "");

        vm.stopBroadcast();

        bytes32 bearMarketId = _marketId(bearParams);
        bytes32 bullMarketId = _marketId(bullParams);

        console.log("");
        console.log("========================================");
        console.log("MORPHO MARKETS CREATED & SEEDED");
        console.log("========================================");
        console.log("");
        console.log("BEAR Market:");
        console.log("  Market ID:   ", vm.toString(bearMarketId));
        console.log("  Loan Token:  ", USDC);
        console.log("  Collateral:  ", STAKED_BEAR);
        console.log("  Oracle:      ", STAKED_ORACLE_BEAR);
        console.log("  LLTV:         77%");
        console.log("  Liquidity:   ", SEED_AMOUNT / 1e6, "USDC");
        console.log("");
        console.log("BULL Market:");
        console.log("  Market ID:   ", vm.toString(bullMarketId));
        console.log("  Loan Token:  ", USDC);
        console.log("  Collateral:  ", STAKED_BULL);
        console.log("  Oracle:      ", STAKED_ORACLE_BULL);
        console.log("  LLTV:         77%");
        console.log("  Liquidity:   ", SEED_AMOUNT / 1e6, "USDC");
        console.log("========================================");
    }

    function _marketId(
        MarketParams memory params
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

}
