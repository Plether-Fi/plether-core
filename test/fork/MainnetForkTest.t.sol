// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {SyntheticSplitter} from "../../src/SyntheticSplitter.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../../src/oracles/StakedOracle.sol";
import {MockYieldAdapter} from "../../src/MockYieldAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {LeverageRouter} from "../../src/LeverageRouter.sol";
import {BullLeverageRouter} from "../../src/BullLeverageRouter.sol";
import {MarketParams, IMorpho} from "../../src/interfaces/IMorpho.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

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
    uint256 constant LLTV_86 = 860000000000000000; // 86%
    uint256 constant LLTV_945 = 945000000000000000; // 94.5%

    // ==========================================
    // BALANCER V2 MAINNET CONSTANTS
    // ==========================================
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // ==========================================
    // CURVE POOL PARAMETERS
    // Single source of truth for all fork tests
    // ==========================================
    uint256 constant CURVE_A = 2000000;
    uint256 constant CURVE_GAMMA = 50000000000000;
    uint256 constant CURVE_MID_FEE = 5000000; // 0.05%
    uint256 constant CURVE_OUT_FEE = 45000000; // 0.45%
    uint256 constant CURVE_ALLOWED_EXTRA_PROFIT = 2000000000000;
    uint256 constant CURVE_FEE_GAMMA = 230000000000000;
    uint256 constant CURVE_ADJUSTMENT_STEP = 146000000000000;
    uint256 constant CURVE_MA_HALF_TIME = 600;

    // ==========================================
    // PROTOCOL STATE
    // ==========================================
    SyntheticSplitter public splitter;
    BasketOracle public basketOracle;
    MockYieldAdapter public yieldAdapter;

    address public curvePool;
    address public bullToken;
    address public bearToken;

    uint256 public realOraclePrice;

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
        realOraclePrice = uint256(price) * 1e10;
        vm.warp(updatedAt + 1 hours);
    }

    /// @notice Deploy core protocol (adapter, oracle, splitter)
    /// @param treasury Address to receive yield
    function _deployProtocol(address treasury) internal {
        address[] memory feeds = new address[](1);
        feeds[0] = CL_EUR;
        uint256[] memory qtys = new uint256[](1);
        qtys[0] = 1e18;

        // Mock Pool for Oracle Init (using real price)
        address tempCurvePool = address(new MockCurvePoolForOracle(realOraclePrice));
        basketOracle = new BasketOracle(feeds, qtys, tempCurvePool, 200);

        // Predict splitter address (deployed after yieldAdapter)
        uint64 currentNonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), currentNonce + 1);

        yieldAdapter = new MockYieldAdapter(IERC20(USDC), address(this), predictedSplitter);

        splitter = new SyntheticSplitter(address(basketOracle), USDC, address(yieldAdapter), 2e8, treasury, address(0));
        require(address(splitter) == predictedSplitter, "Splitter address mismatch");

        bullToken = address(splitter.TOKEN_B());
        bearToken = address(splitter.TOKEN_A());
    }

    /// @notice Deploy Curve pool with USDC/BEAR pair
    /// @param bearLiquidity Amount of BEAR to add as liquidity (18 decimals)
    function _deployCurvePool(uint256 bearLiquidity) internal {
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
                CURVE_ALLOWED_EXTRA_PROFIT,
                CURVE_FEE_GAMMA,
                CURVE_ADJUSTMENT_STEP,
                CURVE_MA_HALF_TIME,
                realOraclePrice
            );

        require(curvePool != address(0), "Pool Deployment Failed");

        // Add Liquidity
        IERC20(USDC).approve(curvePool, type(uint256).max);
        IERC20(bearToken).approve(curvePool, type(uint256).max);

        uint256 usdcAmount = (bearLiquidity * realOraclePrice) / 1e18 / 1e12;
        uint256[2] memory amounts = [usdcAmount, bearLiquidity];

        (bool success,) = curvePool.call(abi.encodeWithSignature("add_liquidity(uint256[2],uint256)", amounts, 0));
        require(success, "Liquidity Add Failed");
    }

    /// @notice Mint initial token pairs
    /// @param amount Amount of token pairs to mint (18 decimals)
    function _mintInitialTokens(uint256 amount) internal {
        (uint256 usdcRequired,,) = splitter.previewMint(amount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(amount);
    }

    /// @notice Create a Morpho market and supply liquidity
    /// @param collateralToken The collateral token (staked token)
    /// @param oracle The price oracle for the collateral
    /// @param liquidityAmount Amount of USDC to supply as liquidity
    /// @return params The market params for the created market
    function _createMorphoMarket(address collateralToken, address oracle, uint256 liquidityAmount)
        internal
        returns (MarketParams memory params)
    {
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
// MAINNET FORK TEST
// Tests ZapRouter with real Curve pool
// ============================================================

contract MainnetForkTest is BaseForkTest {
    StakedToken stBull;
    StakedToken stBear;
    ZapRouter zapRouter;
    StakedOracle stakedOracle;

    function setUp() public {
        _setupFork();
        if (block.chainid != 1) revert("Wrong Chain! Must be Mainnet.");

        deal(USDC, address(this), 2_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");
        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");

        _mintInitialTokens(500_000e18);
        _deployCurvePool(500_000e18);

        zapRouter = new ZapRouter(address(splitter), bearToken, bullToken, USDC, curvePool);
    }

    function test_ZapMint_RealExecution() public {
        uint256 amountIn = 1000e6;
        IERC20(USDC).approve(address(zapRouter), amountIn);
        uint256 balanceBefore = IERC20(bullToken).balanceOf(address(this));

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

    function test_ZapBurn_RealExecution() public {
        uint256 amountIn = 100e6;
        uint256 bullBefore = IERC20(bullToken).balanceOf(address(this));

        IERC20(USDC).approve(address(zapRouter), amountIn);
        zapRouter.zapMint(amountIn, 0, 100, block.timestamp + 1 hours);

        uint256 bullMinted = IERC20(bullToken).balanceOf(address(this)) - bullBefore;
        console.log("BULL minted:", bullMinted);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        IERC20(bullToken).approve(address(zapRouter), bullMinted);
        zapRouter.zapBurn(bullMinted, 0, block.timestamp + 1 hours);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        uint256 usdcReturned = usdcAfter - usdcBefore;

        console.log("USDC returned:", usdcReturned);
        console.log("Round-trip cost:", amountIn - usdcReturned);

        assertGt(usdcReturned, 95e6, "Should return >95% of original USDC");
        assertEq(IERC20(bullToken).balanceOf(address(this)), bullBefore, "All minted BULL burned");
    }
}

// ============================================================
// FULL CYCLE FORK TEST
// Tests complete protocol lifecycle: Mint -> Yield -> Burn
// ============================================================

contract FullCycleForkTest is BaseForkTest {
    address treasury;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        _setupFork();

        treasury = makeAddr("treasury");

        deal(USDC, alice, 100_000e6);
        deal(USDC, bob, 100_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(treasury);
    }

    function test_FullCycle_MintYieldBurn() public {
        uint256 mintAmount = 10_000e18;

        // PHASE 1: MINT
        console.log("=== PHASE 1: MINT ===");

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        console.log("USDC Required for mint:", usdcRequired);

        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        assertEq(IERC20(bullToken).balanceOf(alice), mintAmount, "Alice should have BULL tokens");
        assertEq(IERC20(bearToken).balanceOf(alice), mintAmount, "Alice should have BEAR tokens");
        console.log("Alice BULL balance:", IERC20(bullToken).balanceOf(alice));
        console.log("Alice BEAR balance:", IERC20(bearToken).balanceOf(alice));

        uint256 adapterShares = yieldAdapter.balanceOf(address(splitter));
        uint256 adapterAssets = yieldAdapter.convertToAssets(adapterShares);
        uint256 localBuffer = IERC20(USDC).balanceOf(address(splitter));
        console.log("Adapter assets:", adapterAssets);
        console.log("Local buffer:", localBuffer);
        console.log("Total holdings:", adapterAssets + localBuffer);

        // PHASE 2: SIMULATE YIELD
        console.log("\n=== PHASE 2: SIMULATE YIELD ===");

        uint256 yieldAmount = (adapterAssets * 10) / 100;
        console.log("Simulated yield:", yieldAmount);

        deal(USDC, address(yieldAdapter), adapterAssets + yieldAmount);

        uint256 newAdapterAssets = yieldAdapter.convertToAssets(adapterShares);
        console.log("New adapter assets after yield:", newAdapterAssets);

        // PHASE 3: HARVEST YIELD
        console.log("\n=== PHASE 3: HARVEST YIELD ===");

        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        splitter.harvestYield();
        uint256 treasuryAfter = IERC20(USDC).balanceOf(treasury);
        uint256 harvested = treasuryAfter - treasuryBefore;
        console.log("Yield harvested to treasury:", harvested);

        assertGt(harvested, 0, "Should have harvested yield");
        assertGt(harvested, (yieldAmount * 90) / 100, "Should harvest most of yield");

        // PHASE 4: BURN TOKENS
        console.log("\n=== PHASE 4: BURN ===");

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        (uint256 expectedUsdc,) = splitter.previewBurn(mintAmount);
        console.log("Expected USDC from burn:", expectedUsdc);

        IERC20(bullToken).approve(address(splitter), mintAmount);
        IERC20(bearToken).approve(address(splitter), mintAmount);
        splitter.burn(mintAmount);
        vm.stopPrank();

        uint256 aliceUsdcAfter = IERC20(USDC).balanceOf(alice);
        uint256 usdcReturned = aliceUsdcAfter - aliceUsdcBefore;
        console.log("USDC returned from burn:", usdcReturned);

        assertEq(IERC20(bullToken).balanceOf(alice), 0, "Alice should have no BULL tokens");
        assertEq(IERC20(bearToken).balanceOf(alice), 0, "Alice should have no BEAR tokens");
        assertGt(usdcReturned, (usdcRequired * 99) / 100, "Should return ~100% of original USDC");

        // SUMMARY
        console.log("\n=== SUMMARY ===");
        console.log("USDC deposited:", usdcRequired);
        console.log("USDC returned:", usdcReturned);
        console.log("Yield harvested:", harvested);
        console.log("Net cost to user:", usdcRequired > usdcReturned ? usdcRequired - usdcReturned : 0);
    }

    function test_FullCycle_MultipleUsers() public {
        uint256 aliceMint = 5_000e18;
        uint256 bobMint = 10_000e18;

        // PHASE 1: MULTIPLE MINTS
        console.log("=== PHASE 1: MULTIPLE MINTS ===");

        vm.startPrank(alice);
        (uint256 aliceUsdc,,) = splitter.previewMint(aliceMint);
        IERC20(USDC).approve(address(splitter), aliceUsdc);
        splitter.mint(aliceMint);
        vm.stopPrank();
        console.log("Alice minted %s pairs for %s USDC", aliceMint, aliceUsdc);

        vm.startPrank(bob);
        (uint256 bobUsdc,,) = splitter.previewMint(bobMint);
        IERC20(USDC).approve(address(splitter), bobUsdc);
        splitter.mint(bobMint);
        vm.stopPrank();
        console.log("Bob minted %s pairs for %s USDC", bobMint, bobUsdc);

        // PHASE 2: YIELD ACCRUAL
        console.log("\n=== PHASE 2: YIELD ACCRUAL ===");

        uint256 adapterShares = yieldAdapter.balanceOf(address(splitter));
        uint256 adapterAssets = yieldAdapter.convertToAssets(adapterShares);
        uint256 yieldAmount = (adapterAssets * 5) / 100;

        deal(USDC, address(yieldAdapter), adapterAssets + yieldAmount);
        console.log("Added yield:", yieldAmount);

        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        splitter.harvestYield();
        uint256 harvested = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
        console.log("Harvested:", harvested);

        // PHASE 3: ALICE BURNS
        console.log("\n=== PHASE 3: ALICE BURNS ===");

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(bullToken).approve(address(splitter), aliceMint);
        IERC20(bearToken).approve(address(splitter), aliceMint);
        splitter.burn(aliceMint);
        vm.stopPrank();

        uint256 aliceReturned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;
        console.log("Alice USDC returned:", aliceReturned);

        // PHASE 4: BOB BURNS
        console.log("\n=== PHASE 4: BOB BURNS ===");

        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);
        vm.startPrank(bob);
        IERC20(bullToken).approve(address(splitter), bobMint);
        IERC20(bearToken).approve(address(splitter), bobMint);
        splitter.burn(bobMint);
        vm.stopPrank();

        uint256 bobReturned = IERC20(USDC).balanceOf(bob) - bobUsdcBefore;
        console.log("Bob USDC returned:", bobReturned);

        // ASSERTIONS
        assertEq(IERC20(bullToken).balanceOf(alice), 0, "Alice BULL should be 0");
        assertEq(IERC20(bearToken).balanceOf(alice), 0, "Alice BEAR should be 0");
        assertEq(IERC20(bullToken).balanceOf(bob), 0, "Bob BULL should be 0");
        assertEq(IERC20(bearToken).balanceOf(bob), 0, "Bob BEAR should be 0");

        assertGt(aliceReturned, (aliceUsdc * 99) / 100, "Alice should get ~100% back");
        assertGt(bobReturned, (bobUsdc * 99) / 100, "Bob should get ~100% back");

        console.log("\n=== SUMMARY ===");
        console.log("Total USDC in:", aliceUsdc + bobUsdc);
        console.log("Total USDC out:", aliceReturned + bobReturned);
        console.log("Treasury yield:", harvested);
    }

    function test_FullCycle_MultipleHarvests() public {
        uint256 mintAmount = 50_000e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        console.log("=== INITIAL STATE ===");
        console.log("Minted:", mintAmount, "pairs");

        uint256 totalHarvested = 0;

        for (uint256 i = 1; i <= 4; i++) {
            console.log("\n=== QUARTER", i, "===");

            uint256 adapterShares = yieldAdapter.balanceOf(address(splitter));
            uint256 adapterAssets = yieldAdapter.convertToAssets(adapterShares);
            uint256 quarterlyYield = (adapterAssets * 25) / 1000;

            deal(USDC, address(yieldAdapter), adapterAssets + quarterlyYield);

            uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
            splitter.harvestYield();
            uint256 harvested = IERC20(USDC).balanceOf(treasury) - treasuryBefore;

            totalHarvested += harvested;
            console.log("Quarterly yield added:", quarterlyYield);
            console.log("Harvested:", harvested);
        }

        console.log("\n=== FINAL BURN ===");

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(bullToken).approve(address(splitter), mintAmount);
        IERC20(bearToken).approve(address(splitter), mintAmount);
        splitter.burn(mintAmount);
        vm.stopPrank();

        uint256 returned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;

        console.log("\n=== SUMMARY ===");
        console.log("USDC deposited:", usdcRequired);
        console.log("USDC returned:", returned);
        console.log("Total yield harvested:", totalHarvested);

        assertGt(totalHarvested, 0, "Should have harvested yield");
        assertGt(returned, (usdcRequired * 99) / 100, "Should return ~100% of deposit");
    }
}

// ============================================================
// LEVERAGE ROUTER FORK TEST
// Tests LeverageRouter with real Curve pool + real Morpho
// ============================================================

contract LeverageRouterForkTest is BaseForkTest {
    StakedToken stBear;
    LeverageRouter leverageRouter;
    MorphoOracle morphoOracle;
    BalancerFlashLender lender;
    MarketParams marketParams;

    address alice = address(0xA11CE);

    function setUp() public {
        _setupFork();

        deal(USDC, address(this), 3_000_000e6);
        deal(USDC, alice, 100_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");

        _mintInitialTokens(500_000e18);
        _deployCurvePool(400_000e18);

        // Deploy MorphoOracle for stBEAR pricing (BEAR token, not inverse)
        morphoOracle = new MorphoOracle(address(basketOracle), 2e8, false);

        // Create Morpho market with real Morpho
        marketParams = _createMorphoMarket(address(stBear), address(morphoOracle), 1_000_000e6);

        // Deploy ERC-3156 wrapper around real Balancer V2 Vault (zero fee flash loans)
        lender = new BalancerFlashLender(BALANCER_VAULT);

        // Deploy router
        leverageRouter =
            new LeverageRouter(MORPHO, curvePool, USDC, bearToken, address(stBear), address(lender), marketParams);
    }

    function test_OpenLeverage_RealCurve_RealMorpho() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);

        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedBear,) =
            leverageRouter.previewOpenLeverage(principal, leverage);

        console.log("=== OPEN LEVERAGE (REAL MORPHO) ===");
        console.log("Principal:", principal);
        console.log("Loan Amount:", loanAmount);
        console.log("Total USDC:", totalUSDC);
        console.log("Expected BEAR:", expectedBear);

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Get position from real Morpho
        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        console.log("Collateral (stBEAR):", collateral);
        console.log("Borrow Shares:", borrowShares);

        assertGt(collateral, 0, "Should have collateral");
        assertGt(borrowShares, 0, "Should have debt");
    }

    function test_CloseLeverage_RealCurve_RealMorpho() public {
        uint256 principal = 500e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);
        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        console.log("=== BEFORE CLOSE ===");
        console.log("Collateral:", collateral);
        console.log("Borrow Shares:", borrowShares);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        // Get actual debt in assets (approximate)
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debtAssets = totalBorrowShares > 0 ? (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;

        leverageRouter.closeLeverage(debtAssets, collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 aliceUsdcAfter = IERC20(USDC).balanceOf(alice);
        uint256 usdcReturned = aliceUsdcAfter - aliceUsdcBefore;

        (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);

        console.log("=== AFTER CLOSE ===");
        console.log("USDC Returned:", usdcReturned);
        console.log("Collateral After:", collateralAfter);
        console.log("Borrow Shares After:", borrowSharesAfter);

        assertEq(collateralAfter, 0, "Collateral should be cleared");
        assertGt(usdcReturned, (principal * 90) / 100, "Should return >90% of principal");
    }

    function test_LeverageRoundTrip_RealCurve_RealMorpho() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;

        uint256 aliceUsdcStart = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(leverageRouter), true);
        IERC20(USDC).approve(address(leverageRouter), principal);

        leverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        // Get actual debt in assets
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debt = totalBorrowShares > 0 ? (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;

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

        assertLt(totalCost, (principal * 5) / 100, "Round-trip cost should be <5%");
    }

    /// @notice Helper to compute market ID from params
    function _getMarketId(MarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}

// ============================================================
// BULL LEVERAGE ROUTER FORK TEST
// Tests BullLeverageRouter with real Curve pool + real Morpho
// ============================================================

contract BullLeverageRouterForkTest is BaseForkTest {
    StakedToken stBull;
    BullLeverageRouter bullLeverageRouter;
    MorphoOracle morphoOracle;
    BalancerFlashLender lender;
    MarketParams marketParams;

    address alice = address(0xA11CE);

    function setUp() public {
        _setupFork();

        deal(USDC, address(this), 3_000_000e6);
        deal(USDC, alice, 100_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

        _mintInitialTokens(500_000e18);
        _deployCurvePool(400_000e18);

        // Deploy MorphoOracle for stBULL pricing (BULL token, inverse)
        morphoOracle = new MorphoOracle(address(basketOracle), 2e8, true);

        // Create Morpho market with real Morpho
        marketParams = _createMorphoMarket(address(stBull), address(morphoOracle), 1_000_000e6);

        // Deploy ERC-3156 wrapper around real Balancer V2 Vault (zero fee flash loans)
        lender = new BalancerFlashLender(BALANCER_VAULT);

        // Deploy router
        bullLeverageRouter = new BullLeverageRouter(
            MORPHO,
            address(splitter),
            curvePool,
            USDC,
            bearToken,
            bullToken,
            address(stBull),
            address(lender),
            marketParams
        );
    }

    function test_OpenLeverage_RealCurve_RealMorpho() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);

        (uint256 loanAmount, uint256 totalUSDC, uint256 expectedBull, uint256 expectedDebt) =
            bullLeverageRouter.previewOpenLeverage(principal, leverage);

        console.log("=== OPEN BULL LEVERAGE (REAL MORPHO) ===");
        console.log("Principal:", principal);
        console.log("Loan Amount:", loanAmount);
        console.log("Total USDC:", totalUSDC);
        console.log("Expected BULL:", expectedBull);
        console.log("Expected Debt:", expectedDebt);

        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Get position from real Morpho
        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        console.log("Collateral (stBULL):", collateral);
        console.log("Borrow Shares:", borrowShares);

        assertGt(collateral, 0, "Should have collateral");
    }

    function test_CloseLeverage_RealCurve_RealMorpho() public {
        uint256 principal = 500e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        console.log("=== BEFORE CLOSE ===");
        console.log("Collateral:", collateral);
        console.log("Borrow Shares:", borrowShares);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        // Get actual debt in assets (approximate)
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debtAssets = totalBorrowShares > 0 ? (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;

        bullLeverageRouter.closeLeverage(debtAssets, collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 aliceUsdcAfter = IERC20(USDC).balanceOf(alice);
        uint256 usdcReturned = aliceUsdcAfter - aliceUsdcBefore;

        (, uint128 borrowSharesAfter, uint128 collateralAfter) = IMorpho(MORPHO).position(marketId, alice);

        console.log("=== AFTER CLOSE ===");
        console.log("USDC Returned:", usdcReturned);
        console.log("Collateral After:", collateralAfter);
        console.log("Borrow Shares After:", borrowSharesAfter);

        assertEq(collateralAfter, 0, "Collateral should be cleared");
        assertGt(usdcReturned, (principal * 85) / 100, "Should return >85% of principal");
    }

    function test_LeverageRoundTrip_RealCurve_RealMorpho() public {
        uint256 principal = 1000e6;
        uint256 leverage = 2e18;

        uint256 aliceUsdcStart = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);

        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        // Get actual debt in assets
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debt = totalBorrowShares > 0 ? (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;

        bullLeverageRouter.closeLeverage(debt, collateral, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 aliceUsdcEnd = IERC20(USDC).balanceOf(alice);
        uint256 totalCost = aliceUsdcStart - aliceUsdcEnd;

        console.log("=== BULL ROUND TRIP ANALYSIS ===");
        console.log("Principal:", principal);
        console.log("Leverage:", leverage / 1e18, "x");
        console.log("Round-trip cost:", totalCost);
        console.log("Cost %:", (totalCost * 10000) / principal, "bps");

        assertLt(totalCost, (principal * 10) / 100, "Round-trip cost should be <10%");
    }

    function test_PreviewCloseLeverage_WithOffset() public {
        uint256 principal = 500e6;
        uint256 leverage = 2e18;

        vm.startPrank(alice);
        IMorpho(MORPHO).setAuthorization(address(bullLeverageRouter), true);
        IERC20(USDC).approve(address(bullLeverageRouter), principal);
        bullLeverageRouter.openLeverage(principal, leverage, 100, block.timestamp + 1 hours);

        bytes32 marketId = _getMarketId(marketParams);
        (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(marketId, alice);

        // Get actual debt in assets
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 debt = totalBorrowShares > 0 ? (uint256(borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;
        vm.stopPrank();

        (uint256 expectedUSDC, uint256 usdcForBearBuyback, uint256 expectedReturn) =
            bullLeverageRouter.previewCloseLeverage(debt, collateral);

        console.log("=== PREVIEW CLOSE ===");
        console.log("Collateral (shares):", collateral);
        console.log("Expected USDC:", expectedUSDC);
        console.log("USDC for BEAR buyback:", usdcForBearBuyback);
        console.log("Expected Return:", expectedReturn);

        assertLt(expectedUSDC, 2000e6, "Expected USDC should be < 2000 (sanity check)");
        assertGt(expectedUSDC, 500e6, "Expected USDC should be > 500 (sanity check)");
    }

    /// @notice Helper to compute market ID from params
    function _getMarketId(MarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}

// ============================================================
// MOCK CONTRACTS FOR FORK TEST
// ============================================================

contract MockCurvePoolForOracle {
    uint256 public oraclePrice;

    constructor(uint256 _price) {
        oraclePrice = _price;
    }

    function price_oracle() external view returns (uint256) {
        return oraclePrice;
    }
}

/// @notice Balancer V2 Vault interface for flash loans
interface IBalancerVault {
    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

/// @notice Balancer flash loan recipient interface
interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

/// @notice ERC-3156 wrapper around Balancer V2 Vault flash loans
/// @dev Balancer V2 has zero flash loan fees, making it ideal for leverage operations
contract BalancerFlashLender is IERC3156FlashLender, IFlashLoanRecipient {
    IBalancerVault public immutable VAULT;

    // Transient storage for callback routing
    IERC3156FlashBorrower private _currentBorrower;
    address private _currentInitiator;

    constructor(address _vault) {
        VAULT = IBalancerVault(_vault);
    }

    function maxFlashLoan(address token) external view override returns (uint256) {
        // Return the vault's balance of the token
        return IERC20(token).balanceOf(address(VAULT));
    }

    function flashFee(address, uint256) external pure override returns (uint256) {
        // Balancer V2 has zero flash loan fees
        return 0;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        // Store callback info
        _currentBorrower = receiver;
        _currentInitiator = msg.sender;

        // Prepare Balancer flash loan parameters
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(token);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // Execute flash loan - Balancer will call receiveFlashLoan
        VAULT.flashLoan(this, tokens, amounts, data);

        // Clear transient storage
        _currentBorrower = IERC3156FlashBorrower(address(0));
        _currentInitiator = address(0);

        return true;
    }

    /// @notice Balancer callback - routes to ERC-3156 borrower
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == address(VAULT), "Only Balancer Vault");

        address token = address(tokens[0]);
        uint256 amount = amounts[0];
        uint256 fee = feeAmounts[0];

        // Transfer tokens to borrower
        IERC20(token).transfer(address(_currentBorrower), amount);

        // Call ERC-3156 callback
        bytes32 result = _currentBorrower.onFlashLoan(_currentInitiator, token, amount, fee, userData);
        require(result == keccak256("ERC3156FlashBorrower.onFlashLoan"), "Callback failed");

        // Borrower should have approved us, pull tokens back
        IERC20(token).transferFrom(address(_currentBorrower), address(this), amount + fee);

        // Transfer tokens back to vault (Balancer expects direct transfer, not approve)
        IERC20(token).transfer(address(VAULT), amount + fee);
    }
}
