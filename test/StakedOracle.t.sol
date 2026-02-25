// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StakedToken} from "../src/StakedToken.sol";
import {IOracle, StakedOracle} from "../src/oracles/StakedOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
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
        underlyingToken = new MockERC20("plDXY-BULL", "BULL");

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
        assertEq(stakedOracle.SHARE_DECIMALS(), 10 ** vault.decimals());
    }

    function test_Constructor_HandlesNonStandardDecimals() public {
        // Create 6-decimal token (like USDC)
        MockUSDC usdc = new MockUSDC();
        StakedToken usdcVault = new StakedToken(IERC20(address(usdc)), "Staked USDC", "stUSDC");
        StakedOracle usdcOracle = new StakedOracle(address(usdcVault), address(underlyingOracle));

        assertEq(usdcOracle.SHARE_DECIMALS(), 10 ** usdcVault.decimals());
    }

    // ==========================================
    // Price Calculation Tests
    // ==========================================

    function test_Price_ReturnsCorrectPriceWhenNoYield() public {
        // With 1:1 exchange rate, staked price adjusts for vault decimal offset
        // Vault has 21 decimals (18 + 3 offset), so price is scaled down by 1e3
        uint256 price = stakedOracle.price();

        uint256 oneShare = 10 ** vault.decimals();
        uint256 assetsPerShare = vault.convertToAssets(oneShare);
        uint256 expected = BASE_PRICE * assetsPerShare / oneShare;
        assertEq(price, expected);
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

        // 3. Warp to fully vest streamed rewards
        vm.warp(block.timestamp + vault.STREAM_DURATION());

        // 4. Price should increase by ~10%
        uint256 priceAfter = stakedOracle.price();

        assertGt(priceAfter, priceBefore, "Price should increase after yield donation");
        // Allow some tolerance for rounding
        assertApproxEqRel(priceAfter, (priceBefore * 110) / 100, 0.01e18); // within 1%
    }

    function test_Price_ScalesWithUnderlyingPrice() public {
        uint256 baseStakedPrice = stakedOracle.price();

        // Set underlying price to 2x
        underlyingOracle.setPrice(2 * BASE_PRICE);
        assertEq(stakedOracle.price(), 2 * baseStakedPrice);

        // Set underlying price to 0.5x
        underlyingOracle.setPrice(BASE_PRICE / 2);
        assertEq(stakedOracle.price(), baseStakedPrice / 2);
    }

    function test_Price_CombinesYieldAndPriceChange() public {
        uint256 baseStakedPrice = stakedOracle.price();

        // 1. Alice deposits
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        // 2. Add 20% yield
        underlyingToken.mint(address(this), 20 ether);
        underlyingToken.approve(address(vault), 20 ether);
        vault.donateYield(20 ether);

        // 3. Warp to fully vest streamed rewards
        vm.warp(block.timestamp + vault.STREAM_DURATION());

        // 4. Underlying price increases 50%
        underlyingOracle.setPrice((BASE_PRICE * 150) / 100);

        // Expected: 1.5 (price) * 1.2 (yield) = 1.8x base staked price
        uint256 price = stakedOracle.price();
        uint256 expectedPrice = (baseStakedPrice * 180) / 100;

        assertApproxEqRel(price, expectedPrice, 0.01e18);
    }

    // ==========================================
    // Revert Tests
    // ==========================================

    function test_Price_RevertsOnZeroUnderlyingPrice() public {
        underlyingOracle.setPrice(0);

        vm.expectRevert(StakedOracle.StakedOracle__InvalidPrice.selector);
        stakedOracle.price();
    }

    function test_Price_RevertsWhenUnderlyingOracleHasNoCode() public {
        // Simulate deployment failure: underlying oracle address has no contract code.
        // This can happen when:
        // - Deployment script didn't complete
        // - Anvil/node was restarted and state was lost
        // - Wrong address was configured
        address noCodeAddress = address(0xDEAD);

        // Create StakedOracle with a non-contract address as oracle
        StakedOracle brokenOracle = new StakedOracle(address(vault), noCodeAddress);

        // Calling price() should revert because the external call to a non-contract
        // returns empty data, which fails abi.decode expectations
        vm.expectRevert();
        brokenOracle.price();
    }

    function test_Constructor_RevertsOnZeroVaultAddress() public {
        vm.expectRevert(StakedOracle.StakedOracle__ZeroAddress.selector);
        new StakedOracle(address(0), address(underlyingOracle));
    }

    function test_Constructor_RevertsOnZeroOracleAddress() public {
        vm.expectRevert(StakedOracle.StakedOracle__ZeroAddress.selector);
        new StakedOracle(address(vault), address(0));
    }

    // ==========================================
    // Edge Case Tests
    // ==========================================

    function test_Price_WorksWithLargeAmounts() public {
        uint256 priceEmpty = stakedOracle.price();

        underlyingToken.mint(alice, 1_000_000_000 ether);

        vm.startPrank(alice);
        underlyingToken.approve(address(vault), 1_000_000_000 ether);
        vault.deposit(1_000_000_000 ether, alice);
        vm.stopPrank();

        assertEq(stakedOracle.price(), priceEmpty, "Price unchanged (1:1 exchange rate, no yield)");
    }

    function test_Price_WorksWithSmallAmounts() public {
        uint256 priceEmpty = stakedOracle.price();

        vm.startPrank(alice);
        underlyingToken.approve(address(vault), 1);
        vault.deposit(1, alice);
        vm.stopPrank();

        assertEq(stakedOracle.price(), priceEmpty, "Price unchanged (1:1 exchange rate, no yield)");
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
