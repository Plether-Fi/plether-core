// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {SyntheticSplitter} from "../../src/SyntheticSplitter.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {StakedOracle} from "../../src/oracles/StakedOracle.sol";
import {MockYieldAdapter} from "../../src/MockYieldAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

// --------------------------------------------------------
// INTERFACES (For Mainnet Interaction)
// --------------------------------------------------------
interface ICurveCryptoFactory {
    function deploy_pool(
        string memory _name,
        string memory _symbol,
        address[2] memory _coins, // Fixed array for Vyper compatibility
        uint256 implementation_id,
        uint256 A,
        uint256 gamma,
        uint256 mid_fee,
        uint256 out_fee,
        uint256 allowed_extra_profit,
        uint256 fee_gamma,
        uint256 adjustment_step,
        uint256 ma_half_time,
        uint256 initial_price
    ) external returns (address);
}

interface ICurvePoolExtended {
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function price_oracle() external view returns (uint256);
}

contract MainnetForkTest is Test {
    // ==========================================
    // MAINNET CONSTANTS
    // ==========================================
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Correct Checksummed Address for Twocrypto-NG Factory
    address constant CURVE_CRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;

    address constant CL_EUR = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;

    // ==========================================
    // STATE
    // ==========================================
    SyntheticSplitter splitter;
    StakedToken stBull;
    StakedToken stBear;
    ZapRouter zapRouter;
    BasketOracle basketOracle;
    StakedOracle stakedOracle;
    MockYieldAdapter yieldAdapter;

    address curvePool;
    address bullToken;
    address bearToken;

    function setUp() public {
        // 1. SETUP FORK
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            // Use a recent block to ensure Chainlink feeds are fresh
            vm.createSelectFork(url, 24_136_062);
        } catch {
            revert("Missing MAINNET_RPC_URL in .env");
        }
        if (block.chainid != 1) revert("Wrong Chain! Must be Mainnet.");

        // 2. FUNDING
        deal(USDC, address(this), 2_000_000e6);

        // 3. FETCH REAL PRICE AND WARP TO FRESH TIMESTAMP
        uint256 realOraclePrice;
        {
            (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR).latestRoundData();
            realOraclePrice = uint256(price) * 1e10;
            console.log("Real Oracle Price:", realOraclePrice);

            // Warp to 1 hour after oracle update to ensure freshness (within 8-hour window)
            vm.warp(updatedAt + 1 hours);
        }

        // 4. DEPLOY CORE PROTOCOL (Scoped Block 1)
        {
            yieldAdapter = new MockYieldAdapter(IERC20(USDC), address(this));

            address[] memory feeds = new address[](1);
            feeds[0] = CL_EUR;
            uint256[] memory qtys = new uint256[](1);
            qtys[0] = 1e18;

            // Mock Pool for Oracle Init (Initialized with REAL price)
            address tempCurvePool = address(new MockCurvePoolForOracle(realOraclePrice));
            basketOracle = new BasketOracle(feeds, qtys, tempCurvePool, 200);

            splitter = new SyntheticSplitter(
                address(basketOracle), USDC, address(yieldAdapter), 2e8, address(this), address(0)
            );

            bullToken = address(splitter.TOKEN_B());
            bearToken = address(splitter.TOKEN_A());

            stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");
            stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");

            // Mint initial tokens (500k pairs for deep pool liquidity)
            IERC20(USDC).approve(address(splitter), 1_000_000e6);
            splitter.mint(500_000e18);
        }

        // 5. DEPLOY CURVE POOL (Scoped Block 2)
        {
            address[2] memory coins = [USDC, bearToken];

            console.log("Deploying Pool with Price:", realOraclePrice);

            // CONFIGURATION:
            // 1. Use Safe V2 Params (A=2M, Gamma=0.00005)
            // 2. CRITICAL: Must use non-zero fees! 0% fees cause USDC→BEAR swaps to fail
            //    because the pool's xcp (virtual profit) check fails without fee revenue
            // 3. Use actual oracle price for initialization

            curvePool = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY)
                .deploy_pool(
                    "USDC/Bear Pool",
                    "USDC-BEAR",
                    coins,
                    0,
                    2000000, // A
                    50000000000000, // gamma
                    5000000, // mid_fee = 0.05%
                    45000000, // out_fee = 0.45%
                    2000000000000, // allowed_extra_profit
                    230000000000000, // fee_gamma
                    146000000000000, // adjustment_step
                    600, // ma_half_time
                    realOraclePrice
                );

            require(curvePool != address(0), "Pool Deployment Failed");
            console.log("Pool Deployed at:", curvePool);

            // Add Liquidity (500k BEAR for deep liquidity to support zapBurn)
            IERC20(USDC).approve(curvePool, type(uint256).max);
            IERC20(bearToken).approve(curvePool, type(uint256).max);

            uint256 bearAmount = 500_000e18;
            uint256 usdcAmount = (bearAmount * realOraclePrice) / 1e18 / 1e12;
            uint256[2] memory amountsFixed = [usdcAmount, bearAmount];

            // Low-level call to bypass ABI encoding issues
            (bool success,) =
                curvePool.call(abi.encodeWithSignature("add_liquidity(uint256[2],uint256)", amountsFixed, 0));
            require(success, "Liquidity Add Failed");
        }

        // 6. DEPLOY ROUTER
        zapRouter = new ZapRouter(address(splitter), bearToken, bullToken, USDC, curvePool);
    }

    function test_ZapMint_RealExecution() public {
        uint256 amountIn = 1000e6;
        IERC20(USDC).approve(address(zapRouter), amountIn);
        uint256 balanceBefore = IERC20(bullToken).balanceOf(address(this));

        // Execute Real Zap
        zapRouter.zapMint(amountIn, 0, 100, block.timestamp + 1 hours);

        uint256 balanceAfter = IERC20(bullToken).balanceOf(address(this));

        console.log("USDC In:", amountIn);
        console.log("BULL Out:", balanceAfter - balanceBefore);

        assertGt(balanceAfter, balanceBefore);
    }

    function test_SplitterMint_RealExecution() public {
        uint256 mintAmount = 1000e18;
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);

        uint256 bullBefore = IERC20(bullToken).balanceOf(address(this));

        splitter.mint(mintAmount);

        uint256 bullAfter = IERC20(bullToken).balanceOf(address(this));
        assertEq(bullAfter - bullBefore, mintAmount);
    }

    /// @notice Test zapBurn with proper pool fees
    function test_ZapBurn_RealExecution() public {
        // 1. ZapMint first
        uint256 amountIn = 100e6; // 100 USDC
        uint256 bullBefore = IERC20(bullToken).balanceOf(address(this));

        IERC20(USDC).approve(address(zapRouter), amountIn);
        zapRouter.zapMint(amountIn, 0, 100, block.timestamp + 1 hours);

        uint256 bullMinted = IERC20(bullToken).balanceOf(address(this)) - bullBefore;
        console.log("BULL minted:", bullMinted);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        // 2. ZapBurn
        IERC20(bullToken).approve(address(zapRouter), bullMinted);
        zapRouter.zapBurn(bullMinted, 0, block.timestamp + 1 hours);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        uint256 usdcReturned = usdcAfter - usdcBefore;

        console.log("USDC returned:", usdcReturned);
        console.log("Round-trip cost:", amountIn - usdcReturned);

        // 3. Assertions
        // With fees (~0.5% each way), expect ~98-99% return
        assertGt(usdcReturned, 95e6, "Should return >95% of original USDC");
        assertEq(IERC20(bullToken).balanceOf(address(this)), bullBefore, "All minted BULL burned");
    }
}

contract MockCurvePoolForOracle {
    uint256 public oraclePrice;

    constructor(uint256 _price) {
        oraclePrice = _price;
    }

    function price_oracle() external view returns (uint256) {
        return oraclePrice;
    }
}
