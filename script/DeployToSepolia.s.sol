// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythAdapter} from "../src/oracles/PythAdapter.sol";
import {DeployToTest} from "./DeployToTest.s.sol";
import "forge-std/console.sol";

/**
 * @title ZeroRateIrm
 * @notice Simple zero-rate IRM for Sepolia (AdaptiveCurveIrm not deployed there)
 * @dev Returns 0% APY regardless of utilization - suitable for testnet only
 */
contract ZeroRateIrm {

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    function borrowRateView(
        MarketParams memory,
        Market memory
    ) external pure returns (uint256) {
        return 0;
    }

    function borrowRate(
        MarketParams memory,
        Market memory
    ) external pure returns (uint256) {
        return 0;
    }

}

/// @notice Minimal interface for Morpho owner functions
interface IMorphoOwner {

    function enableIrm(
        address irm
    ) external;
    function enableLltv(
        uint256 lltv
    ) external;

}

/**
 * @title DeployToSepolia
 * @notice Deployment script for Plether protocol on Sepolia testnet
 * @dev Uses live Chainlink feeds (EUR, JPY, GBP) + Pyth adapters (CAD, CHF, SEK).
 *      Deploys own Morpho instance + IRM since the public Morpho on Sepolia has no enabled IRMs/LLTVs.
 */
contract DeployToSepolia is DeployToTest {

    // Chainlink Sepolia feeds
    address constant CHAINLINK_EUR_USD = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;
    address constant CHAINLINK_JPY_USD = 0x8A6af2B75F23831ADc973ce6288e5329F63D86c6;
    address constant CHAINLINK_GBP_USD = 0x91FAB41F5f3bE955963a986366edAcff1aaeaa83;

    // Pyth feed IDs (USD/X, inverted to X/USD via PythAdapter)
    bytes32 constant PYTH_CAD_USD = 0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca;
    bytes32 constant PYTH_CHF_USD = 0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8;
    bytes32 constant PYTH_SEK_USD = 0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676;

    // Pyth on Sepolia
    address constant PYTH_SEPOLIA = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21;

    address public deployedMorpho;
    ZeroRateIrm public deployedIrm;

    function _getPythAddress() internal pure override returns (address) {
        return PYTH_SEPOLIA;
    }

    function _deployMockFeeds()
        internal
        override
        returns (address[] memory feeds, uint256[] memory quantities, uint256[] memory basePrices)
    {
        feeds = new address[](6);

        // Chainlink live feeds (EUR, JPY, GBP)
        feeds[0] = CHAINLINK_EUR_USD;
        feeds[1] = CHAINLINK_JPY_USD;
        feeds[2] = CHAINLINK_GBP_USD;
        console.log("Using Chainlink EUR/USD:", CHAINLINK_EUR_USD);
        console.log("Using Chainlink JPY/USD:", CHAINLINK_JPY_USD);
        console.log("Using Chainlink GBP/USD:", CHAINLINK_GBP_USD);

        // Pyth adapters (CAD, CHF, SEK) - inverted from USD/X to X/USD
        feeds[3] = address(new PythAdapter(PYTH_SEPOLIA, PYTH_CAD_USD, 24 hours, "CAD / USD", true));
        feeds[4] = address(new PythAdapter(PYTH_SEPOLIA, PYTH_SEK_USD, 24 hours, "SEK / USD", true));
        feeds[5] = address(new PythAdapter(PYTH_SEPOLIA, PYTH_CHF_USD, 24 hours, "CHF / USD", true));
        console.log("PythAdapter CAD/USD:", feeds[3]);
        console.log("PythAdapter SEK/USD:", feeds[4]);
        console.log("PythAdapter CHF/USD:", feeds[5]);

        // Push initial Pyth prices from env
        bytes memory rawUpdateData = vm.envBytes("PYTH_UPDATE_DATA");
        bytes[] memory updateData = abi.decode(rawUpdateData, (bytes[]));
        uint256 fee = IPyth(PYTH_SEPOLIA).getUpdateFee(updateData);
        IPyth(PYTH_SEPOLIA).updatePriceFeeds{value: fee}(updateData);
        console.log("Pyth prices updated (fee: %s wei)", fee);

        // Quantities unchanged (DXY weights)
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

    function _getMorphoAddress() internal override returns (address) {
        if (deployedMorpho == address(0)) {
            uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
            address deployer = vm.addr(privateKey);

            bytes memory morphoInitCode = vm.readFileBinary("script/bytecode/Morpho.bin");
            bytes memory morphoCreationCode = abi.encodePacked(morphoInitCode, abi.encode(deployer));

            address morpho;
            assembly {
                morpho := create(0, add(morphoCreationCode, 0x20), mload(morphoCreationCode))
            }
            require(morpho != address(0), "Morpho deployment failed");
            deployedMorpho = morpho;
            console.log("Morpho deployed:", morpho);

            deployedIrm = new ZeroRateIrm();
            console.log("ZeroRateIrm deployed:", address(deployedIrm));
            IMorphoOwner(morpho).enableIrm(address(deployedIrm));
            console.log("ZeroRateIrm enabled in Morpho");

            IMorphoOwner(morpho).enableLltv(LLTV);
            console.log("LLTV 91.5% enabled in Morpho");
        }
        return deployedMorpho;
    }

    function _getIrmAddress() internal override returns (address) {
        _getMorphoAddress();
        return address(deployedIrm);
    }

    function _getNonceOffset() internal pure override returns (uint64) {
        // Base (37) + Morpho(1) + ZeroRateIrm(1) + enableIrm(1) + enableLltv(1) = 41
        // Feed delta: -6 MockV3Agg + 3 PythAdapter + 1 updatePriceFeeds = -2
        // Pyth delta: -1 MockPyth - 1 setPrice = -2
        // Total: 41 - 2 - 2 = 37
        return 37;
    }

}
