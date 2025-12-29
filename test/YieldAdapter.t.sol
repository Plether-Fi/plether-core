// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/YieldAdapter.sol";
import "./utils/MockAave.sol";

// Simple Mock USDC for testing (6 decimals standard)
contract MockUSDC is MockERC20 {
    constructor() MockERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// Mock Reward Token
contract MockRewardToken is MockERC20 {
    constructor() MockERC20("Aave Token", "AAVE") {}
}

// Mock Aave RewardsController
contract MockRewardsController is IRewardsController {
    MockRewardToken public rewardToken;
    uint256 public pendingRewards;

    constructor(address _rewardToken) {
        rewardToken = MockRewardToken(_rewardToken);
    }

    function setPendingRewards(uint256 amount) external {
        pendingRewards = amount;
    }

    function getAllUserRewards(address[] calldata, address)
        external
        view
        override
        returns (address[] memory rewardsList, uint256[] memory unclaimedAmounts)
    {
        rewardsList = new address[](1);
        rewardsList[0] = address(rewardToken);
        unclaimedAmounts = new uint256[](1);
        unclaimedAmounts[0] = pendingRewards;
    }

    function claimRewards(address[] calldata, uint256, address to, address)
        external
        override
        returns (uint256)
    {
        uint256 amount = pendingRewards;
        pendingRewards = 0;
        rewardToken.mint(to, amount);
        return amount;
    }
}

contract YieldAdapterTest is Test {
    YieldAdapter adapter;

    // Mocks
    MockUSDC usdc;
    MockAToken aUsdc;
    MockPool pool;

    address owner = address(0xAAAA);
    address user = address(0xBBBB);
    address hacker = address(0x666);

    function setUp() public {
        // 1. Deploy Mocks
        usdc = new MockUSDC();
        // Note: MockAToken takes (name, symbol, underlyingAddress)
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc));
        pool = new MockPool(address(usdc), address(aUsdc));

        // 2. Fund the Pool (So it can pay back withdrawals)
        usdc.mint(address(pool), 1_000_000 * 1e6);

        // 3. Deploy Adapter (user is set as splitter for testing deposits)
        vm.prank(owner);
        adapter = new YieldAdapter(IERC20(address(usdc)), address(pool), address(aUsdc), owner, user);

        // 4. Fund User
        usdc.mint(user, 1000 * 1e6); // $1000 USDC
    }

    // ==========================================
    // 1. ERC-4626 Core Flow (Deposit/Withdraw)
    // ==========================================

    function test_Deposit_SuppliesToAave() public {
        uint256 amount = 100 * 1e6;

        vm.startPrank(user);

        // Approve adapter to spend user's USDC
        usdc.approve(address(adapter), amount);

        // Act: Deposit into Vault
        uint256 shares = adapter.deposit(amount, user);

        vm.stopPrank();

        // Check 1: User got shares (1:1 in this mock scenario)
        assertEq(shares, amount);
        assertEq(adapter.balanceOf(user), amount);

        // Check 2: Adapter holds NO USDC (It pushed it to Aave)
        assertEq(usdc.balanceOf(address(adapter)), 0);

        // Check 3: Adapter holds aUSDC (Receipt from Aave)
        assertEq(aUsdc.balanceOf(address(adapter)), amount);

        // Check 4: totalAssets() reflects the aToken balance
        assertEq(adapter.totalAssets(), amount);
    }

    function test_Withdraw_PullsFromAave() public {
        uint256 amount = 100 * 1e6;

        // Setup: Deposit first
        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount, user);

        // Act: Withdraw half
        uint256 withdrawAmount = 50 * 1e6;
        adapter.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Check 1: User got USDC back
        // Start 1000 -> Dep 100 (900 left) -> With 50 (950 total)
        assertEq(usdc.balanceOf(user), 950 * 1e6);

        // Check 2: Adapter burned shares
        assertEq(adapter.balanceOf(user), 50 * 1e6);

        // Check 3: Adapter still has correct aToken balance
        assertEq(aUsdc.balanceOf(address(adapter)), 50 * 1e6);
    }

    function test_Redeem_WorksSameAsWithdraw() public {
        // Redeem is share-based withdrawal
        uint256 amount = 100 * 1e6;

        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount, user);

        // Act: Redeem all shares
        uint256 shares = adapter.balanceOf(user);
        adapter.redeem(shares, user, user);
        vm.stopPrank();

        // Check: User has full balance back
        assertEq(usdc.balanceOf(user), 1000 * 1e6);
        assertEq(adapter.totalAssets(), 0);
    }

    // ==========================================
    // 2. Yield Accumulation Logic
    // ==========================================

    function test_TotalAssets_IncreasesWithYield() public {
        uint256 amount = 100 * 1e6;

        // 1. User Deposits
        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount, user);
        vm.stopPrank();

        // 2. Simulate Interest: Aave Pool gives 10 USDC yield
        // We simulate this by minting aUSDC directly to the adapter
        // (In real life, Aave rebases everyone's balance up)
        aUsdc.mint(address(adapter), 10 * 1e6);

        // Check: Total Assets should now be 110
        assertEq(adapter.totalAssets(), 110 * 1e6);

        // 3. User Withdraws Everything
        // Since shares are 100, but assets are 110, exchange rate changed.
        vm.startPrank(user);
        adapter.redeem(100 * 1e6, user, user);
        vm.stopPrank();

        // Check: User got Principal + Yield (Allowing for 1 wei rounding loss due to OZ v5 security)
        assertApproxEqAbs(usdc.balanceOf(user), 1010 * 1e6, 1);
    }

    // ==========================================
    // 3. Security Tests
    // ==========================================

    function test_RescueToken_CannotStealCollateral() public {
        vm.startPrank(owner);

        // 1. Try to rescue USDC (Underlying) -> Revert
        vm.expectRevert("Cannot rescue Underlying");
        adapter.rescueToken(address(usdc), owner);

        // 2. Try to rescue aUSDC (Asset backing) -> Revert
        vm.expectRevert("Cannot rescue aTokens");
        adapter.rescueToken(address(aUsdc), owner);

        vm.stopPrank();
    }

    function test_RescueToken_SuccessForRandomToken() public {
        // 1. Send random tokens to adapter
        MockERC20 randomToken = new MockERC20("Random", "RND");
        randomToken.mint(address(adapter), 500 ether);

        // 2. Rescue
        vm.startPrank(owner);
        adapter.rescueToken(address(randomToken), owner);
        vm.stopPrank();

        // Check: Owner got them
        assertEq(randomToken.balanceOf(owner), 500 ether);
    }

    function test_RescueToken_OnlyOwner() public {
        MockERC20 randomToken = new MockERC20("Random", "RND");

        vm.startPrank(hacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hacker));
        adapter.rescueToken(address(randomToken), hacker);
        vm.stopPrank();
    }

    function test_Deposit_OnlySplitter() public {
        // Hacker tries to deposit directly (inflation attack attempt)
        usdc.mint(hacker, 1000 * 1e6);

        vm.startPrank(hacker);
        usdc.approve(address(adapter), 1000 * 1e6);

        vm.expectRevert(YieldAdapter.YieldAdapter__OnlySplitter.selector);
        adapter.deposit(1000 * 1e6, hacker);
        vm.stopPrank();
    }

    function test_Splitter_IsImmutable() public view {
        // Verify SPLITTER is set correctly and cannot be changed
        assertEq(adapter.SPLITTER(), user);
    }

    // ==========================================
    // 4. Rewards Tests
    // ==========================================

    function test_SetRewardsController_Success() public {
        MockRewardToken rewardToken = new MockRewardToken();
        MockRewardsController controller = new MockRewardsController(address(rewardToken));

        vm.prank(owner);
        adapter.setRewardsController(address(controller));

        assertEq(address(adapter.rewardsController()), address(controller));
    }

    function test_SetRewardsController_OnlyOwner() public {
        MockRewardToken rewardToken = new MockRewardToken();
        MockRewardsController controller = new MockRewardsController(address(rewardToken));

        vm.prank(hacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hacker));
        adapter.setRewardsController(address(controller));
    }

    function test_GetPendingRewards_ReturnsEmptyIfNoController() public view {
        (address[] memory rewardsList, uint256[] memory amounts) = adapter.getPendingRewards();

        assertEq(rewardsList.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_GetPendingRewards_ReturnsRewardsIfSet() public {
        MockRewardToken rewardToken = new MockRewardToken();
        MockRewardsController controller = new MockRewardsController(address(rewardToken));

        vm.prank(owner);
        adapter.setRewardsController(address(controller));

        // Set pending rewards
        controller.setPendingRewards(100 ether);

        (address[] memory rewardsList, uint256[] memory amounts) = adapter.getPendingRewards();

        assertEq(rewardsList.length, 1);
        assertEq(rewardsList[0], address(rewardToken));
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 100 ether);
    }

    function test_ClaimRewards_Success() public {
        MockRewardToken rewardToken = new MockRewardToken();
        MockRewardsController controller = new MockRewardsController(address(rewardToken));

        vm.prank(owner);
        adapter.setRewardsController(address(controller));

        // Set pending rewards
        controller.setPendingRewards(100 ether);

        address treasury = address(0x999);

        vm.prank(owner);
        uint256 claimed = adapter.claimRewards(address(rewardToken), treasury);

        assertEq(claimed, 100 ether);
        assertEq(rewardToken.balanceOf(treasury), 100 ether);

        // Verify rewards are now 0
        (address[] memory rewardsList, uint256[] memory amounts) = adapter.getPendingRewards();
        assertEq(amounts[0], 0);
    }

    function test_ClaimRewards_OnlyOwner() public {
        MockRewardToken rewardToken = new MockRewardToken();
        MockRewardsController controller = new MockRewardsController(address(rewardToken));

        vm.prank(owner);
        adapter.setRewardsController(address(controller));

        vm.prank(hacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hacker));
        adapter.claimRewards(address(rewardToken), hacker);
    }

    function test_ClaimRewards_RevertsIfNoController() public {
        vm.prank(owner);
        vm.expectRevert(YieldAdapter.YieldAdapter__InvalidAddress.selector);
        adapter.claimRewards(address(0x123), owner);
    }

    function test_ClaimRewards_RevertsIfZeroRecipient() public {
        MockRewardToken rewardToken = new MockRewardToken();
        MockRewardsController controller = new MockRewardsController(address(rewardToken));

        vm.startPrank(owner);
        adapter.setRewardsController(address(controller));

        vm.expectRevert(YieldAdapter.YieldAdapter__InvalidAddress.selector);
        adapter.claimRewards(address(rewardToken), address(0));
        vm.stopPrank();
    }
}
