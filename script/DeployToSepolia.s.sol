// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {BasketOracle} from "../src/BasketOracle.sol";
import {YieldAdapter} from "../src/YieldAdapter.sol";
import {MockYieldAdapter} from "../src/MockYieldAdapter.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
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

        // Set CAP (example: 2 with 8 decimals, adjust as needed)
        uint256 cap = 2 * 10 ** 8;

        // Treasury (using deployer as example)
        address treasury = deployer;

        // Sequencer Uptime Feed (address(0) since Sepolia is L1, no sequencer)
        address sequencerUptimeFeed = address(0);

        // ============================================
        // OPTION A: MockYieldAdapter (for testnet)
        // ============================================
        MockYieldAdapter mockAdapter = new MockYieldAdapter(IERC20(usdc), deployer);

        SyntheticSplitter splitter =
            new SyntheticSplitter(address(oracle), usdc, address(mockAdapter), cap, treasury, sequencerUptimeFeed);

        console.log("BasketOracle deployed at:", address(oracle));
        console.log("MockAdapter deployed at:", address(mockAdapter));
        console.log("SyntheticSplitter deployed at:", address(splitter));
        console.log("Bear Token (TOKEN_A):", address(splitter.TOKEN_A()));
        console.log("Bull Token (TOKEN_B):", address(splitter.TOKEN_B()));

        // ============================================
        // OPTION B: Real YieldAdapter (for mainnet)
        // Uses CREATE2 to predict Splitter address before deploying Adapter
        // Uncomment below and comment out Option A for production
        // ============================================
        /*
        bytes32 salt = keccak256("PlethSyntheticSplitterV1");

        // Predict the Splitter address using CREATE2
        // Note: The Splitter constructor args must match exactly
        bytes memory splitterCreationCode = abi.encodePacked(
            type(SyntheticSplitter).creationCode,
            abi.encode(address(oracle), usdc, address(0), cap, treasury, sequencerUptimeFeed)
        );

        // This will be the Splitter address (we update adapter address in creationCode after computing)
        address predictedSplitter = vm.computeCreate2Address(
            salt,
            keccak256(splitterCreationCode)
        );

        // Deploy YieldAdapter with the predicted Splitter address (immutable)
        YieldAdapter yieldAdapter = new YieldAdapter(
            IERC20(usdc),
            aavePool,
            aUsdc,
            deployer,
            predictedSplitter  // This will be the Splitter's address
        );

        // Now deploy Splitter with CREATE2 at the predicted address
        // Update creation code with actual adapter address
        SyntheticSplitter splitterProd = new SyntheticSplitter{salt: salt}(
            address(oracle),
            usdc,
            address(yieldAdapter),
            cap,
            treasury,
            sequencerUptimeFeed
        );

        // Verify deployment
        require(address(splitterProd) == predictedSplitter, "CREATE2 address mismatch!");

        console.log("BasketOracle deployed at:", address(oracle));
        console.log("YieldAdapter deployed at:", address(yieldAdapter));
        console.log("SyntheticSplitter deployed at:", address(splitterProd));
        console.log("Bear Token (TOKEN_A):", address(splitterProd.TOKEN_A()));
        console.log("Bull Token (TOKEN_B):", address(splitterProd.TOKEN_B()));
        */

        vm.stopBroadcast();
    }
}
