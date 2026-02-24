// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BullLeverageRouter} from "../../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../../src/LeverageRouter.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {SyntheticSplitter} from "../../src/SyntheticSplitter.sol";
import {VaultAdapter} from "../../src/VaultAdapter.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {LeverageRouterBase} from "../../src/base/LeverageRouterBase.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../../src/oracles/StakedOracle.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

// --------------------------------------------------------
// INTERFACES (For Mainnet Interaction)
// --------------------------------------------------------
interface ICurveCryptoFactory {

    function deploy_pool(
        string memory _name,
        string memory _symbol,
        address[2] memory _coins,
        uint256 implementation_id,
        uint256 A,
        uint256 gamma,
        uint256 mid_fee,
        uint256 out_fee,
        uint256 fee_gamma,
        uint256 allowed_extra_profit,
        uint256 adjustment_step,
        uint256 ma_exp_time,
        uint256 initial_price
    ) external returns (address);

    function deploy_gauge(
        address pool
    ) external returns (address);

}

interface ICurvePoolExtended {

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);
    function price_oracle() external view returns (uint256);

}

// ============================================================
// BASE FORK TEST
// Abstract contract with shared setup logic for all fork tests
// ============================================================

abstract contract BaseForkTest is Test {

    // ==========================================
    // MAINNET CONSTANTS
    // ==========================================
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE_CRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;
    address constant CL_EUR = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;
    uint256 constant FORK_BLOCK = 24_136_062;

    // ==========================================
    // MORPHO BLUE MAINNET CONSTANTS
    // ==========================================
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    // Common enabled LLTVs on Morpho Blue
    uint256 constant LLTV_86 = 860_000_000_000_000_000; // 86%
    uint256 constant LLTV_945 = 945_000_000_000_000_000; // 94.5%

    // WETH for leverage market collateral
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Morpho vault for yield
    IERC4626 constant STEAKHOUSE_USDC = IERC4626(0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB);

    // ==========================================
    // CURVE POOL PARAMETERS
    // Curve Pool Parameters — must match DeployToMainnet.s.sol
    uint256 constant CURVE_A = 320_000;
    uint256 constant CURVE_GAMMA = 2_000_000_000_000_000; // 2e15 (0.002)
    uint256 constant CURVE_MID_FEE = 4_000_000; // 0.04%
    uint256 constant CURVE_OUT_FEE = 20_000_000; // 0.2%
    uint256 constant CURVE_FEE_GAMMA = 1_000_000_000_000_000; // 1e15
    uint256 constant CURVE_ALLOWED_EXTRA_PROFIT = 2_000_000_000_000;
    uint256 constant CURVE_ADJUSTMENT_STEP = 146_000_000_000_000;
    uint256 constant CURVE_MA_HALF_TIME = 600;

    // CAP scaled to 18 decimals for Curve price calculations
    // CAP = 2e8 (8 decimals) -> 2e18 (18 decimals)
    uint256 constant CAP_SCALED = 2e18;

    // Base price for EUR normalization (8 decimals)
    uint256 constant BASE_EUR = 108_000_000;

    // ==========================================
    // PROTOCOL STATE
    // ==========================================
    SyntheticSplitter public splitter;
    BasketOracle public basketOracle;
    VaultAdapter public yieldAdapter;

    address public curvePool;
    address public bullToken;
    address public bearToken;

    uint256 public realOraclePrice;
    uint256 public bearPrice; // basket price (BEAR tracks basket directly)

    // ==========================================
    // SETUP HELPERS
    // ==========================================

    /// @notice Setup the mainnet fork
    function _setupFork() internal {
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url, FORK_BLOCK);
        } catch {
            revert("Missing MAINNET_RPC_URL in .env");
        }
    }

    /// @notice Fetch real oracle price and warp to valid timestamp (never backward)
    function _fetchPriceAndWarp() internal {
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        uint256 normalizedPrice8 = (uint256(price) * 1e18) / (BASE_EUR * 1e10);
        realOraclePrice = normalizedPrice8 * 1e10;
        bearPrice = realOraclePrice;
        uint256 target = updatedAt + 1 hours;
        if (target < block.timestamp) {
            target = block.timestamp;
        }
        vm.warp(target);
    }

    /// @notice Deploy core protocol (adapter, oracle, splitter)
    /// @param treasury Address to receive yield
    function _deployProtocol(
        address treasury
    ) internal {
        address[] memory feeds = new address[](1);
        feeds[0] = CL_EUR;
        uint256[] memory qtys = new uint256[](1);
        qtys[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;

        address tempCurvePool = address(new MockCurvePoolForOracle(bearPrice));
        basketOracle = new BasketOracle(feeds, qtys, basePrices, 200, address(this));
        basketOracle.setCurvePool(tempCurvePool);

        uint64 currentNonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), currentNonce + 1);

        yieldAdapter = new VaultAdapter(IERC20(USDC), address(STEAKHOUSE_USDC), address(this), predictedSplitter);

        splitter = new SyntheticSplitter(address(basketOracle), USDC, address(yieldAdapter), 2e8, treasury, address(0));
        require(address(splitter) == predictedSplitter, "Splitter address mismatch");

        bullToken = address(splitter.BULL());
        bearToken = address(splitter.BEAR());
    }

    /// @notice Deploy Curve pool with USDC/BEAR pair
    /// @param bearLiquidity Amount of BEAR to add as liquidity (18 decimals)
    function _deployCurvePool(
        uint256 bearLiquidity
    ) internal {
        address[2] memory coins = [USDC, bearToken];

        curvePool = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY)
            .deploy_pool(
                "USDC/plDXY-BEAR Pool",
                "USDC-plDXY-BEAR",
                coins,
                0,
                CURVE_A,
                CURVE_GAMMA,
                CURVE_MID_FEE,
                CURVE_OUT_FEE,
                CURVE_FEE_GAMMA,
                CURVE_ALLOWED_EXTRA_PROFIT,
                CURVE_ADJUSTMENT_STEP,
                CURVE_MA_HALF_TIME,
                bearPrice
            );

        require(curvePool != address(0), "Pool Deployment Failed");

        // Add Liquidity at bearPrice (USDC per plDXY-BEAR)
        IERC20(USDC).approve(curvePool, type(uint256).max);
        IERC20(bearToken).approve(curvePool, type(uint256).max);

        uint256 usdcAmount = (bearLiquidity * bearPrice) / 1e18 / 1e12;
        uint256[2] memory amounts = [usdcAmount, bearLiquidity];

        (bool success,) = curvePool.call(abi.encodeWithSignature("add_liquidity(uint256[2],uint256)", amounts, 0));
        require(success, "Liquidity Add Failed");
    }

    /// @notice Mint initial token pairs
    /// @param amount Amount of token pairs to mint (18 decimals)
    function _mintInitialTokens(
        uint256 amount
    ) internal {
        (uint256 usdcRequired,,) = splitter.previewMint(amount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(amount);
    }

    /// @notice Create a Morpho market and supply liquidity
    /// @param collateralToken The collateral token (staked token)
    /// @param oracle The price oracle for the collateral
    /// @param liquidityAmount Amount of USDC to supply as liquidity
    /// @return params The market params for the created market
    function _createMorphoMarket(
        address collateralToken,
        address oracle,
        uint256 liquidityAmount
    ) internal returns (MarketParams memory params) {
        params = MarketParams({
            loanToken: USDC, collateralToken: collateralToken, oracle: oracle, irm: ADAPTIVE_CURVE_IRM, lltv: LLTV_86
        });

        // Create the market
        IMorpho(MORPHO).createMarket(params);

        // Supply USDC liquidity so borrowers can borrow
        IERC20(USDC).approve(MORPHO, liquidityAmount);
        IMorpho(MORPHO).supply(params, liquidityAmount, 0, address(this), "");
    }

}

// ============================================================
// MOCK CONTRACTS FOR FORK TEST
// ============================================================

contract MockCurvePoolForOracle {

    uint256 public oraclePrice;

    constructor(
        uint256 _price
    ) {
        oraclePrice = _price;
    }

    function price_oracle() external view returns (uint256) {
        return oraclePrice;
    }

}
