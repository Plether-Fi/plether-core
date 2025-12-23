// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {BasketOracle} from "../src/BasketOracle.sol"; // Adjust path to your BasketOracle contract
// import {YieldAdapter} from "../src/YieldAdapter.sol"; // Adjust path to your YieldAdapter contract
import {MockYieldAdapter} from "../src/MockYieldAdapter.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol"; // Adjust path to your SyntheticSplitter contract
import {SyntheticToken} from "../src/SyntheticToken.sol"; // Adjust path if needed (though deployed internally)
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol"; // Adjust path
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock AggregatorV3Interface for testing on Sepolia (since fiat feeds may not be available)
contract MockV3Aggregator is AggregatorV3Interface {
    int256 private immutable _price;
    uint256 private immutable _updatedAt;

    constructor(int256 price_) {
        _price = price_;
        _updatedAt = block.timestamp;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "Mock Feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _price, 0, _updatedAt, 0);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _price, 0, _updatedAt, 0);
    }
}

contract DeployToSepolia is Script {
    function run() external {
        // Load private key from environment variable
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        // Start broadcasting transactions
        vm.startBroadcast(privateKey);

        // Deploy mock Chainlink feeds for DXY components (since real fiat feeds aren't available on Sepolia)
        // Inline deployments to reduce local variables and avoid stack too deep
        address[] memory feeds = new address[](6);
        feeds[0] = address(new MockV3Aggregator(105000000)); // ~1.05 USD per EUR, 8 decimals
        feeds[1] = address(new MockV3Aggregator(640000)); // ~0.0064 USD per JPY
        feeds[2] = address(new MockV3Aggregator(125000000)); // ~1.25 USD per GBP
        feeds[3] = address(new MockV3Aggregator(73000000)); // ~0.73 USD per CAD
        feeds[4] = address(new MockV3Aggregator(9300000)); // ~0.093 USD per SEK
        feeds[5] = address(new MockV3Aggregator(113000000)); // ~1.13 USD per CHF

        // Prepare quantities based on DXY weights (scaled to 1e18 precision)
        uint256[] memory quantities = new uint256[](6);
        quantities[0] = 576 * 10 ** 15; // 57.6%
        quantities[1] = 136 * 10 ** 15; // 13.6%
        quantities[2] = 119 * 10 ** 15; // 11.9%
        quantities[3] = 91 * 10 ** 15; // 9.1%
        quantities[4] = 42 * 10 ** 15; // 4.2%
        quantities[5] = 36 * 10 ** 15; // 3.6%

        // Deploy BasketOracle
        BasketOracle oracle = new BasketOracle(feeds, quantities);

        // USDC address on Sepolia
        // address usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        address usdc = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;

        // Aave V3 Pool on Sepolia
        address aavePool = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

        // Aave V3 aUSDC on Sepolia
        address aUsdc = 0x16dA4541aD1807f4443d92D26044C1147406EB80;

        // Cast USDC to IERC20 outside the constructor call to reduce stack depth
        IERC20 usdcToken = IERC20(usdc);

        // Deploy YieldAdapter
        // YieldAdapter yieldAdapter = new YieldAdapter(usdcToken, aavePool, aUsdc, deployer);
        MockYieldAdapter mockAdapter = new MockYieldAdapter(IERC20(usdc), deployer);

        // Set CAP (example: 2 with 8 decimals, adjust as needed)
        uint256 cap = 2 * 10 ** 8;

        // Treasury (using deployer as example)
        address treasury = deployer;

        // Sequencer Uptime Feed (address(0) since Sepolia is L1, no sequencer)
        address sequencerUptimeFeed = address(0);

        // Deploy SyntheticSplitter
        SyntheticSplitter splitter =
            new SyntheticSplitter(address(oracle), usdc, address(mockAdapter), cap, treasury, sequencerUptimeFeed);

        // Output deployed addresses (console logs for reference)
        console.log("BasketOracle deployed at:", address(oracle));
        console.log("mockAdapter deployed at:", address(mockAdapter));
        console.log("SyntheticSplitter deployed at:", address(splitter));
        console.log("Bear Token (tokenA):", address(splitter.tokenA()));
        console.log("Bull Token (tokenB):", address(splitter.tokenB()));

        vm.stopBroadcast();
    }
}
