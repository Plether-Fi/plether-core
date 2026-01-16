// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BullLeverageRouter} from "../../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../../src/LeverageRouter.sol";
import {MorphoAdapter} from "../../src/MorphoAdapter.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {SyntheticSplitter} from "../../src/SyntheticSplitter.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {LeverageRouterBase} from "../../src/base/LeverageRouterBase.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../../src/oracles/StakedOracle.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
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

    // WETH for yield market collateral (dummy collateral for USDC lending market)
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ==========================================
    // CURVE POOL PARAMETERS
    // Single source of truth for all fork tests
    // Optimized for low-volatility DXY pair
    // MAX_A for twocrypto-ng = N_COINS^2 * A_MULTIPLIER * 1000 = 40M
    // ==========================================
    uint256 constant CURVE_A = 20_000_000; // High amplification for tight concentration
    uint256 constant CURVE_GAMMA = 1_000_000_000_000_000; // 1e15
    uint256 constant CURVE_MID_FEE = 2_500_000; // 0.025% (1e10 = 100%)
    uint256 constant CURVE_OUT_FEE = 30_000_000; // 0.3% (1e10 = 100%)
    uint256 constant CURVE_ALLOWED_EXTRA_PROFIT = 2_000_000_000_000;
    uint256 constant CURVE_FEE_GAMMA = 1_000_000_000_000_000; // 1e15
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
    MorphoAdapter public yieldAdapter;
    MarketParams public yieldMarketParams;

    address public curvePool;
    address public bullToken;
    address public bearToken;

    uint256 public realOraclePrice;
    uint256 public bearPrice; // CAP - DXY, the fair value of DXY-BEAR

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

    /// @notice Fetch real oracle price and warp to valid timestamp
    function _fetchPriceAndWarp() internal {
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        // Normalized formula: (price * quantity) / (basePrice * 1e10)
        // With quantity=1e18: result in 8 decimals = price / basePrice (normalized)
        uint256 normalizedPrice8 = (uint256(price) * 1e18) / (BASE_EUR * 1e10);
        realOraclePrice = normalizedPrice8 * 1e10;
        bearPrice = CAP_SCALED - realOraclePrice;
        vm.warp(updatedAt + 1 hours);
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

        // Mock Pool for Oracle Init (using DXY-BEAR price = CAP - DXY)
        address tempCurvePool = address(new MockCurvePoolForOracle(bearPrice));
        basketOracle = new BasketOracle(feeds, qtys, basePrices, 200, 2e8, address(this));
        basketOracle.setCurvePool(tempCurvePool);

        // Create a Morpho yield market for the adapter (USDC lending market)
        // Use a simple mock oracle for the yield market (not critical since we're just supplying)
        address yieldMarketOracle = address(new MockMorphoOracleForYield());

        yieldMarketParams = MarketParams({
            loanToken: USDC, collateralToken: WETH, oracle: yieldMarketOracle, irm: ADAPTIVE_CURVE_IRM, lltv: LLTV_86
        });

        // Create the yield market on Morpho
        IMorpho(MORPHO).createMarket(yieldMarketParams);

        // Predict splitter address (deployed after yieldAdapter)
        uint64 currentNonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), currentNonce + 1);

        yieldAdapter = new MorphoAdapter(IERC20(USDC), MORPHO, yieldMarketParams, address(this), predictedSplitter);

        splitter = new SyntheticSplitter(address(basketOracle), USDC, address(yieldAdapter), 2e8, treasury, address(0));
        require(address(splitter) == predictedSplitter, "Splitter address mismatch");

        bullToken = address(splitter.TOKEN_B());
        bearToken = address(splitter.TOKEN_A());
    }

    /// @notice Deploy Curve pool with USDC/BEAR pair
    /// @param bearLiquidity Amount of BEAR to add as liquidity (18 decimals)
    function _deployCurvePool(
        uint256 bearLiquidity
    ) internal {
        address[2] memory coins = [USDC, bearToken];

        curvePool = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY)
            .deploy_pool(
                "USDC/Bear Pool",
                "USDC-BEAR",
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

        // Add Liquidity at bearPrice (USDC per DXY-BEAR)
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

/// @notice Mock Morpho oracle for yield market (returns ETH/USDC price in 36 decimals)
/// @dev Morpho oracles return price as: collateralToken/loanToken * 1e36
///      For WETH/USDC at ~$3000 ETH: 3000 * 1e6 * 1e36 / 1e18 = 3000e24
contract MockMorphoOracleForYield {

    function price() external pure returns (uint256) {
        // ETH price ~$3000 in terms of USDC (6 decimals)
        // Morpho expects: collateralPrice * 10^(36 + loanDecimals - collateralDecimals)
        // = 3000 * 10^(36 + 6 - 18) = 3000 * 10^24 = 3e27
        return 3000e24;
    }

}

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
