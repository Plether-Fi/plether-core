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

// ============================================================
// LEVERAGE ROUTER FORK TEST
// Tests LeverageRouter with real Curve pool + mock Morpho/Lender
// ============================================================

import {LeverageRouter} from "../../src/LeverageRouter.sol";
import {MarketParams, IMorpho} from "../../src/interfaces/IMorpho.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

contract LeverageRouterForkTest is Test {
    // Mainnet constants
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE_CRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;
    address constant CL_EUR = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;

    // Protocol
    SyntheticSplitter splitter;
    StakedToken stBear;
    LeverageRouter leverageRouter;
    BasketOracle basketOracle;
    MockYieldAdapter yieldAdapter;

    // Mocks for lending (Morpho integration tested separately)
    MockMorphoForFork morpho;
    MockFlashLenderForFork lender;

    address curvePool;
    address bullToken;
    address bearToken;

    address alice = address(0xA11CE);

    function setUp() public {
        // 1. SETUP FORK
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url, 24_136_062);
        } catch {
            revert("Missing MAINNET_RPC_URL in .env");
        }

        // 2. FUNDING
        deal(USDC, address(this), 2_000_000e6);
        deal(USDC, alice, 100_000e6);

        // 3. FETCH REAL PRICE AND WARP
        uint256 realOraclePrice;
        {
            (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR).latestRoundData();
            realOraclePrice = uint256(price) * 1e10;
            vm.warp(updatedAt + 1 hours);
        }

        // 4. DEPLOY CORE PROTOCOL
        {
            yieldAdapter = new MockYieldAdapter(IERC20(USDC), address(this));

            address[] memory feeds = new address[](1);
            feeds[0] = CL_EUR;
            uint256[] memory qtys = new uint256[](1);
            qtys[0] = 1e18;

            address tempCurvePool = address(new MockCurvePoolForOracle(realOraclePrice));
            basketOracle = new BasketOracle(feeds, qtys, tempCurvePool, 200);

            splitter = new SyntheticSplitter(
                address(basketOracle), USDC, address(yieldAdapter), 2e8, address(this), address(0)
            );

            bullToken = address(splitter.TOKEN_B());
            bearToken = address(splitter.TOKEN_A());

            stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");

            // Mint initial tokens
            IERC20(USDC).approve(address(splitter), 1_000_000e6);
            splitter.mint(500_000e18);
        }

        // 5. DEPLOY CURVE POOL
        {
            address[2] memory coins = [USDC, bearToken];

            curvePool = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY)
                .deploy_pool(
                    "USDC/Bear Pool",
                    "USDC-BEAR",
                    coins,
                    0,
                    2000000,
                    50000000000000,
                    5000000, // mid_fee = 0.05%
                    45000000, // out_fee = 0.45%
                    2000000000000,
                    230000000000000,
                    146000000000000,
                    600,
                    realOraclePrice
                );

            // Add Liquidity
            IERC20(USDC).approve(curvePool, type(uint256).max);
            IERC20(bearToken).approve(curvePool, type(uint256).max);

            uint256 bearAmount = 400_000e18;
            uint256 usdcAmount = (bearAmount * realOraclePrice) / 1e18 / 1e12;
            uint256[2] memory amountsFixed = [usdcAmount, bearAmount];

            (bool success,) =
                curvePool.call(abi.encodeWithSignature("add_liquidity(uint256[2],uint256)", amountsFixed, 0));
            require(success, "Liquidity Add Failed");
        }

        // 6. DEPLOY MOCK MORPHO AND FLASH LENDER
        morpho = new MockMorphoForFork(USDC, address(stBear));
        lender = new MockFlashLenderForFork(USDC);

        // Fund flash lender and morpho for borrows
        deal(USDC, address(lender), 1_000_000e6);
        deal(USDC, address(morpho), 1_000_000e6);

        // 7. DEPLOY LEVERAGE ROUTER
        MarketParams memory params = MarketParams({
            loanToken: USDC, collateralToken: address(stBear), oracle: address(0), irm: address(0), lltv: 0
        });

        leverageRouter =
            new LeverageRouter(address(morpho), curvePool, USDC, bearToken, address(stBear), address(lender), params);
    }

    /// @notice Test opening a leveraged BEAR position with real Curve swap
    function test_OpenLeverage_RealCurve() public {
        uint256 principal = 1000e6; // 1000 USDC
        uint256 leverage = 2e18; // 2x leverage

        vm.startPrank(alice);

        // Authorize router in Morpho
        morpho.setAuthorization(address(leverageRouter), true);

        // Approve USDC
        IERC20(USDC).approve(address(leverageRouter), principal);

        // Preview what we expect
        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedBear,) =
            leverageRouter.previewOpenLeverage(principal, leverage);

        console.log("=== OPEN LEVERAGE ===");
        console.log("Principal:", principal);
        console.log("Loan Amount:", loanAmount);
        console.log("Total USDC:", totalUSDC);
        console.log("Expected BEAR:", expectedBear);

        // Execute
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        vm.stopPrank();

        // Verify position
        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);

        console.log("Collateral (stBEAR):", collateral);
        console.log("Debt (USDC):", debt);

        // Assertions
        assertGt(collateral, 0, "Should have collateral");
        assertEq(debt, loanAmount, "Debt should equal loan amount");
        // Collateral should be close to expectedBear (within 1% due to slippage)
        assertGt(collateral, (expectedBear * 99) / 100, "Collateral should be close to expected");
    }

    /// @notice Test closing a leveraged position with real Curve swap
    function test_CloseLeverage_RealCurve() public {
        // Use smaller position to stay within 1% slippage limit
        uint256 principal = 500e6; // 500 USDC
        uint256 leverage = 2e18; // 2x leverage = 1000 USDC total swap

        vm.startPrank(alice);
        morpho.setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);

        console.log("=== BEFORE CLOSE ===");
        console.log("Collateral:", collateral);
        console.log("Debt:", debt);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        // Close the position (max 1% slippage enforced by contract)
        leverageRouter.closeLeverage(debt, collateral, 100, block.timestamp + 1 hours);

        vm.stopPrank();

        uint256 aliceUsdcAfter = IERC20(USDC).balanceOf(alice);
        uint256 usdcReturned = aliceUsdcAfter - aliceUsdcBefore;

        console.log("=== AFTER CLOSE ===");
        console.log("USDC Returned:", usdcReturned);
        console.log("Collateral:", morpho.collateralBalance(alice));
        console.log("Debt:", morpho.borrowBalance(alice));

        // Assertions
        assertEq(morpho.collateralBalance(alice), 0, "Collateral should be cleared");
        assertEq(morpho.borrowBalance(alice), 0, "Debt should be cleared");
        // Should get most of principal back (minus swap fees ~1%)
        assertGt(usdcReturned, (principal * 95) / 100, "Should return >95% of principal");
    }

    /// @notice Test round-trip: open and close, measure total cost
    function test_LeverageRoundTrip_RealCurve() public {
        // Use smaller position to stay within 1% slippage limit
        uint256 principal = 1000e6; // 1000 USDC
        uint256 leverage = 2e18; // 2x leverage = 2000 USDC total swap

        uint256 aliceUsdcStart = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        morpho.setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);

        // Open
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);

        // Close immediately (max 1% slippage enforced by contract)
        leverageRouter.closeLeverage(debt, collateral, 100, block.timestamp + 1 hours);

        vm.stopPrank();

        uint256 aliceUsdcEnd = IERC20(USDC).balanceOf(alice);
        uint256 totalCost = aliceUsdcStart - aliceUsdcEnd;

        console.log("=== ROUND TRIP ANALYSIS ===");
        console.log("Principal:", principal);
        console.log("Leverage:", leverage / 1e18, "x");
        console.log("Total USDC swapped:", principal * (leverage / 1e18));
        console.log("Round-trip cost:", totalCost);
        console.log("Cost %:", (totalCost * 10000) / principal, "bps");

        // With 2x leverage, we swap 2000 USDC worth through Curve each way
        // At ~0.5% fees each way, expect ~1-2% total cost
        assertLt(totalCost, (principal * 5) / 100, "Round-trip cost should be <5%");
    }
}

// ============================================================
// BULL LEVERAGE ROUTER FORK TEST
// Tests BullLeverageRouter with real Curve pool + mock Morpho/Lender
// Uses real Splitter for minting/burning pairs
// ============================================================

import {BullLeverageRouter} from "../../src/BullLeverageRouter.sol";

contract BullLeverageRouterForkTest is Test {
    // Mainnet constants
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE_CRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;
    address constant CL_EUR = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;

    // Protocol
    SyntheticSplitter splitter;
    StakedToken stBull;
    BullLeverageRouter bullLeverageRouter;
    BasketOracle basketOracle;
    MockYieldAdapter yieldAdapter;

    // Mocks for lending
    MockMorphoForFork morpho;
    MockFlashLenderForFork lender;

    address curvePool;
    address bullToken;
    address bearToken;

    address alice = address(0xA11CE);

    function setUp() public {
        // 1. SETUP FORK
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url, 24_136_062);
        } catch {
            revert("Missing MAINNET_RPC_URL in .env");
        }

        // 2. FUNDING
        deal(USDC, address(this), 2_000_000e6);
        deal(USDC, alice, 100_000e6);

        // 3. FETCH REAL PRICE AND WARP
        uint256 realOraclePrice;
        {
            (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR).latestRoundData();
            realOraclePrice = uint256(price) * 1e10;
            vm.warp(updatedAt + 1 hours);
        }

        // 4. DEPLOY CORE PROTOCOL
        {
            yieldAdapter = new MockYieldAdapter(IERC20(USDC), address(this));

            address[] memory feeds = new address[](1);
            feeds[0] = CL_EUR;
            uint256[] memory qtys = new uint256[](1);
            qtys[0] = 1e18;

            address tempCurvePool = address(new MockCurvePoolForOracle(realOraclePrice));
            basketOracle = new BasketOracle(feeds, qtys, tempCurvePool, 200);

            splitter = new SyntheticSplitter(
                address(basketOracle), USDC, address(yieldAdapter), 2e8, address(this), address(0)
            );

            bullToken = address(splitter.TOKEN_B());
            bearToken = address(splitter.TOKEN_A());

            stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

            // Mint initial tokens for pool liquidity
            IERC20(USDC).approve(address(splitter), 1_000_000e6);
            splitter.mint(500_000e18);
        }

        // 5. DEPLOY CURVE POOL (USDC/BEAR for selling BEAR from minted pairs)
        {
            address[2] memory coins = [USDC, bearToken];

            curvePool = ICurveCryptoFactory(CURVE_CRYPTO_FACTORY)
                .deploy_pool(
                    "USDC/Bear Pool",
                    "USDC-BEAR",
                    coins,
                    0,
                    2000000,
                    50000000000000,
                    5000000, // mid_fee = 0.05%
                    45000000, // out_fee = 0.45%
                    2000000000000,
                    230000000000000,
                    146000000000000,
                    600,
                    realOraclePrice
                );

            // Add Liquidity
            IERC20(USDC).approve(curvePool, type(uint256).max);
            IERC20(bearToken).approve(curvePool, type(uint256).max);

            uint256 bearAmount = 400_000e18;
            uint256 usdcAmount = (bearAmount * realOraclePrice) / 1e18 / 1e12;
            uint256[2] memory amountsFixed = [usdcAmount, bearAmount];

            (bool success,) =
                curvePool.call(abi.encodeWithSignature("add_liquidity(uint256[2],uint256)", amountsFixed, 0));
            require(success, "Liquidity Add Failed");
        }

        // 6. DEPLOY MOCK MORPHO AND FLASH LENDER
        morpho = new MockMorphoForFork(USDC, address(stBull));
        lender = new MockFlashLenderForFork(USDC);

        // Fund flash lender and morpho for borrows
        deal(USDC, address(lender), 1_000_000e6);
        deal(USDC, address(morpho), 1_000_000e6);

        // 7. DEPLOY BULL LEVERAGE ROUTER
        MarketParams memory params = MarketParams({
            loanToken: USDC, collateralToken: address(stBull), oracle: address(0), irm: address(0), lltv: 0
        });

        bullLeverageRouter = new BullLeverageRouter(
            address(morpho),
            address(splitter),
            curvePool,
            USDC,
            bearToken,
            bullToken,
            address(stBull),
            address(lender),
            params
        );
    }

    /// @notice Test opening a leveraged BULL position with real Curve swap
    function test_OpenLeverage_RealCurve() public {
        uint256 principal = 1000e6; // 1000 USDC
        uint256 leverage = 2e18; // 2x leverage

        vm.startPrank(alice);

        // Authorize router in Morpho
        morpho.setAuthorization(address(bullLeverageRouter), true);

        // Approve USDC
        IERC20(USDC).approve(address(bullLeverageRouter), principal);

        // Preview what we expect
        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedBull, uint256 expectedDebt) =
            bullLeverageRouter.previewOpenLeverage(principal, leverage);

        console.log("=== OPEN BULL LEVERAGE ===");
        console.log("Principal:", principal);
        console.log("Loan Amount:", loanAmount);
        console.log("Total USDC:", totalUSDC);
        console.log("Expected BULL:", expectedBull);
        console.log("Expected Debt:", expectedDebt);

        // Execute
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        vm.stopPrank();

        // Verify position
        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);

        console.log("Collateral (stBULL):", collateral);
        console.log("Debt (USDC):", debt);

        // Assertions
        assertGt(collateral, 0, "Should have collateral");
        // Debt may be 0 if BEAR sells for more than flash loan amount (favorable market)
        // Debt should never exceed loan amount since we sell BEAR for USDC to offset
        assertLe(debt, loanAmount, "Debt should be <= loan amount");
        // Collateral should be close to expectedBull (within 1% due to slippage)
        assertGt(collateral, (expectedBull * 99) / 100, "Collateral should be close to expected");
    }

    /// @notice Test closing a leveraged BULL position with real Curve swap
    function test_CloseLeverage_RealCurve() public {
        // Use smaller position to stay within slippage limits
        uint256 principal = 500e6; // 500 USDC
        uint256 leverage = 2e18; // 2x leverage

        vm.startPrank(alice);
        morpho.setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);

        console.log("=== BEFORE CLOSE ===");
        console.log("Collateral:", collateral);
        console.log("Debt:", debt);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        // Close the position
        bullLeverageRouter.closeLeverage(debt, collateral, 100, block.timestamp + 1 hours);

        vm.stopPrank();

        uint256 aliceUsdcAfter = IERC20(USDC).balanceOf(alice);
        uint256 usdcReturned = aliceUsdcAfter - aliceUsdcBefore;

        console.log("=== AFTER CLOSE ===");
        console.log("USDC Returned:", usdcReturned);
        console.log("Collateral:", morpho.collateralBalance(alice));
        console.log("Debt:", morpho.borrowBalance(alice));

        // Assertions
        assertEq(morpho.collateralBalance(alice), 0, "Collateral should be cleared");
        assertEq(morpho.borrowBalance(alice), 0, "Debt should be cleared");
        // Should get most of principal back (minus swap fees)
        assertGt(usdcReturned, (principal * 90) / 100, "Should return >90% of principal");
    }

    /// @notice Test round-trip: open and close BULL position, measure total cost
    function test_LeverageRoundTrip_RealCurve() public {
        uint256 principal = 1000e6; // 1000 USDC
        uint256 leverage = 2e18; // 2x leverage

        uint256 aliceUsdcStart = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        morpho.setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);

        // Open
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);

        // Close immediately
        bullLeverageRouter.closeLeverage(debt, collateral, 100, block.timestamp + 1 hours);

        vm.stopPrank();

        uint256 aliceUsdcEnd = IERC20(USDC).balanceOf(alice);
        uint256 totalCost = aliceUsdcStart - aliceUsdcEnd;

        console.log("=== BULL ROUND TRIP ANALYSIS ===");
        console.log("Principal:", principal);
        console.log("Leverage:", leverage / 1e18, "x");
        console.log("Round-trip cost:", totalCost);
        console.log("Cost %:", (totalCost * 10000) / principal, "bps");

        // Bull leverage swaps BEAR for USDC (open) then USDC for BEAR (close)
        // Expect ~2-5% total cost due to swap fees and slippage
        assertLt(totalCost, (principal * 10) / 100, "Round-trip cost should be <10%");
    }

    /// @notice Test that preview functions return sensible values with offset
    function test_PreviewCloseLeverage_WithOffset() public {
        // First open a position
        uint256 principal = 500e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        morpho.setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        uint256 collateral = morpho.collateralBalance(alice);
        uint256 debt = morpho.borrowBalance(alice);
        vm.stopPrank();

        // Preview close - should handle offset correctly
        (uint256 expectedUSDC, uint256 usdcForBearBuyback, uint256 expectedReturn) =
            bullLeverageRouter.previewCloseLeverage(debt, collateral);

        console.log("=== PREVIEW CLOSE ===");
        console.log("Collateral (shares):", collateral);
        console.log("Expected USDC:", expectedUSDC);
        console.log("USDC for BEAR buyback:", usdcForBearBuyback);
        console.log("Expected Return:", expectedReturn);

        // expectedUSDC should be reasonable (not 1000x too high)
        // With ~500 USDC principal at 2x, we have ~1000 USDC worth of BULL
        // At CAP price (2e8 = $2), each BULL is worth $2, so ~500 BULL = $1000
        assertLt(expectedUSDC, 2000e6, "Expected USDC should be < 2000 (sanity check)");
        assertGt(expectedUSDC, 500e6, "Expected USDC should be > 500 (sanity check)");
    }
}

// ============================================================
// MOCK CONTRACTS FOR FORK TEST
// ============================================================

contract MockMorphoForFork is IMorpho {
    address public usdc;
    address public collateralToken;
    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public borrowBalance;
    mapping(address => mapping(address => bool)) public authorizations;

    constructor(address _usdc, address _collateralToken) {
        usdc = _usdc;
        collateralToken = _collateralToken;
    }

    function setAuthorization(address authorized, bool status) external {
        authorizations[msg.sender][authorized] = status;
    }

    function isAuthorized(address authorizer, address authorized) external view override returns (bool) {
        return authorizations[authorizer][authorized];
    }

    function supply(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        IERC20(collateralToken).transferFrom(msg.sender, address(this), assets);
        collateralBalance[onBehalfOf] += assets;
        return (assets, 0);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address receiver)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(authorizations[onBehalfOf][msg.sender], "Not authorized");
        }
        // Transfer USDC to receiver (mock must be funded in setUp)
        IERC20(usdc).transfer(receiver, assets);
        borrowBalance[onBehalfOf] += assets;
        return (assets, 0);
    }

    function repay(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        IERC20(usdc).transferFrom(msg.sender, address(this), assets);
        borrowBalance[onBehalfOf] -= assets;
        return (assets, 0);
    }

    function withdraw(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address receiver)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(authorizations[onBehalfOf][msg.sender], "Not authorized");
        }
        collateralBalance[onBehalfOf] -= assets;
        IERC20(collateralToken).transfer(receiver, assets);
        return (assets, 0);
    }

    function position(bytes32, address) external pure override returns (uint256, uint128, uint128) {
        return (0, 0, 0);
    }

    function market(bytes32) external pure override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }
}

contract MockFlashLenderForFork is IERC3156FlashLender {
    address public token;

    constructor(address _token) {
        token = _token;
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256) external pure override returns (uint256) {
        return 0; // No fee for testing
    }

    function flashLoan(IERC3156FlashBorrower receiver, address _token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        require(_token == token, "Unsupported token");

        // Transfer tokens to borrower
        IERC20(token).transfer(address(receiver), amount);

        // Execute callback
        require(
            receiver.onFlashLoan(msg.sender, _token, amount, 0, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );

        // Collect repayment
        IERC20(token).transferFrom(address(receiver), address(this), amount);

        return true;
    }
}
