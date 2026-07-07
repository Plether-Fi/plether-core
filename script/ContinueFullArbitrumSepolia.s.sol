// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ArbitrumSepoliaTestnetCurvePool, ArbitrumSepoliaZeroRateIrm, IMintableERC20, IMorphoOwner} from "./DeployFullArbitrumSepolia.s.sol";
import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../src/oracles/StakedOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Script.sol";

/// @title ContinueFullArbitrumSepolia
/// @notice Continues after the first four txs of DeployFullArbitrumSepolia landed.
contract ContinueFullArbitrumSepolia is Script {

    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    uint256 internal constant LLTV = 0.915e18;
    uint256 internal constant CAP = 2e8;
    uint256 internal constant CURVE_BEAR_LIQUIDITY = 800_000e18;
    uint256 internal constant MORPHO_LIQUIDITY = 100_000e6;

    address internal constant USDC = 0xf1e1B188b87525C51ECe4bae8627ae621D769651;
    address internal constant SPLITTER = 0xebefb54a70391ACac074fA68d7929C4a7Ea5f77c;
    address internal constant PLDXY_BEAR = 0x37838d96F93B815e7a9AcF76bB94e93ED3C114F5;
    address internal constant PLDXY_BULL = 0x4c96B49e0a140885Ee7eC174adD7f66e53fa5E89;
    address internal constant STAKED_BEAR = 0x1Ea462561cCbFc8C0C7D5B5F4618573001AB30D9;
    address internal constant STAKED_BULL = 0x6B0CeE16329Ac833b512450fe536Db92AfB0A20A;
    address internal constant BASKET_ORACLE = 0x2c448B9c7be8244D7F44Ca8D3B81bd6Fb1F7FCa5;
    address internal constant CURVE_POOL = 0xa17565411Cb83cAa28606e8D2Cb50a9871588715;

    struct DeployedContracts {
        address curvePool;
        address morpho;
        ArbitrumSepoliaZeroRateIrm irm;
        MorphoOracle morphoOracleBear;
        MorphoOracle morphoOracleBull;
        StakedOracle stakedOracleBear;
        StakedOracle stakedOracleBull;
        bytes32 morphoMarketBear;
        bytes32 morphoMarketBull;
        ZapRouter zapRouter;
        LeverageRouter leverageRouter;
        BullLeverageRouter bullLeverageRouter;
    }

    function run() external returns (DeployedContracts memory deployed) {
        require(block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID, "wrong chain");

        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Continuing full Plether package deployment on Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("Existing CurvePool:", CURVE_POOL);

        vm.startBroadcast(privateKey);

        uint256 bearPrice6 = ArbitrumSepoliaTestnetCurvePool(CURVE_POOL).bearPrice6();
        uint256 usdcLiquidity = (CURVE_BEAR_LIQUIDITY * bearPrice6) / 1e18;

        IERC20(USDC).approve(CURVE_POOL, usdcLiquidity);
        IERC20(PLDXY_BEAR).approve(CURVE_POOL, CURVE_BEAR_LIQUIDITY);
        ArbitrumSepoliaTestnetCurvePool(CURVE_POOL).add_liquidity([usdcLiquidity, CURVE_BEAR_LIQUIDITY], 0);
        BasketOracle(BASKET_ORACLE).setCurvePool(CURVE_POOL);

        deployed.curvePool = CURVE_POOL;
        deployed.morpho = _deployMorpho(deployer);
        deployed.irm = new ArbitrumSepoliaZeroRateIrm();
        IMorphoOwner(deployed.morpho).enableIrm(address(deployed.irm));
        IMorphoOwner(deployed.morpho).enableLltv(LLTV);

        deployed.morphoOracleBear = new MorphoOracle(BASKET_ORACLE, CAP, false);
        deployed.morphoOracleBull = new MorphoOracle(BASKET_ORACLE, CAP, true);
        deployed.stakedOracleBear = new StakedOracle(STAKED_BEAR, address(deployed.morphoOracleBear));
        deployed.stakedOracleBull = new StakedOracle(STAKED_BULL, address(deployed.morphoOracleBull));

        MarketParams memory bearMarket = MarketParams({
            loanToken: USDC,
            collateralToken: STAKED_BEAR,
            oracle: address(deployed.stakedOracleBear),
            irm: address(deployed.irm),
            lltv: LLTV
        });
        MarketParams memory bullMarket = MarketParams({
            loanToken: USDC,
            collateralToken: STAKED_BULL,
            oracle: address(deployed.stakedOracleBull),
            irm: address(deployed.irm),
            lltv: LLTV
        });

        IMorpho(deployed.morpho).createMarket(bearMarket);
        IMorpho(deployed.morpho).createMarket(bullMarket);
        deployed.morphoMarketBear = keccak256(abi.encode(bearMarket));
        deployed.morphoMarketBull = keccak256(abi.encode(bullMarket));

        IMintableERC20(USDC).mint(deployer, MORPHO_LIQUIDITY * 2);
        IERC20(USDC).approve(deployed.morpho, MORPHO_LIQUIDITY * 2);
        IMorpho(deployed.morpho).supply(bearMarket, MORPHO_LIQUIDITY, 0, deployer, "");
        IMorpho(deployed.morpho).supply(bullMarket, MORPHO_LIQUIDITY, 0, deployer, "");

        deployed.zapRouter = new ZapRouter(SPLITTER, PLDXY_BEAR, PLDXY_BULL, USDC, CURVE_POOL);
        deployed.leverageRouter =
            new LeverageRouter(deployed.morpho, CURVE_POOL, USDC, PLDXY_BEAR, STAKED_BEAR, bearMarket);
        deployed.bullLeverageRouter = new BullLeverageRouter(
            deployed.morpho,
            SPLITTER,
            CURVE_POOL,
            USDC,
            PLDXY_BEAR,
            PLDXY_BULL,
            STAKED_BULL,
            bullMarket,
            address(0)
        );

        vm.stopBroadcast();

        _logDeployment(deployed, usdcLiquidity);
        return deployed;
    }

    function _deployMorpho(
        address owner
    ) internal returns (address morpho) {
        bytes memory morphoInitCode = vm.readFileBinary("script/bytecode/Morpho.bin");
        bytes memory morphoCreationCode = abi.encodePacked(morphoInitCode, abi.encode(owner));

        assembly {
            morpho := create(0, add(morphoCreationCode, 0x20), mload(morphoCreationCode))
        }
        require(morpho != address(0), "Morpho deployment failed");
    }

    function _logDeployment(
        DeployedContracts memory d,
        uint256 usdcLiquidity
    ) internal pure {
        console.log("========================================");
        console.log("FULL ARBITRUM SEPOLIA CONTINUATION COMPLETE");
        console.log("========================================");
        console.log("CurvePool:", d.curvePool);
        console.log("CurvePool USDC liquidity:", usdcLiquidity);
        console.log("CurvePool BEAR liquidity:", CURVE_BEAR_LIQUIDITY);
        console.log("Morpho:", d.morpho);
        console.log("ZeroRateIrm:", address(d.irm));
        console.log("MorphoOracleBear:", address(d.morphoOracleBear));
        console.log("MorphoOracleBull:", address(d.morphoOracleBull));
        console.log("StakedOracleBear:", address(d.stakedOracleBear));
        console.log("StakedOracleBull:", address(d.stakedOracleBull));
        console.log("MorphoMarketBear:");
        console.logBytes32(d.morphoMarketBear);
        console.log("MorphoMarketBull:");
        console.logBytes32(d.morphoMarketBull);
        console.log("ZapRouter:", address(d.zapRouter));
        console.log("LeverageRouter:", address(d.leverageRouter));
        console.log("BullLeverageRouter:", address(d.bullLeverageRouter));
        console.log("========================================");
    }

}
