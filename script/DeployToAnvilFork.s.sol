// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PythAdapter} from "../src/oracles/PythAdapter.sol";
import {DeployToTest} from "./DeployToTest.s.sol";
import "forge-std/console.sol";

/**
 * @title DeployToAnvilFork
 * @notice Deployment script for Plether protocol on Anvil mainnet fork
 * @dev Uses real Chainlink oracles and Pyth for live price data
 */
contract DeployToAnvilFork is DeployToTest {

    // Real Chainlink feeds on Ethereum mainnet
    address constant CL_EUR_USD = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;
    address constant CL_JPY_USD = 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3;
    address constant CL_GBP_USD = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address constant CL_CAD_USD = 0xa34317DB73e77d453b1B8d04550c44D10e981C8e;
    address constant CL_CHF_USD = 0x449d117117838fFA61263B61dA6301AA2a88B13A;

    // Pyth on Ethereum mainnet (for SEK/USD)
    address constant PYTH_MAINNET = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    // USD/SEK Pyth price ID (inverted to SEK/USD)
    bytes32 constant USD_SEK_PRICE_ID = 0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676;

    // PythAdapter for SEK (deployed in _deployMockFeeds)
    PythAdapter public sekAdapter;

    function _deployMockFeeds()
        internal
        override
        returns (address[] memory feeds, uint256[] memory quantities, uint256[] memory basePrices)
    {
        // Deploy PythAdapter for SEK first
        sekAdapter = new PythAdapter(PYTH_MAINNET, USD_SEK_PRICE_ID, 24 hours, "SEK / USD", true);
        console.log("PythAdapter (SEK/USD):", address(sekAdapter));

        feeds = new address[](6);
        feeds[0] = CL_EUR_USD;
        feeds[1] = CL_JPY_USD;
        feeds[2] = CL_GBP_USD;
        feeds[3] = CL_CAD_USD;
        feeds[4] = address(sekAdapter);
        feeds[5] = CL_CHF_USD;

        console.log("Using real Chainlink feeds:");
        console.log("  EUR/USD:", CL_EUR_USD);
        console.log("  JPY/USD:", CL_JPY_USD);
        console.log("  GBP/USD:", CL_GBP_USD);
        console.log("  CAD/USD:", CL_CAD_USD);
        console.log("  SEK/USD:", address(sekAdapter), "(via Pyth)");
        console.log("  CHF/USD:", CL_CHF_USD);

        quantities = new uint256[](6);
        quantities[0] = 576 * 10 ** 15; // EUR: 57.6%
        quantities[1] = 136 * 10 ** 15; // JPY: 13.6%
        quantities[2] = 119 * 10 ** 15; // GBP: 11.9%
        quantities[3] = 91 * 10 ** 15; // CAD: 9.1%
        quantities[4] = 42 * 10 ** 15; // SEK: 4.2%
        quantities[5] = 36 * 10 ** 15; // CHF: 3.6%

        // Base prices for normalization (8 decimals, January 1, 2026 reference)
        basePrices = new uint256[](6);
        basePrices[0] = 117_500_000; // EUR: $1.1750
        basePrices[1] = 638_000; // JPY: $0.00638
        basePrices[2] = 134_480_000; // GBP: $1.3448
        basePrices[3] = 72_880_000; // CAD: $0.7288
        basePrices[4] = 10_860_000; // SEK: $0.1086
        basePrices[5] = 126_100_000; // CHF: $1.2610
    }

    function _getNonceOffset() internal pure override returns (uint64) {
        // Base offset (37) - MockV3Aggregators(6) + PythAdapter_SEK(1) = 32
        // Then - MockPyth(1) - setPrice(1) = 30 (using real Pyth)
        return 30;
    }

    function _getPythAddress() internal pure override returns (address) {
        return PYTH_MAINNET;
    }

}
