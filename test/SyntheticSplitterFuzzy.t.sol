// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "../src/YieldAdapter.sol";
import "./utils/MockAave.sol";
import "./utils/MockOracle.sol";

contract MockUSDC is MockERC20 {
    constructor() MockERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract SyntheticSplitterFuzzTest is Test {
    SyntheticSplitter splitter;
    YieldAdapter adapter;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockPool pool;
    MockOracle oracle;
    MockOracle sequencer;

    address alice = address(0x1);
    address treasury = address(0x999);

    uint256 constant CAP = 200_000_000; // $2.00
    uint256 constant MAX_MINT_AMOUNT = 1_000_000_000 * 1e18;

    function setUp() public {
        vm.warp(1735689600);

        usdc = new MockUSDC();
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc));
        pool = new MockPool(address(usdc), address(aUsdc));
        oracle = new MockOracle(100_000_000, "Basket");
        sequencer = new MockOracle(0, "Sequencer");

        usdc.mint(address(pool), 10_000_000_000 * 1e6);

        adapter = new YieldAdapter(IERC20(address(usdc)), address(pool), address(aUsdc), address(this));

        splitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(sequencer));

        // Satisfy Sequencer Grace Period
        vm.warp(block.timestamp + 3601);
    }

    function testFuzz_Mint_MaintainsSolvency(uint256 amount) public {
        amount = bound(amount, 0.01 ether, MAX_MINT_AMOUNT);

        uint256 usdcNeeded = (amount * CAP) / splitter.USDC_MULTIPLIER();
        usdc.mint(alice, usdcNeeded + 1e6);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(amount);
        vm.stopPrank();

        uint256 totalLiabilities = (splitter.TOKEN_A().totalSupply() * CAP) / splitter.USDC_MULTIPLIER();
        uint256 localBuffer = usdc.balanceOf(address(splitter));
        uint256 adapterAssets = adapter.convertToAssets(adapter.balanceOf(address(splitter)));
        uint256 totalAssets = localBuffer + adapterAssets;

        assertGe(totalAssets + 1, totalLiabilities, "Solvency Broken");
    }

    function testFuzz_MintBurn_TokenParity(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 1 ether, MAX_MINT_AMOUNT);

        // FIX 1: Don't allow 0 burn, and don't burn more than mint
        burnAmount = bound(burnAmount, 1, mintAmount);

        uint256 cost = (mintAmount * CAP) / splitter.USDC_MULTIPLIER();
        usdc.mint(alice, cost + 1e6);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(mintAmount);

        splitter.burn(burnAmount);
        vm.stopPrank();

        assertEq(splitter.TOKEN_A().totalSupply(), splitter.TOKEN_B().totalSupply(), "Token Parity Broken");
    }

    function testFuzz_BurnWhilePaused_IfSolvent(uint256 amount) public {
        amount = bound(amount, 1 ether, MAX_MINT_AMOUNT);

        uint256 cost = (amount * CAP) / splitter.USDC_MULTIPLIER();
        usdc.mint(alice, cost + 1e6);
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(amount);
        vm.stopPrank();

        splitter.pause();

        vm.startPrank(alice);
        splitter.burn(amount);
        vm.stopPrank();

        assertEq(splitter.TOKEN_A().balanceOf(alice), 0);
    }

    function testFuzz_HarvestMath(uint96 poolLiquidity, uint96 yieldAmount) public {
        // Constrain inputs
        uint256 poolSize = bound(uint256(poolLiquidity), 100 * 1e6, 100_000_000_000 * 1e6);
        uint256 yield = bound(uint256(yieldAmount), 1 * 1e6, poolSize * 2);
        uint256 mintAmt = 10_000 * 1e18;
        uint256 cost = (mintAmt * CAP) / splitter.USDC_MULTIPLIER();
        usdc.mint(alice, cost + 1e6);

        vm.startPrank(alice);
        usdc.approve(address(splitter), cost + 1e6);
        splitter.mint(mintAmt);
        vm.stopPrank();
        // Simulate Whale
        usdc.mint(address(pool), poolSize);
        aUsdc.mint(address(this), poolSize);
        // Inject Yield
        aUsdc.mint(address(adapter), yield);
        usdc.mint(address(pool), yield);
        try splitter.harvestYield() {
        // Success is allowed (if yield > threshold)
        }
        catch Error(string memory reason) {
            // This catches standard require(..., "Reason") failures
            // We consider this a failure because we only expect "NoSurplus" or Success
            fail(string.concat("Harvest failed with string error: ", reason));
        } catch (bytes memory reason) {
            // This catches Custom Errors (like Splitter__NoSurplus)
            // Log the error selector to identify it
            console.log("Custom error selector:");
            console.logBytes4(bytes4(reason));
            // If more data in the error, log full bytes (if the error has params)
            console.log("Full error bytes:");
            console.logBytes(reason);
            // Check if the selector matches Splitter__NoSurplus
            if (bytes4(reason) != SyntheticSplitter.Splitter__NoSurplus.selector) {
                fail("Harvest failed with unexpected custom error");
            }
            // If it matches NoSurplus, the test passes (Expected behavior for low yield)
        } catch Panic(uint256 panicCode) {
            // This catches Panics (Math overflow, division by zero)
            console.log("Panic code: %d", panicCode);
            fail("Harvest crashed (Panic/Overflow)");
        }
    }
}
