// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import "forge-std/Script.sol";

/**
 * @title CreateMorphoMarkets
 * @notice Creates Morpho Blue markets for the latest mainnet deployment.
 * @dev Uses deployed StakedOracle + StakedToken addresses from deployments/mainnet.json.
 *
 *      Dry run:
 *        source .env && forge script script/CreateMorphoMarkets.s.sol --tc CreateMorphoMarkets \
 *          --rpc-url $MAINNET_RPC_URL
 *
 *      Broadcast:
 *        source .env && forge script script/CreateMorphoMarkets.s.sol --tc CreateMorphoMarkets \
 *          --rpc-url $MAINNET_RPC_URL --broadcast
 */
contract CreateMorphoMarkets is Script {

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    address constant STAKED_BEAR = 0x4f7310E8bDa646A7DA4b8F1bBE83073380C5Dc53;
    address constant STAKED_BULL = 0x3B859C74d628dAe76C95fA3b2A9d1A50aB153E2D;
    address constant STAKED_ORACLE_BEAR = 0x7e22eEc2506aE777b5093F030de69dF04b2c4c93;
    address constant STAKED_ORACLE_BULL = 0x18770Dff1fa9c38a78b3F2ae48de5b65FC5859bD;

    uint256 constant LLTV = 0.915e18;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deployer:", deployer);

        MarketParams memory bearMarket = MarketParams({
            loanToken: USDC, collateralToken: STAKED_BEAR, oracle: STAKED_ORACLE_BEAR, irm: MORPHO_IRM, lltv: LLTV
        });

        MarketParams memory bullMarket = MarketParams({
            loanToken: USDC, collateralToken: STAKED_BULL, oracle: STAKED_ORACLE_BULL, irm: MORPHO_IRM, lltv: LLTV
        });

        bytes32 bearMarketId = keccak256(abi.encode(bearMarket));
        bytes32 bullMarketId = keccak256(abi.encode(bullMarket));

        console.log("BEAR market ID:");
        console.logBytes32(bearMarketId);
        console.log("BULL market ID:");
        console.logBytes32(bullMarketId);

        vm.startBroadcast(privateKey);

        IMorpho(MORPHO_BLUE).createMarket(bearMarket);
        console.log("BEAR market created");

        IMorpho(MORPHO_BLUE).createMarket(bullMarket);
        console.log("BULL market created");

        vm.stopBroadcast();
    }

}
