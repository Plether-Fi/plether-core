// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../src/oracles/StakedOracle.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VerifyDeployment
 * @notice Post-deployment verification script for Plether protocol
 * @dev Runs on mainnet fork to verify:
 *      1. Oracle prices within expected bounds
 *      2. Contract state consistency
 *      3. Approvals and permissions
 *      4. Small mint/burn flow works
 *      5. Router functionality
 */
contract VerifyDeployment is Script {
    // ==========================================
    // DEPLOYED ADDRESSES (update after deploy)
    // ==========================================

    address constant BASKET_ORACLE = address(0); // TODO: Set after deployment
    address constant SPLITTER = address(0); // TODO: Set after deployment
    address constant DXY_BEAR = address(0); // TODO: Set after deployment
    address constant DXY_BULL = address(0); // TODO: Set after deployment
    address constant MORPHO_ORACLE_BEAR = address(0); // TODO: Set after deployment
    address constant MORPHO_ORACLE_BULL = address(0); // TODO: Set after deployment
    address constant STAKED_BEAR = address(0); // TODO: Set after deployment
    address constant STAKED_BULL = address(0); // TODO: Set after deployment
    address constant STAKED_ORACLE_BEAR = address(0); // TODO: Set after deployment
    address constant STAKED_ORACLE_BULL = address(0); // TODO: Set after deployment
    address constant ZAP_ROUTER = address(0); // TODO: Set after deployment
    address constant LEVERAGE_ROUTER = address(0); // TODO: Set after deployment
    address constant BULL_LEVERAGE_ROUTER = address(0); // TODO: Set after deployment

    // External dependencies
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE_POOL = address(0); // TODO: Set after Curve pool deployment

    // Expected values
    uint256 constant CAP = 2 * 10 ** 8; // $2.00 cap (8 decimals)
    uint256 constant MIN_EXPECTED_PRICE = 90_000_000; // $0.90 minimum expected DXY price
    uint256 constant MAX_EXPECTED_PRICE = 140_000_000; // $1.40 maximum expected DXY price

    // Test amounts
    uint256 constant MINT_TEST_AMOUNT = 100 ether; // 100 tokens
    uint256 constant USDC_TEST_AMOUNT = 200e6; // 200 USDC

    function run() external view {
        console2.log("========================================");
        console2.log("PLETHER DEPLOYMENT VERIFICATION");
        console2.log("========================================");
        console2.log("");

        // Check all addresses are set
        _checkAddressesSet();

        // Verify contract state
        _verifyContractState();

        // Verify oracle prices
        _verifyOraclePrices();

        // Verify token relationships
        _verifyTokenRelationships();

        // Verify staking vaults
        _verifyStakingVaults();

        // Verify router configuration
        _verifyRouterConfiguration();

        console2.log("");
        console2.log("========================================");
        console2.log("ALL VERIFICATIONS PASSED!");
        console2.log("========================================");
    }

    function runWithMint() external {
        console2.log("========================================");
        console2.log("PLETHER DEPLOYMENT VERIFICATION (WITH MINT)");
        console2.log("========================================");
        console2.log("");

        // Check all addresses are set
        _checkAddressesSet();

        // Verify contract state
        _verifyContractState();

        // Verify oracle prices
        _verifyOraclePrices();

        // Verify token relationships
        _verifyTokenRelationships();

        // Verify staking vaults
        _verifyStakingVaults();

        // Verify router configuration
        _verifyRouterConfiguration();

        // Test small mint flow (requires broadcast)
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        _testMintFlow();
        vm.stopBroadcast();

        console2.log("");
        console2.log("========================================");
        console2.log("ALL VERIFICATIONS PASSED!");
        console2.log("========================================");
    }

    // ==========================================
    // VERIFICATION HELPERS
    // ==========================================

    function _checkAddressesSet() internal pure {
        require(BASKET_ORACLE != address(0), "BasketOracle not set");
        require(SPLITTER != address(0), "Splitter not set");
        require(DXY_BEAR != address(0), "DXY-BEAR not set");
        require(DXY_BULL != address(0), "DXY-BULL not set");
        require(MORPHO_ORACLE_BEAR != address(0), "MorphoOracle BEAR not set");
        require(MORPHO_ORACLE_BULL != address(0), "MorphoOracle BULL not set");
        require(STAKED_BEAR != address(0), "StakedBear not set");
        require(STAKED_BULL != address(0), "StakedBull not set");
        console2.log("[OK] All addresses are set");
    }

    function _verifyContractState() internal view {
        SyntheticSplitter splitter = SyntheticSplitter(SPLITTER);

        // Check Splitter CAP
        require(splitter.CAP() == CAP, "CAP mismatch");
        console2.log("[OK] Splitter CAP correct:", CAP);

        // Check tokens are correctly set
        require(address(splitter.TOKEN_A()) == DXY_BEAR, "TOKEN_A mismatch");
        require(address(splitter.TOKEN_B()) == DXY_BULL, "TOKEN_B mismatch");
        console2.log("[OK] Splitter tokens correctly configured");

        // Check Splitter is active (not paused and not liquidated)
        require(!splitter.paused(), "Splitter is paused");
        require(!splitter.isLiquidated(), "Splitter is liquidated");
        console2.log("[OK] Splitter is in ACTIVE state");

        // Check token SPLITTER references
        require(SyntheticToken(DXY_BEAR).SPLITTER() == SPLITTER, "BEAR SPLITTER wrong");
        require(SyntheticToken(DXY_BULL).SPLITTER() == SPLITTER, "BULL SPLITTER wrong");
        console2.log("[OK] Token SPLITTER references correct");
    }

    function _verifyOraclePrices() internal view {
        // Check BasketOracle price
        BasketOracle basketOracle = BasketOracle(BASKET_ORACLE);
        (, int256 rawPrice,,,) = basketOracle.latestRoundData();
        require(rawPrice > 0, "BasketOracle price <= 0");
        uint256 price = uint256(rawPrice);

        console2.log("[OK] BasketOracle price (8 decimals):", price);
        require(price >= MIN_EXPECTED_PRICE, "Price below expected minimum");
        require(price <= MAX_EXPECTED_PRICE, "Price above expected maximum");
        console2.log("[OK] BasketOracle price within expected bounds");

        // Check MorphoOracle prices (36 decimals)
        MorphoOracle morphoOracleBear = MorphoOracle(MORPHO_ORACLE_BEAR);
        MorphoOracle morphoOracleBull = MorphoOracle(MORPHO_ORACLE_BULL);

        uint256 bearPrice = morphoOracleBear.price();
        uint256 bullPrice = morphoOracleBull.price();

        require(bearPrice > 0, "MorphoOracle BEAR price = 0");
        require(bullPrice > 0, "MorphoOracle BULL price = 0");
        console2.log("[OK] MorphoOracle BEAR price:", bearPrice);
        console2.log("[OK] MorphoOracle BULL price:", bullPrice);

        // Check StakedOracle prices
        StakedOracle stakedOracleBear = StakedOracle(STAKED_ORACLE_BEAR);
        StakedOracle stakedOracleBull = StakedOracle(STAKED_ORACLE_BULL);

        uint256 stakedBearPrice = stakedOracleBear.price();
        uint256 stakedBullPrice = stakedOracleBull.price();

        require(stakedBearPrice > 0, "StakedOracle BEAR price = 0");
        require(stakedBullPrice > 0, "StakedOracle BULL price = 0");
        console2.log("[OK] StakedOracle BEAR price:", stakedBearPrice);
        console2.log("[OK] StakedOracle BULL price:", stakedBullPrice);
    }

    function _verifyTokenRelationships() internal view {
        // Verify token names/symbols
        SyntheticToken bear = SyntheticToken(DXY_BEAR);
        SyntheticToken bull = SyntheticToken(DXY_BULL);

        require(bytes(bear.name()).length > 0, "BEAR name empty");
        require(bytes(bull.name()).length > 0, "BULL name empty");
        console2.log("[OK] BEAR token:", bear.name());
        console2.log("[OK] BULL token:", bull.name());

        // Verify decimals
        require(bear.decimals() == 18, "BEAR decimals != 18");
        require(bull.decimals() == 18, "BULL decimals != 18");
        console2.log("[OK] Token decimals are 18");
    }

    function _verifyStakingVaults() internal view {
        StakedToken stakedBear = StakedToken(STAKED_BEAR);
        StakedToken stakedBull = StakedToken(STAKED_BULL);

        // Check underlying assets
        require(stakedBear.asset() == DXY_BEAR, "StakedBear asset mismatch");
        require(stakedBull.asset() == DXY_BULL, "StakedBull asset mismatch");
        console2.log("[OK] Staked token assets correctly configured");

        // Check names
        console2.log("[OK] StakedBear:", stakedBear.name());
        console2.log("[OK] StakedBull:", stakedBull.name());

        // Check decimals match underlying
        require(stakedBear.decimals() == 18, "StakedBear decimals != 18");
        require(stakedBull.decimals() == 18, "StakedBull decimals != 18");
        console2.log("[OK] Staked token decimals are 18");
    }

    function _verifyRouterConfiguration() internal view {
        if (ZAP_ROUTER == address(0)) {
            console2.log("[SKIP] ZapRouter not deployed");
            return;
        }

        ZapRouter zapRouter = ZapRouter(ZAP_ROUTER);

        // Check ZapRouter CAP
        require(zapRouter.CAP() == CAP, "ZapRouter CAP mismatch");
        console2.log("[OK] ZapRouter CAP matches Splitter");

        // Check ZapRouter addresses
        require(address(zapRouter.SPLITTER()) == SPLITTER, "ZapRouter SPLITTER wrong");
        require(address(zapRouter.DXY_BEAR()) == DXY_BEAR, "ZapRouter DXY_BEAR wrong");
        require(address(zapRouter.DXY_BULL()) == DXY_BULL, "ZapRouter DXY_BULL wrong");
        console2.log("[OK] ZapRouter addresses correctly configured");

        if (LEVERAGE_ROUTER != address(0)) {
            console2.log("[OK] LeverageRouter deployed at:", LEVERAGE_ROUTER);
        }

        if (BULL_LEVERAGE_ROUTER != address(0)) {
            console2.log("[OK] BullLeverageRouter deployed at:", BULL_LEVERAGE_ROUTER);
        }
    }

    function _testMintFlow() internal {
        console2.log("");
        console2.log("Testing mint flow...");

        SyntheticSplitter splitter = SyntheticSplitter(SPLITTER);
        IERC20 usdc = IERC20(USDC);

        // Check balance
        address sender = msg.sender;
        uint256 usdcBalance = usdc.balanceOf(sender);
        require(usdcBalance >= USDC_TEST_AMOUNT, "Insufficient USDC for test");

        // Get preview
        (uint256 previewUsdc,,) = splitter.previewMint(MINT_TEST_AMOUNT);
        console2.log("  Preview mint USDC required:", previewUsdc);

        // Approve and mint
        usdc.approve(SPLITTER, previewUsdc);
        uint256 bearBefore = IERC20(DXY_BEAR).balanceOf(sender);
        uint256 bullBefore = IERC20(DXY_BULL).balanceOf(sender);

        splitter.mint(MINT_TEST_AMOUNT);

        uint256 bearAfter = IERC20(DXY_BEAR).balanceOf(sender);
        uint256 bullAfter = IERC20(DXY_BULL).balanceOf(sender);

        require(bearAfter == bearBefore + MINT_TEST_AMOUNT, "BEAR balance mismatch");
        require(bullAfter == bullBefore + MINT_TEST_AMOUNT, "BULL balance mismatch");

        console2.log("[OK] Mint successful - received BEAR and BULL tokens");

        // Test burn
        IERC20(DXY_BEAR).approve(SPLITTER, MINT_TEST_AMOUNT);
        IERC20(DXY_BULL).approve(SPLITTER, MINT_TEST_AMOUNT);

        uint256 usdcBefore = usdc.balanceOf(sender);
        splitter.burn(MINT_TEST_AMOUNT);
        uint256 usdcAfter = usdc.balanceOf(sender);

        require(usdcAfter > usdcBefore, "USDC not received from burn");
        console2.log("[OK] Burn successful - received USDC:", usdcAfter - usdcBefore);
    }
}
