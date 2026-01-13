// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StakedToken} from "../src/StakedToken.sol";
import {IOracle, StakedOracle} from "../src/oracles/StakedOracle.sol";
import {MockERC20} from "./utils/MockAave.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Mock oracle that implements IOracle interface
contract MockUnderlyingOracle is IOracle {

    uint256 public mockPrice;

    constructor(
        uint256 _price
    ) {
        mockPrice = _price;
    }

    function price() external view override returns (uint256) {
        return mockPrice;
    }

    function setPrice(
        uint256 _price
    ) external {
        mockPrice = _price;
    }

}

contract StakedOracleTest is Test {

    StakedOracle public stakedOracle;
    StakedToken public vault;
    MockUnderlyingOracle public underlyingOracle;
    MockERC20 public underlyingToken;

    address alice = address(0xA11CE);

    // Morpho-style price scaling (1e36)
    uint256 constant BASE_PRICE = 1e36;

    function setUp() public {
        // 1. Deploy underlying token (18 decimals)
        underlyingToken = new MockERC20("DXY-BULL", "BULL");

        // 2. Deploy ERC-4626 vault
        vault = new StakedToken(IERC20(address(underlyingToken)), "Staked BULL", "stBULL");

        // 3. Deploy mock underlying oracle with base price
        underlyingOracle = new MockUnderlyingOracle(BASE_PRICE);

        // 4. Deploy StakedOracle
        stakedOracle = new StakedOracle(address(vault), address(underlyingOracle));

        // 5. Fund alice
        underlyingToken.mint(alice, 1_000_000 ether);
    }

    // ==========================================
    // Constructor Tests
    // ==========================================

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(stakedOracle.VAULT()), address(vault));
        assertEq(address(stakedOracle.UNDERLYING_ORACLE()), address(underlyingOracle));
        assertEq(stakedOracle.UNDERLYING_DECIMALS(), 1e18); // 18 decimal token
    }

    function test_Constructor_HandlesNonStandardDecimals() public {
        // Create 6-decimal token (like USDC)
        MockUSDC usdc = new MockUSDC();
        StakedToken usdcVault = new StakedToken(IERC20(address(usdc)), "Staked USDC", "stUSDC");
        StakedOracle usdcOracle = new StakedOracle(address(usdcVault), address(underlyingOracle));

        assertEq(usdcOracle.UNDERLYING_DECIMALS(), 1e6);
    }

    // ==========================================
    // Price Calculation Tests
    // ==========================================

    function test_Price_ReturnsUnderlyingPriceWhenNoYield() public {
        // When vault has no deposits, exchange rate is 1:1
        // Price should equal underlying oracle price
        uint256 price = stakedOracle.price();

        // With no deposits, convertToAssets(1e18) returns 1e18 (1:1 ratio)
        // So price = BASE_PRICE * 1e18 / 1e18 = BASE_PRICE
        assertEq(price, BASE_PRICE);
    }

    function test_Price_IncreasesWithYield() public {
        // 1. Alice deposits into vault
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        // Initial price (1:1 exchange rate, accounting for offset)
        uint256 priceBefore = stakedOracle.price();

        // 2. Donate 10% yield to vault
        underlyingToken.mint(address(this), 10 ether);
        underlyingToken.approve(address(vault), 10 ether);
        vault.donateYield(10 ether);

        // 3. Price should increase by ~10%
        uint256 priceAfter = stakedOracle.price();

        assertGt(priceAfter, priceBefore, "Price should increase after yield donation");
        // Allow some tolerance for rounding
        assertApproxEqRel(priceAfter, (priceBefore * 110) / 100, 0.01e18); // within 1%
    }

    function test_Price_ScalesWithUnderlyingPrice() public {
        // Test that staked price scales proportionally with underlying price

        // Set underlying price to 2x
        underlyingOracle.setPrice(2 * BASE_PRICE);

        uint256 price = stakedOracle.price();
        assertEq(price, 2 * BASE_PRICE);

        // Set underlying price to 0.5x
        underlyingOracle.setPrice(BASE_PRICE / 2);

        price = stakedOracle.price();
        assertEq(price, BASE_PRICE / 2);
    }

    function test_Price_CombinesYieldAndPriceChange() public {
        // 1. Alice deposits
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        // 2. Add 20% yield
        underlyingToken.mint(address(this), 20 ether);
        underlyingToken.approve(address(vault), 20 ether);
        vault.donateYield(20 ether);

        // 3. Underlying price increases 50%
        underlyingOracle.setPrice((BASE_PRICE * 150) / 100);

        // Expected: 1.5 * 1.2 = 1.8x original price
        uint256 price = stakedOracle.price();
        uint256 expectedPrice = (BASE_PRICE * 180) / 100;

        assertApproxEqRel(price, expectedPrice, 0.01e18); // within 1%
    }

    // ==========================================
    // Revert Tests
    // ==========================================

    function test_Price_RevertsOnZeroUnderlyingPrice() public {
        underlyingOracle.setPrice(0);

        vm.expectRevert(StakedOracle.StakedOracle__InvalidPrice.selector);
        stakedOracle.price();
    }

    // ==========================================
    // Edge Case Tests
    // ==========================================

    function test_Price_WorksWithLargeAmounts() public {
        // Deposit large amount
        underlyingToken.mint(alice, 1_000_000_000 ether);

        vm.startPrank(alice);
        underlyingToken.approve(address(vault), 1_000_000_000 ether);
        vault.deposit(1_000_000_000 ether, alice);
        vm.stopPrank();

        // Should not overflow
        uint256 price = stakedOracle.price();
        assertGt(price, 0);
    }

    function test_Price_WorksWithSmallAmounts() public {
        // Deposit small amount
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), 1);
        vault.deposit(1, alice);
        vm.stopPrank();

        // Should still work
        uint256 price = stakedOracle.price();
        assertGt(price, 0);
    }

    function test_Price_ConsistentAcrossMultipleDeposits() public {
        // Multiple users deposit
        address bob = address(0xB0B);
        underlyingToken.mint(bob, 100 ether);

        vm.prank(alice);
        underlyingToken.approve(address(vault), 50 ether);
        vm.prank(alice);
        vault.deposit(50 ether, alice);

        uint256 priceAfterAlice = stakedOracle.price();

        vm.prank(bob);
        underlyingToken.approve(address(vault), 100 ether);
        vm.prank(bob);
        vault.deposit(100 ether, bob);

        uint256 priceAfterBob = stakedOracle.price();

        // Price should remain same (no yield added)
        assertEq(priceAfterAlice, priceAfterBob);
    }

}

/// @notice Mock USDC with 6 decimals
contract MockUSDC is MockERC20 {

    constructor() MockERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

}
