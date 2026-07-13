// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {ICurvePool} from "../src/interfaces/ICurvePool.sol";
import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../src/oracles/StakedOracle.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "forge-std/Script.sol";

interface IArbitrumSepoliaMintableERC20 is IERC20 {

    function mint(
        address to,
        uint256 amount
    ) external;

}

interface IArbitrumSepoliaMorphoOwner {

    function setOwner(
        address newOwner
    ) external;

    function enableIrm(
        address irm
    ) external;

    function enableLltv(
        uint256 lltv
    ) external;

}

contract ArbitrumSepoliaAtomicZeroRateIrm {

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
contract ArbitrumSepoliaAtomicCurvePool is ICurvePool {

    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    IERC20 public immutable PLDXY_BEAR;
    address public immutable owner;

    uint256 public bearPrice6;

    constructor(
        address usdc,
        address plDxyBear,
        address poolOwner,
        uint256 initialBearPrice6
    ) {
        require(usdc != address(0), "USDC zero");
        require(plDxyBear != address(0), "BEAR zero");
        require(poolOwner != address(0), "owner zero");
        require(initialBearPrice6 != 0, "price zero");

        USDC = IERC20(usdc);
        PLDXY_BEAR = IERC20(plDxyBear);
        owner = poolOwner;
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

contract ArbitrumSepoliaFullPackageCore {

    using SafeERC20 for IERC20;

    uint256 internal constant LLTV = 0.915e18;
    uint256 internal constant CAP = 2e8;

    address public immutable finalOwner;
    address public immutable usdc;
    address public immutable splitter;
    address public immutable plDxyBear;
    address public immutable plDxyBull;
    address public immutable stakedBear;
    address public immutable stakedBull;
    address public immutable basketOracle;

    ArbitrumSepoliaAtomicCurvePool public immutable curvePool;
    address public immutable morpho;
    ArbitrumSepoliaAtomicZeroRateIrm public immutable irm;
    MorphoOracle public immutable morphoOracleBear;
    MorphoOracle public immutable morphoOracleBull;
    StakedOracle public immutable stakedOracleBear;
    StakedOracle public immutable stakedOracleBull;
    bytes32 public immutable morphoMarketBear;
    bytes32 public immutable morphoMarketBull;

    constructor(
        address owner_,
        address usdc_,
        address splitter_,
        address plDxyBear_,
        address plDxyBull_,
        address stakedBear_,
        address stakedBull_,
        address basketOracle_,
        uint256 curveBearLiquidity,
        uint256 morphoLiquidity,
        bytes memory morphoInitCode
    ) {
        require(owner_ != address(0), "owner zero");
        require(morphoInitCode.length != 0, "morpho code empty");

        finalOwner = owner_;
        usdc = usdc_;
        splitter = splitter_;
        plDxyBear = plDxyBear_;
        plDxyBull = plDxyBull_;
        stakedBear = stakedBear_;
        stakedBull = stakedBull_;
        basketOracle = basketOracle_;

        (, int256 answer,,,) = BasketOracle(basketOracle_).latestRoundData();
        require(answer > 0, "invalid basket price");
        uint256 bearPrice6 = uint256(answer) / 100;

        curvePool = new ArbitrumSepoliaAtomicCurvePool(usdc_, plDxyBear_, owner_, bearPrice6);
        _seedCurvePool(curveBearLiquidity, bearPrice6);

        morpho = _deployMorpho(morphoInitCode);
        irm = new ArbitrumSepoliaAtomicZeroRateIrm();
        IArbitrumSepoliaMorphoOwner(morpho).enableIrm(address(irm));
        IArbitrumSepoliaMorphoOwner(morpho).enableLltv(LLTV);

        morphoOracleBear = new MorphoOracle(basketOracle_, CAP, false);
        morphoOracleBull = new MorphoOracle(basketOracle_, CAP, true);
        stakedOracleBear = new StakedOracle(stakedBear_, address(morphoOracleBear));
        stakedOracleBull = new StakedOracle(stakedBull_, address(morphoOracleBull));

        MarketParams memory bearMarket = MarketParams({
            loanToken: usdc_,
            collateralToken: stakedBear_,
            oracle: address(stakedOracleBear),
            irm: address(irm),
            lltv: LLTV
        });
        MarketParams memory bullMarket = MarketParams({
            loanToken: usdc_,
            collateralToken: stakedBull_,
            oracle: address(stakedOracleBull),
            irm: address(irm),
            lltv: LLTV
        });

        IMorpho(morpho).createMarket(bearMarket);
        IMorpho(morpho).createMarket(bullMarket);
        morphoMarketBear = keccak256(abi.encode(bearMarket));
        morphoMarketBull = keccak256(abi.encode(bullMarket));
        _seedMorphoMarkets(bearMarket, bullMarket, morphoLiquidity);
        IArbitrumSepoliaMorphoOwner(morpho).setOwner(owner_);
    }

    function _seedCurvePool(
        uint256 bearLiquidity,
        uint256 bearPrice6
    ) internal {
        uint256 usdcLiquidity = (bearLiquidity * bearPrice6) / 1e18;
        (uint256 mintCost,,) = SyntheticSplitter(splitter).previewMint(bearLiquidity);

        IArbitrumSepoliaMintableERC20(usdc).mint(address(this), usdcLiquidity + mintCost);
        IERC20(usdc).forceApprove(splitter, mintCost);
        SyntheticSplitter(splitter).mint(bearLiquidity);

        IERC20(usdc).forceApprove(address(curvePool), usdcLiquidity);
        IERC20(plDxyBear).forceApprove(address(curvePool), bearLiquidity);
        curvePool.add_liquidity([usdcLiquidity, bearLiquidity], 0);
        IERC20(plDxyBull).safeTransfer(finalOwner, bearLiquidity);
    }

    function _seedMorphoMarkets(
        MarketParams memory bearMarket,
        MarketParams memory bullMarket,
        uint256 morphoLiquidity
    ) internal {
        IArbitrumSepoliaMintableERC20(usdc).mint(address(this), morphoLiquidity * 2);
        IERC20(usdc).forceApprove(morpho, morphoLiquidity * 2);
        IMorpho(morpho).supply(bearMarket, morphoLiquidity, 0, finalOwner, "");
        IMorpho(morpho).supply(bullMarket, morphoLiquidity, 0, finalOwner, "");
    }

    function _deployMorpho(
        bytes memory morphoInitCode
    ) internal returns (address deployedMorpho) {
        bytes memory morphoCreationCode = abi.encodePacked(morphoInitCode, abi.encode(address(this)));

        assembly {
            deployedMorpho := create(0, add(morphoCreationCode, 0x20), mload(morphoCreationCode))
        }
        require(deployedMorpho != address(0), "Morpho deployment failed");
    }

}

contract DeployFullArbitrumSepoliaAtomic is Script {

    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    uint256 internal constant DEFAULT_CURVE_BEAR_LIQUIDITY = 800_000e18;
    uint256 internal constant DEFAULT_MORPHO_LIQUIDITY = 100_000e6;

    address internal constant DEFAULT_USDC = 0xf1e1B188b87525C51ECe4bae8627ae621D769651;
    address internal constant DEFAULT_SPLITTER = 0xebefb54a70391ACac074fA68d7929C4a7Ea5f77c;
    address internal constant DEFAULT_PLDXY_BEAR = 0x37838d96F93B815e7a9AcF76bB94e93ED3C114F5;
    address internal constant DEFAULT_PLDXY_BULL = 0x4c96B49e0a140885Ee7eC174adD7f66e53fa5E89;
    address internal constant DEFAULT_STAKED_BEAR = 0x1Ea462561cCbFc8C0C7D5B5F4618573001AB30D9;
    address internal constant DEFAULT_STAKED_BULL = 0x6B0CeE16329Ac833b512450fe536Db92AfB0A20A;
    address internal constant DEFAULT_BASKET_ORACLE = 0x2c448B9c7be8244D7F44Ca8D3B81bd6Fb1F7FCa5;

    function run() external returns (ArbitrumSepoliaFullPackageCore deployed) {
        require(block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID, "wrong chain");

        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address owner = vm.addr(privateKey);

        bytes memory morphoInitCode = vm.readFileBinary("script/bytecode/Morpho.bin");

        vm.startBroadcast(privateKey);
        deployed = new ArbitrumSepoliaFullPackageCore(
            owner,
            vm.envOr("SPOT_USDC", DEFAULT_USDC),
            vm.envOr("SPOT_SPLITTER", DEFAULT_SPLITTER),
            vm.envOr("SPOT_BEAR", DEFAULT_PLDXY_BEAR),
            vm.envOr("SPOT_BULL", DEFAULT_PLDXY_BULL),
            vm.envOr("SPOT_STAKED_BEAR", DEFAULT_STAKED_BEAR),
            vm.envOr("SPOT_STAKED_BULL", DEFAULT_STAKED_BULL),
            vm.envOr("SPOT_BASKET_ORACLE", DEFAULT_BASKET_ORACLE),
            vm.envOr("FULL_CURVE_BEAR_LIQUIDITY", DEFAULT_CURVE_BEAR_LIQUIDITY),
            vm.envOr("FULL_MORPHO_LIQUIDITY", DEFAULT_MORPHO_LIQUIDITY),
            morphoInitCode
        );
        vm.stopBroadcast();

        console.log("FullPackageCore:", address(deployed));
        console.log("CurvePool:", address(deployed.curvePool()));
        console.log("Morpho:", deployed.morpho());
        console.log("ZeroRateIrm:", address(deployed.irm()));
        console.log("MorphoOracleBear:", address(deployed.morphoOracleBear()));
        console.log("MorphoOracleBull:", address(deployed.morphoOracleBull()));
        console.log("StakedOracleBear:", address(deployed.stakedOracleBear()));
        console.log("StakedOracleBull:", address(deployed.stakedOracleBull()));
        console.log("MorphoMarketBear:");
        console.logBytes32(deployed.morphoMarketBear());
        console.log("MorphoMarketBull:");
        console.logBytes32(deployed.morphoMarketBull());
    }

}

contract SetArbitrumSepoliaCurvePool is Script {

    function run() external {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address basketOracle = vm.envAddress("SPOT_BASKET_ORACLE");
        address curvePool = vm.envAddress("FULL_CURVE_POOL");

        vm.startBroadcast(privateKey);
        BasketOracle(basketOracle).setCurvePool(curvePool);
        vm.stopBroadcast();
    }

}

contract DeployArbitrumSepoliaZapRouter is Script {

    function run() external returns (ZapRouter router) {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        router = new ZapRouter(
            vm.envAddress("SPOT_SPLITTER"),
            vm.envAddress("SPOT_BEAR"),
            vm.envAddress("SPOT_BULL"),
            vm.envAddress("SPOT_USDC"),
            vm.envAddress("FULL_CURVE_POOL")
        );
        vm.stopBroadcast();

        console.log("ZapRouter:", address(router));
    }

}

contract DeployArbitrumSepoliaLeverageRouter is Script {

    uint256 internal constant LLTV = 0.915e18;

    function run() external returns (LeverageRouter router) {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        MarketParams memory bearMarket = MarketParams({
            loanToken: vm.envAddress("SPOT_USDC"),
            collateralToken: vm.envAddress("SPOT_STAKED_BEAR"),
            oracle: vm.envAddress("FULL_STAKED_ORACLE_BEAR"),
            irm: vm.envAddress("FULL_IRM"),
            lltv: LLTV
        });

        vm.startBroadcast(privateKey);
        router = new LeverageRouter(
            vm.envAddress("FULL_MORPHO"),
            vm.envAddress("FULL_CURVE_POOL"),
            vm.envAddress("SPOT_USDC"),
            vm.envAddress("SPOT_BEAR"),
            vm.envAddress("SPOT_STAKED_BEAR"),
            bearMarket
        );
        vm.stopBroadcast();

        console.log("LeverageRouter:", address(router));
    }

}

contract DeployArbitrumSepoliaBullLeverageRouter is Script {

    uint256 internal constant LLTV = 0.915e18;

    function run() external returns (BullLeverageRouter router) {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        MarketParams memory bullMarket = MarketParams({
            loanToken: vm.envAddress("SPOT_USDC"),
            collateralToken: vm.envAddress("SPOT_STAKED_BULL"),
            oracle: vm.envAddress("FULL_STAKED_ORACLE_BULL"),
            irm: vm.envAddress("FULL_IRM"),
            lltv: LLTV
        });

        vm.startBroadcast(privateKey);
        router = new BullLeverageRouter(
            vm.envAddress("FULL_MORPHO"),
            vm.envAddress("SPOT_SPLITTER"),
            vm.envAddress("FULL_CURVE_POOL"),
            vm.envAddress("SPOT_USDC"),
            vm.envAddress("SPOT_BEAR"),
            vm.envAddress("SPOT_BULL"),
            vm.envAddress("SPOT_STAKED_BULL"),
            bullMarket,
            address(0)
        );
        vm.stopBroadcast();

        console.log("BullLeverageRouter:", address(router));
    }

}
