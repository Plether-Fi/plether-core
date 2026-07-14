// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICurvePool} from "@plether/shared/interfaces/ICurvePool.sol";
import {IMorpho, MarketParams} from "@plether/shared/interfaces/IMorpho.sol";
import {SyntheticSplitter} from "@plether/spot/core/SyntheticSplitter.sol";
import {BasketOracle} from "@plether/spot/oracles/BasketOracle.sol";
import {MorphoOracle} from "@plether/spot/oracles/MorphoOracle.sol";
import {StakedOracle} from "@plether/spot/oracles/StakedOracle.sol";
import {BullLeverageRouter} from "@plether/spot/routers/BullLeverageRouter.sol";
import {LeverageRouter} from "@plether/spot/routers/LeverageRouter.sol";
import {ZapRouter} from "@plether/spot/routers/ZapRouter.sol";
import {StakedToken} from "@plether/spot/staking/StakedToken.sol";
import "forge-std/Script.sol";

interface IMintableERC20 is IERC20 {

    function mint(
        address to,
        uint256 amount
    ) external;

}

interface IMorphoOwner {

    function enableIrm(
        address irm
    ) external;

    function enableLltv(
        uint256 lltv
    ) external;

}

contract ArbitrumSepoliaZeroRateIrm {

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

/// @notice Reserve-backed testnet pool with the Curve interface used by Plether routers.
contract ArbitrumSepoliaTestnetCurvePool is ICurvePool {

    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    IERC20 public immutable PLDXY_BEAR;
    address public immutable owner;

    uint256 public bearPrice6;

    constructor(
        address usdc,
        address plDxyBear,
        uint256 initialBearPrice6
    ) {
        require(usdc != address(0), "USDC zero");
        require(plDxyBear != address(0), "BEAR zero");
        require(initialBearPrice6 != 0, "price zero");

        USDC = IERC20(usdc);
        PLDXY_BEAR = IERC20(plDxyBear);
        owner = msg.sender;
        bearPrice6 = initialBearPrice6;
    }

    function setPrice(
        uint256 newBearPrice6
    ) external {
        require(msg.sender == owner, "not owner");
        require(newBearPrice6 != 0, "price zero");
        bearPrice6 = newBearPrice6;
    }

    function add_liquidity(
        uint256[2] memory amounts,
        uint256
    ) external returns (uint256 minted) {
        if (amounts[0] > 0) {
            USDC.safeTransferFrom(msg.sender, address(this), amounts[0]);
        }
        if (amounts[1] > 0) {
            PLDXY_BEAR.safeTransferFrom(msg.sender, address(this), amounts[1]);
        }
        return amounts[0] + (amounts[1] * bearPrice6) / 1e18;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256) {
        if (i == 0 && j == 1) {
            return (dx * 1e18) / bearPrice6;
        }
        if (i == 1 && j == 0) {
            return (dx * bearPrice6) / 1e18;
        }
        return 0;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "insufficient output");

        if (i == 0 && j == 1) {
            USDC.safeTransferFrom(msg.sender, address(this), dx);
            PLDXY_BEAR.safeTransfer(msg.sender, dy);
            return dy;
        }

        if (i == 1 && j == 0) {
            PLDXY_BEAR.safeTransferFrom(msg.sender, address(this), dx);
            USDC.safeTransfer(msg.sender, dy);
            return dy;
        }

        revert("invalid pair");
    }

    function price_oracle() external view returns (uint256) {
        return bearPrice6 * 1e12;
    }

}

/// @title DeployFullArbitrumSepolia
/// @notice Continuation deploy for the full spot trading/lending package on top of the spot deployment.
contract DeployFullArbitrumSepolia is Script {

    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    uint256 internal constant LLTV = 0.915e18;
    uint256 internal constant CAP = 2e8;
    uint256 internal constant DEFAULT_CURVE_BEAR_LIQUIDITY = 800_000e18;
    uint256 internal constant DEFAULT_MORPHO_LIQUIDITY = 100_000e6;

    address internal constant DEFAULT_USDC = 0xf1e1B188b87525C51ECe4bae8627ae621D769651;
    address internal constant DEFAULT_SPLITTER = 0xebefb54a70391ACac074fA68d7929C4a7Ea5f77c;
    address internal constant DEFAULT_PLDXY_BEAR = 0x37838d96F93B815e7a9AcF76bB94e93ED3C114F5;
    address internal constant DEFAULT_PLDXY_BULL = 0x4c96B49e0a140885Ee7eC174adD7f66e53fa5E89;
    address internal constant DEFAULT_STAKED_BEAR = 0x1Ea462561cCbFc8C0C7D5B5F4618573001AB30D9;
    address internal constant DEFAULT_STAKED_BULL = 0x6B0CeE16329Ac833b512450fe536Db92AfB0A20A;
    address internal constant DEFAULT_BASKET_ORACLE = 0x2c448B9c7be8244D7F44Ca8D3B81bd6Fb1F7FCa5;

    struct DeployedContracts {
        ArbitrumSepoliaTestnetCurvePool curvePool;
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

        address usdc = vm.envOr("SPOT_USDC", DEFAULT_USDC);
        address splitter = vm.envOr("SPOT_SPLITTER", DEFAULT_SPLITTER);
        address plDxyBear = vm.envOr("SPOT_BEAR", DEFAULT_PLDXY_BEAR);
        address plDxyBull = vm.envOr("SPOT_BULL", DEFAULT_PLDXY_BULL);
        address stakedBear = vm.envOr("SPOT_STAKED_BEAR", DEFAULT_STAKED_BEAR);
        address stakedBull = vm.envOr("SPOT_STAKED_BULL", DEFAULT_STAKED_BULL);
        address basketOracle = vm.envOr("SPOT_BASKET_ORACLE", DEFAULT_BASKET_ORACLE);
        uint256 curveBearLiquidity = vm.envOr("FULL_CURVE_BEAR_LIQUIDITY", DEFAULT_CURVE_BEAR_LIQUIDITY);
        uint256 morphoLiquidity = vm.envOr("FULL_MORPHO_LIQUIDITY", DEFAULT_MORPHO_LIQUIDITY);

        console.log("Deploying full Plether package to Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("USDC:", usdc);
        console.log("Splitter:", splitter);
        console.log("plDXY-BEAR:", plDxyBear);
        console.log("plDXY-BULL:", plDxyBull);
        console.log("Staked BEAR:", stakedBear);
        console.log("Staked BULL:", stakedBull);
        console.log("BasketOracle:", basketOracle);
        console.log("");

        vm.startBroadcast(privateKey);

        (, int256 answer,,,) = BasketOracle(basketOracle).latestRoundData();
        require(answer > 0, "invalid basket price");
        uint256 bearPrice6 = uint256(answer) / 100;

        deployed.curvePool = new ArbitrumSepoliaTestnetCurvePool(usdc, plDxyBear, bearPrice6);
        _seedCurvePool(usdc, splitter, plDxyBear, address(deployed.curvePool), deployer, curveBearLiquidity, bearPrice6);

        require(address(BasketOracle(basketOracle).curvePool()) == address(0), "curve pool already set");
        BasketOracle(basketOracle).setCurvePool(address(deployed.curvePool));

        deployed.morpho = _deployMorpho(deployer);
        deployed.irm = new ArbitrumSepoliaZeroRateIrm();
        IMorphoOwner(deployed.morpho).enableIrm(address(deployed.irm));
        IMorphoOwner(deployed.morpho).enableLltv(LLTV);

        deployed.morphoOracleBear = new MorphoOracle(basketOracle, CAP, false);
        deployed.morphoOracleBull = new MorphoOracle(basketOracle, CAP, true);
        deployed.stakedOracleBear = new StakedOracle(stakedBear, address(deployed.morphoOracleBear));
        deployed.stakedOracleBull = new StakedOracle(stakedBull, address(deployed.morphoOracleBull));

        MarketParams memory bearMarket = MarketParams({
            loanToken: usdc,
            collateralToken: stakedBear,
            oracle: address(deployed.stakedOracleBear),
            irm: address(deployed.irm),
            lltv: LLTV
        });
        MarketParams memory bullMarket = MarketParams({
            loanToken: usdc,
            collateralToken: stakedBull,
            oracle: address(deployed.stakedOracleBull),
            irm: address(deployed.irm),
            lltv: LLTV
        });

        IMorpho(deployed.morpho).createMarket(bearMarket);
        IMorpho(deployed.morpho).createMarket(bullMarket);
        deployed.morphoMarketBear = keccak256(abi.encode(bearMarket));
        deployed.morphoMarketBull = keccak256(abi.encode(bullMarket));
        _seedMorphoMarkets(usdc, deployed.morpho, deployer, bearMarket, bullMarket, morphoLiquidity);

        deployed.zapRouter = new ZapRouter(splitter, plDxyBear, plDxyBull, usdc, address(deployed.curvePool));
        deployed.leverageRouter =
            new LeverageRouter(deployed.morpho, address(deployed.curvePool), usdc, plDxyBear, stakedBear, bearMarket);
        deployed.bullLeverageRouter = new BullLeverageRouter(
            deployed.morpho,
            splitter,
            address(deployed.curvePool),
            usdc,
            plDxyBear,
            plDxyBull,
            stakedBull,
            bullMarket,
            address(0)
        );

        vm.stopBroadcast();

        _logDeployment(deployed, bearPrice6, curveBearLiquidity, morphoLiquidity);
        return deployed;
    }

    function _seedCurvePool(
        address usdc,
        address splitter,
        address plDxyBear,
        address curvePool,
        address deployer,
        uint256 bearLiquidity,
        uint256 bearPrice6
    ) internal {
        uint256 usdcLiquidity = (bearLiquidity * bearPrice6) / 1e18;
        (uint256 mintCost,,) = SyntheticSplitter(splitter).previewMint(bearLiquidity);

        IMintableERC20(usdc).mint(deployer, usdcLiquidity + mintCost);
        IERC20(usdc).approve(splitter, mintCost);
        SyntheticSplitter(splitter).mint(bearLiquidity);

        IERC20(usdc).approve(curvePool, usdcLiquidity);
        IERC20(plDxyBear).approve(curvePool, bearLiquidity);
        ArbitrumSepoliaTestnetCurvePool(curvePool).add_liquidity([usdcLiquidity, bearLiquidity], 0);

        console.log("Curve pool seeded USDC:", usdcLiquidity);
        console.log("Curve pool seeded BEAR:", bearLiquidity);
    }

    function _seedMorphoMarkets(
        address usdc,
        address morpho,
        address deployer,
        MarketParams memory bearMarket,
        MarketParams memory bullMarket,
        uint256 morphoLiquidity
    ) internal {
        IMintableERC20(usdc).mint(deployer, morphoLiquidity * 2);
        IERC20(usdc).approve(morpho, morphoLiquidity * 2);
        IMorpho(morpho).supply(bearMarket, morphoLiquidity, 0, deployer, "");
        IMorpho(morpho).supply(bullMarket, morphoLiquidity, 0, deployer, "");

        console.log("Morpho BEAR market seeded USDC:", morphoLiquidity);
        console.log("Morpho BULL market seeded USDC:", morphoLiquidity);
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
        uint256 bearPrice6,
        uint256 curveBearLiquidity,
        uint256 morphoLiquidity
    ) internal pure {
        console.log("========================================");
        console.log("FULL ARBITRUM SEPOLIA DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("CurvePool:", address(d.curvePool));
        console.log("CurvePool bearPrice6:", bearPrice6);
        console.log("CurvePool BEAR liquidity:", curveBearLiquidity);
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
        console.log("Morpho market USDC liquidity each:", morphoLiquidity);
        console.log("ZapRouter:", address(d.zapRouter));
        console.log("LeverageRouter:", address(d.leverageRouter));
        console.log("BullLeverageRouter:", address(d.bullLeverageRouter));
        console.log("========================================");
    }

}
