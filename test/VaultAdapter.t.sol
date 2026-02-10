// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultAdapter} from "../src/VaultAdapter.sol";
import {MockERC20} from "./utils/MockAave.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC6 is MockERC20 {

    constructor() MockERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

}

contract MockERC4626Vault is ERC4626 {

    constructor(
        IERC20 _asset
    ) ERC4626(_asset) ERC20("Mock Vault", "mVault") {}

    function simulateYield(
        uint256 amount
    ) external {
        MockERC20(asset()).mint(address(this), amount);
    }

}

contract VaultAdapterTest is Test {

    VaultAdapter adapter;

    MockUSDC6 usdc;
    MockERC4626Vault vault;

    address owner = address(0xAAAA);
    address splitter = address(0xBBBB);
    address hacker = address(0x666);

    function setUp() public {
        usdc = new MockUSDC6();
        vault = new MockERC4626Vault(IERC20(address(usdc)));

        adapter = new VaultAdapter(IERC20(address(usdc)), address(vault), owner, splitter);

        usdc.mint(splitter, 1000 * 1e6);
    }

    // ==========================================
    // 1. Deposit / Withdraw Core Flow
    // ==========================================

    function test_Deposit_ForwardsToVault() public {
        uint256 amount = 100 * 1e6;

        vm.startPrank(splitter);
        usdc.approve(address(adapter), amount);
        uint256 shares = adapter.deposit(amount, splitter);
        vm.stopPrank();

        assertEq(shares, amount);
        assertEq(adapter.balanceOf(splitter), amount);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(adapter.totalAssets(), amount);
    }

    function test_Withdraw_PullsFromVault() public {
        uint256 amount = 100 * 1e6;

        vm.startPrank(splitter);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount, splitter);

        uint256 withdrawAmount = 50 * 1e6;
        adapter.withdraw(withdrawAmount, splitter, splitter);
        vm.stopPrank();

        assertEq(usdc.balanceOf(splitter), 950 * 1e6);
        assertEq(adapter.balanceOf(splitter), 50 * 1e6);
        assertEq(adapter.totalAssets(), 50 * 1e6);
    }

    function test_Redeem_ReturnsAllAssets() public {
        uint256 amount = 100 * 1e6;

        vm.startPrank(splitter);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount, splitter);

        adapter.redeem(adapter.balanceOf(splitter), splitter, splitter);
        vm.stopPrank();

        assertEq(usdc.balanceOf(splitter), 1000 * 1e6);
        assertEq(adapter.totalAssets(), 0);
    }

    // ==========================================
    // 2. Yield Accrual
    // ==========================================

    function test_TotalAssets_IncreasesWithYield() public {
        uint256 amount = 100 * 1e6;

        vm.startPrank(splitter);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount, splitter);
        vm.stopPrank();

        vault.simulateYield(10 * 1e6);

        assertApproxEqAbs(adapter.totalAssets(), 110 * 1e6, 1);

        vm.startPrank(splitter);
        adapter.redeem(adapter.balanceOf(splitter), splitter, splitter);
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(splitter), 1010 * 1e6, 2);
    }

    // ==========================================
    // 3. Access Control
    // ==========================================

    function test_Deposit_OnlySplitter() public {
        usdc.mint(hacker, 1000 * 1e6);

        vm.startPrank(hacker);
        usdc.approve(address(adapter), 1000 * 1e6);
        vm.expectRevert(VaultAdapter.VaultAdapter__OnlySplitter.selector);
        adapter.deposit(1000 * 1e6, hacker);
        vm.stopPrank();
    }

    // ==========================================
    // 4. Rescue Token
    // ==========================================

    function test_RescueToken_BlocksUnderlying() public {
        vm.prank(owner);
        vm.expectRevert(VaultAdapter.VaultAdapter__CannotRescueUnderlying.selector);
        adapter.rescueToken(address(usdc), owner);
    }

    function test_RescueToken_BlocksVaultShares() public {
        vm.prank(owner);
        vm.expectRevert(VaultAdapter.VaultAdapter__CannotRescueVaultShares.selector);
        adapter.rescueToken(address(vault), owner);
    }

    function test_RescueToken_AllowsRandomToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND");
        randomToken.mint(address(adapter), 500 ether);

        vm.prank(owner);
        adapter.rescueToken(address(randomToken), owner);

        assertEq(randomToken.balanceOf(owner), 500 ether);
    }

    // ==========================================
    // 5. Constructor Validation
    // ==========================================

    function test_Constructor_RevertsOnZeroVault() public {
        vm.expectRevert(VaultAdapter.VaultAdapter__InvalidAddress.selector);
        new VaultAdapter(IERC20(address(usdc)), address(0), owner, splitter);
    }

    function test_Constructor_RevertsOnZeroSplitter() public {
        vm.expectRevert(VaultAdapter.VaultAdapter__InvalidAddress.selector);
        new VaultAdapter(IERC20(address(usdc)), address(vault), owner, address(0));
    }

    function test_Constructor_RevertsOnAssetMismatch() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH");
        vm.expectRevert(VaultAdapter.VaultAdapter__InvalidVault.selector);
        new VaultAdapter(IERC20(address(otherToken)), address(vault), owner, splitter);
    }

    // ==========================================
    // 6. accrueInterest No-Op
    // ==========================================

    function test_AccrueInterest_DoesNotRevert() public {
        adapter.accrueInterest();
    }

}
