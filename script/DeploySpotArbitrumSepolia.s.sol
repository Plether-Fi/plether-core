// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythAdapter} from "../src/oracles/PythAdapter.sol";
import {IMorphoOwner, ZeroRateIrm} from "./DeployToSepolia.s.sol";
import {DeployToTest, IMintableERC20} from "./DeployToTest.s.sol";
import {MockTwocryptoPool} from "./mocks/MockTwocryptoPool.s.sol";
import "forge-std/console.sol";

/**
 * @title DeploySpotArbitrumSepolia
 * @notice Deploys the spot stack to Arbitrum Sepolia using the released perps mock USDC.
 * @dev Uses a testnet-only mock twocrypto pool because the Sepolia Curve factory is not present on Arbitrum Sepolia.
 */
contract DeploySpotArbitrumSepolia is DeployToTest {

    address internal constant DEFAULT_SHARED_USDC = 0xf1e1B188b87525C51ECe4bae8627ae621D769651;
    address internal constant PYTH_ARBITRUM_SEPOLIA = 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF;

    bytes32 internal constant PYTH_EUR_USD = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    bytes32 internal constant PYTH_USD_JPY = 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    bytes32 internal constant PYTH_GBP_USD = 0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1;
    bytes32 internal constant PYTH_USD_CAD = 0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca;
    bytes32 internal constant PYTH_USD_SEK = 0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676;
    bytes32 internal constant PYTH_USD_CHF = 0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8;

    address public deployedMorpho;
    ZeroRateIrm public deployedIrm;

    function _getPythAddress() internal pure override returns (address) {
        return PYTH_ARBITRUM_SEPOLIA;
    }

    function _deployOrLoadUsdc() internal view override returns (IMintableERC20 usdc) {
        address perpsUsdc = vm.envOr("PERPS_USDC", DEFAULT_SHARED_USDC);
        address usdcAddress = vm.envOr("SPOT_USDC", perpsUsdc);

        require(usdcAddress.code.length > 0, "USDC has no code");
        usdc = IMintableERC20(usdcAddress);
        require(usdc.decimals() == 6, "USDC must have 6 decimals");

        console.log("Using shared USDC:", usdcAddress);
    }

    function _deployMockFeeds()
        internal
        override
        returns (address[] memory feeds, uint256[] memory quantities, uint256[] memory basePrices)
    {
        feeds = new address[](6);
        feeds[0] = address(new PythAdapter(PYTH_ARBITRUM_SEPOLIA, PYTH_EUR_USD, 72 hours, "EUR / USD", false, 500));
        feeds[1] = address(new PythAdapter(PYTH_ARBITRUM_SEPOLIA, PYTH_USD_JPY, 72 hours, "JPY / USD", true, 500));
        feeds[2] = address(new PythAdapter(PYTH_ARBITRUM_SEPOLIA, PYTH_GBP_USD, 72 hours, "GBP / USD", false, 500));
        feeds[3] = address(new PythAdapter(PYTH_ARBITRUM_SEPOLIA, PYTH_USD_CAD, 72 hours, "CAD / USD", true, 500));
        feeds[4] = address(new PythAdapter(PYTH_ARBITRUM_SEPOLIA, PYTH_USD_SEK, 72 hours, "SEK / USD", true, 500));
        feeds[5] = address(new PythAdapter(PYTH_ARBITRUM_SEPOLIA, PYTH_USD_CHF, 72 hours, "CHF / USD", true, 500));
        console.log("PythAdapter EUR/USD:", feeds[0]);
        console.log("PythAdapter JPY/USD:", feeds[1]);
        console.log("PythAdapter GBP/USD:", feeds[2]);
        console.log("PythAdapter CAD/USD:", feeds[3]);
        console.log("PythAdapter SEK/USD:", feeds[4]);
        console.log("PythAdapter CHF/USD:", feeds[5]);

        bytes memory rawUpdateData = vm.envBytes("PYTH_UPDATE_DATA");
        bytes[] memory updateData = abi.decode(rawUpdateData, (bytes[]));
        uint256 fee = IPyth(PYTH_ARBITRUM_SEPOLIA).getUpdateFee(updateData);
        IPyth(PYTH_ARBITRUM_SEPOLIA).updatePriceFeeds{value: fee}(updateData);
        console.log("Pyth prices updated (fee: %s wei)", fee);

        quantities = new uint256[](6);
        quantities[0] = 576 * 10 ** 15; // EUR: 57.6%
        quantities[1] = 136 * 10 ** 15; // JPY: 13.6%
        quantities[2] = 119 * 10 ** 15; // GBP: 11.9%
        quantities[3] = 91 * 10 ** 15; // CAD: 9.1%
        quantities[4] = 42 * 10 ** 15; // SEK: 4.2%
        quantities[5] = 36 * 10 ** 15; // CHF: 3.6%

        basePrices = new uint256[](6);
        basePrices[0] = 117_500_000; // EUR: $1.1750
        basePrices[1] = 638_000; // JPY: $0.00638
        basePrices[2] = 134_480_000; // GBP: $1.3448
        basePrices[3] = 72_880_000; // CAD: $0.7288
        basePrices[4] = 10_860_000; // SEK: $0.1086
        basePrices[5] = 126_100_000; // CHF: $1.2610
    }

    function _deployCurvePool(
        address usdc,
        address plDxyBear,
        uint256 initialPrice
    ) internal override returns (address pool) {
        pool = address(new MockTwocryptoPool(usdc, plDxyBear, initialPrice));
        console.log("MockTwocryptoPool initial BEAR price:", initialPrice);
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
        // Base offset (40) - fresh MockUSDC (1) + one extra Pyth feed/update tx + local Morpho (4) - local MockPyth (2).
        return 42;
    }

}
