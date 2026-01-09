// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {SyntheticSplitter} from "../../src/SyntheticSplitter.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {MorphoAdapter} from "../../src/MorphoAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MarketParams, IMorpho} from "../../src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICurveCryptoFactory} from "./BaseForkTest.sol";

/// @notice Mock SEK/USD feed (not available on mainnet Chainlink)
contract MockSEKFeed is AggregatorV3Interface {
    int256 private _price;
    uint256 private _updatedAt;

    constructor(int256 price_) {
        _price = price_;
        _updatedAt = block.timestamp;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "SEK / USD (Mock)";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }
}

/// @notice Mock Morpho oracle for yield market
contract MockMorphoOracleForYieldBasket {
    function price() external pure returns (uint256) {
        return 3000e24;
    }
}

/// @notice Mock Curve pool for oracle initialization
contract MockCurvePoolForOracleBasket {
    uint256 public oraclePrice;

    constructor(uint256 _price) {
        oraclePrice = _price;
    }

    function price_oracle() external view returns (uint256) {
        return oraclePrice;
    }
}

/// @title Full Basket Oracle Fork Tests
/// @notice Tests BasketOracle with real 6-feed DXY basket (5 real + 1 mock for SEK)
contract BasketOracleForkTest is Test {
    address constant CL_EUR_USD = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;
    address constant CL_JPY_USD = 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3;
    address constant CL_GBP_USD = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address constant CL_CAD_USD = 0xa34317DB73e77d453b1B8d04550c44D10e981C8e;
    address constant CL_CHF_USD = 0x449d117117838fFA61263B61dA6301AA2a88B13A;

    uint256 constant WEIGHT_EUR = 576 * 1e15;
    uint256 constant WEIGHT_JPY = 136 * 1e15;
    uint256 constant WEIGHT_GBP = 119 * 1e15;
    uint256 constant WEIGHT_CAD = 91 * 1e15;
    uint256 constant WEIGHT_SEK = 42 * 1e15;
    uint256 constant WEIGHT_CHF = 36 * 1e15;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE_CRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 24_136_062;

    uint256 constant CURVE_A = 2000000;
    uint256 constant CURVE_GAMMA = 50000000000000;
    uint256 constant CURVE_MID_FEE = 5000000;
    uint256 constant CURVE_OUT_FEE = 45000000;
    uint256 constant CURVE_ALLOWED_EXTRA_PROFIT = 2000000000000;
    uint256 constant CURVE_FEE_GAMMA = 230000000000000;
    uint256 constant CURVE_ADJUSTMENT_STEP = 146000000000000;
    uint256 constant CURVE_MA_HALF_TIME = 600;

    BasketOracle public basketOracle;
    MockSEKFeed public sekFeed;
    address public curvePool;

    SyntheticSplitter public splitter;
    MorphoAdapter public yieldAdapter;
    address public bearToken;
    address public bullToken;

    uint256 public calculatedBasketPrice;

    function setUp() public {
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url, FORK_BLOCK);
        } catch {
            revert("Missing MAINNET_RPC_URL");
        }

        deal(USDC, address(this), 5_000_000e6);

        (, int256 eurPrice,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR_USD).latestRoundData();
        vm.warp(updatedAt + 1 hours);

        int256 sekPrice = 9500000;
        sekFeed = new MockSEKFeed(sekPrice);

        calculatedBasketPrice = _calculateBasketPrice();

        address tempCurvePool = address(new MockCurvePoolForOracleBasket(calculatedBasketPrice * 1e10));

        address[] memory feeds = new address[](6);
        feeds[0] = CL_EUR_USD;
        feeds[1] = CL_JPY_USD;
        feeds[2] = CL_GBP_USD;
        feeds[3] = CL_CAD_USD;
        feeds[4] = address(sekFeed);
        feeds[5] = CL_CHF_USD;

        uint256[] memory quantities = new uint256[](6);
        quantities[0] = WEIGHT_EUR;
        quantities[1] = WEIGHT_JPY;
        quantities[2] = WEIGHT_GBP;
        quantities[3] = WEIGHT_CAD;
        quantities[4] = WEIGHT_SEK;
        quantities[5] = WEIGHT_CHF;

        basketOracle = new BasketOracle(feeds, quantities, 500, address(this));
        basketOracle.setCurvePool(tempCurvePool);
    }

    function _calculateBasketPrice() internal view returns (uint256) {
        uint256 sum = 0;

        (, int256 eur,,,) = AggregatorV3Interface(CL_EUR_USD).latestRoundData();
        (, int256 jpy,,,) = AggregatorV3Interface(CL_JPY_USD).latestRoundData();
        (, int256 gbp,,,) = AggregatorV3Interface(CL_GBP_USD).latestRoundData();
        (, int256 cad,,,) = AggregatorV3Interface(CL_CAD_USD).latestRoundData();
        (, int256 sek,,,) = sekFeed.latestRoundData();
        (, int256 chf,,,) = AggregatorV3Interface(CL_CHF_USD).latestRoundData();

        sum += uint256(eur) * WEIGHT_EUR / 1e18;
        sum += uint256(jpy) * WEIGHT_JPY / 1e18;
        sum += uint256(gbp) * WEIGHT_GBP / 1e18;
        sum += uint256(cad) * WEIGHT_CAD / 1e18;
        sum += uint256(sek) * WEIGHT_SEK / 1e18;
        sum += uint256(chf) * WEIGHT_CHF / 1e18;

        return sum;
    }

    function test_FullBasket_ReturnsWeightedSum() public view {
        (, int256 price,,,) = basketOracle.latestRoundData();

        assertGt(price, 0, "Price should be positive");
        assertEq(uint256(price), calculatedBasketPrice, "Should match calculated basket");
    }

    function test_FullBasket_WeightsSumTo100Percent() public pure {
        uint256 totalWeight = WEIGHT_EUR + WEIGHT_JPY + WEIGHT_GBP + WEIGHT_CAD + WEIGHT_SEK + WEIGHT_CHF;
        assertEq(totalWeight, 1e18, "Weights should sum to 100%");
    }

    function test_FullBasket_ComponentContributions() public view {
        (, int256 eur,,,) = AggregatorV3Interface(CL_EUR_USD).latestRoundData();
        uint256 eurContribution = uint256(eur) * WEIGHT_EUR / 1e18;

        (, int256 price,,,) = basketOracle.latestRoundData();

        uint256 eurPercentage = (eurContribution * 10000) / uint256(price);

        assertGt(eurPercentage, 5000, "EUR should contribute >50% to basket");
        assertLt(eurPercentage, 8000, "EUR should contribute <80% to basket");
    }

    function test_FullBasket_EURPriceImpact() public {
        (, int256 priceBefore,,,) = basketOracle.latestRoundData();

        int256 originalEur;
        (, originalEur,,,) = AggregatorV3Interface(CL_EUR_USD).latestRoundData();
        int256 newEur = (originalEur * 95) / 100;

        address[] memory feeds = new address[](6);
        feeds[0] = address(new MockSEKFeed(newEur));
        feeds[1] = CL_JPY_USD;
        feeds[2] = CL_GBP_USD;
        feeds[3] = CL_CAD_USD;
        feeds[4] = address(sekFeed);
        feeds[5] = CL_CHF_USD;

        uint256[] memory quantities = new uint256[](6);
        quantities[0] = WEIGHT_EUR;
        quantities[1] = WEIGHT_JPY;
        quantities[2] = WEIGHT_GBP;
        quantities[3] = WEIGHT_CAD;
        quantities[4] = WEIGHT_SEK;
        quantities[5] = WEIGHT_CHF;

        uint256 expectedPrice = calculatedBasketPrice * 1e10;
        address tempPool = address(new MockCurvePoolForOracleBasket(expectedPrice));

        BasketOracle newOracle = new BasketOracle(feeds, quantities, 500, address(this));
        newOracle.setCurvePool(tempPool);

        (, int256 priceAfter,,,) = newOracle.latestRoundData();

        uint256 impact = ((uint256(priceBefore) - uint256(priceAfter)) * 10000) / uint256(priceBefore);

        assertGt(impact, 200, "5% EUR drop should cause >2% basket impact");
        assertLt(impact, 400, "5% EUR drop should cause <4% basket impact");
    }

    function test_FullBasket_SEKPriceImpact() public {
        (, int256 priceBefore,,,) = basketOracle.latestRoundData();

        MockSEKFeed newSekFeed = new MockSEKFeed(8500000);

        address[] memory feeds = new address[](6);
        feeds[0] = CL_EUR_USD;
        feeds[1] = CL_JPY_USD;
        feeds[2] = CL_GBP_USD;
        feeds[3] = CL_CAD_USD;
        feeds[4] = address(newSekFeed);
        feeds[5] = CL_CHF_USD;

        uint256[] memory quantities = new uint256[](6);
        quantities[0] = WEIGHT_EUR;
        quantities[1] = WEIGHT_JPY;
        quantities[2] = WEIGHT_GBP;
        quantities[3] = WEIGHT_CAD;
        quantities[4] = WEIGHT_SEK;
        quantities[5] = WEIGHT_CHF;

        uint256 expectedPrice = calculatedBasketPrice * 1e10;
        address tempPool = address(new MockCurvePoolForOracleBasket(expectedPrice));

        BasketOracle newOracle = new BasketOracle(feeds, quantities, 500, address(this));
        newOracle.setCurvePool(tempPool);

        (, int256 priceAfter,,,) = newOracle.latestRoundData();

        uint256 impact = ((uint256(priceBefore) - uint256(priceAfter)) * 10000) / uint256(priceBefore);

        assertLt(impact, 100, "10% SEK drop should cause <1% basket impact (4.2% weight)");
    }

    function test_FullBasket_IntegrationWithSplitter() public {
        uint256 mintAmount = 1000e18;

        _deployProtocolWithBasket();

        uint256 bearBefore = IERC20(bearToken).balanceOf(address(this));
        uint256 bullBefore = IERC20(bullToken).balanceOf(address(this));

        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);

        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);

        uint256 bearAfter = IERC20(bearToken).balanceOf(address(this));
        uint256 bullAfter = IERC20(bullToken).balanceOf(address(this));

        assertEq(bearAfter - bearBefore, mintAmount, "Should receive BEAR delta");
        assertEq(bullAfter - bullBefore, mintAmount, "Should receive BULL delta");

        (, int256 oraclePrice,,,) = basketOracle.latestRoundData();
        assertEq(uint256(oraclePrice), calculatedBasketPrice, "Oracle should use all 6 feeds");
    }

    function test_FullBasket_DeviationCheckWithRealPool() public {
        uint256 initialPrice18 = calculatedBasketPrice * 1e10;
        curvePool = _deployCurvePool(initialPrice18);

        address[] memory feeds = new address[](6);
        feeds[0] = CL_EUR_USD;
        feeds[1] = CL_JPY_USD;
        feeds[2] = CL_GBP_USD;
        feeds[3] = CL_CAD_USD;
        feeds[4] = address(sekFeed);
        feeds[5] = CL_CHF_USD;

        uint256[] memory quantities = new uint256[](6);
        quantities[0] = WEIGHT_EUR;
        quantities[1] = WEIGHT_JPY;
        quantities[2] = WEIGHT_GBP;
        quantities[3] = WEIGHT_CAD;
        quantities[4] = WEIGHT_SEK;
        quantities[5] = WEIGHT_CHF;

        basketOracle = new BasketOracle(feeds, quantities, 200, address(this));
        basketOracle.setCurvePool(curvePool);

        (, int256 price,,,) = basketOracle.latestRoundData();
        assertGt(price, 0, "Should return valid price");
    }

    function test_FullBasket_UpdatedAtIsOldestFeed() public view {
        (,,, uint256 updatedAt,) = basketOracle.latestRoundData();

        uint256 oldestReal = type(uint256).max;
        address[5] memory realFeeds = [CL_EUR_USD, CL_JPY_USD, CL_GBP_USD, CL_CAD_USD, CL_CHF_USD];

        for (uint256 i = 0; i < realFeeds.length; i++) {
            (,,, uint256 feedUpdatedAt,) = AggregatorV3Interface(realFeeds[i]).latestRoundData();
            if (feedUpdatedAt < oldestReal) {
                oldestReal = feedUpdatedAt;
            }
        }

        (,,, uint256 sekUpdatedAt,) = sekFeed.latestRoundData();

        uint256 expectedOldest = oldestReal < sekUpdatedAt ? oldestReal : sekUpdatedAt;

        assertEq(updatedAt, expectedOldest, "Should use oldest updatedAt");
    }

    function _deployCurvePool(uint256 initialPrice) internal returns (address pool) {
        _deployProtocolWithBasket();

        address[2] memory coins = [USDC, bearToken];

        pool = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY)
            .deploy_pool(
                "USDC/BEAR Full Basket",
                "USDC-BEAR-FB",
                coins,
                0,
                CURVE_A,
                CURVE_GAMMA,
                CURVE_MID_FEE,
                CURVE_OUT_FEE,
                CURVE_ALLOWED_EXTRA_PROFIT,
                CURVE_FEE_GAMMA,
                CURVE_ADJUSTMENT_STEP,
                CURVE_MA_HALF_TIME,
                initialPrice
            );

        require(pool != address(0), "Pool deployment failed");

        uint256 bearLiquidity = 500_000e18;
        uint256 usdcAmount = (bearLiquidity * initialPrice) / 1e18 / 1e12;

        IERC20(USDC).approve(pool, type(uint256).max);
        IERC20(bearToken).approve(pool, type(uint256).max);

        uint256[2] memory amounts = [usdcAmount, bearLiquidity];
        (bool success,) = pool.call(abi.encodeWithSignature("add_liquidity(uint256[2],uint256)", amounts, 0));
        require(success, "Liquidity add failed");
    }

    function _deployProtocolWithBasket() internal {
        if (address(splitter) != address(0)) return;

        address yieldOracle = address(new MockMorphoOracleForYieldBasket());
        MarketParams memory yieldParams = MarketParams({
            loanToken: USDC,
            collateralToken: WETH,
            oracle: yieldOracle,
            irm: ADAPTIVE_CURVE_IRM,
            lltv: 860000000000000000
        });

        IMorpho(MORPHO).createMarket(yieldParams);

        uint64 nonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), nonce + 1);

        yieldAdapter = new MorphoAdapter(IERC20(USDC), MORPHO, yieldParams, address(this), predictedSplitter);
        splitter =
            new SyntheticSplitter(address(basketOracle), USDC, address(yieldAdapter), 2e8, address(this), address(0));

        require(address(splitter) == predictedSplitter, "Splitter address mismatch");

        bearToken = address(splitter.TOKEN_A());
        bullToken = address(splitter.TOKEN_B());

        (uint256 usdcRequired,,) = splitter.previewMint(600_000e18);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(600_000e18);
    }
}
