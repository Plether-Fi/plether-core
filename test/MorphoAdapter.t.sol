// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniversalRewardsDistributor, MorphoAdapter} from "../src/MorphoAdapter.sol";
import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {MockERC20} from "./utils/MockAave.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

// Simple Mock USDC for testing (6 decimals standard)
contract MockUSDC is MockERC20 {

    constructor() MockERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

}

// Mock Morpho Blue
contract MockMorpho is IMorpho {

    mapping(bytes32 => mapping(address => uint256)) public supplyShares;
    mapping(bytes32 => uint256) public totalSupplyAssets;
    mapping(bytes32 => uint256) public totalSupplyShares;

    IERC20 public loanToken;

    constructor(
        address _loanToken
    ) {
        loanToken = IERC20(_loanToken);
    }

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256, // shares (unused, we use assets mode)
        address onBehalf,
        bytes calldata
    ) external override returns (uint256 assetsSupplied, uint256 sharesSupplied) {
        bytes32 id = keccak256(abi.encode(marketParams));

        // Pull tokens
        loanToken.transferFrom(msg.sender, address(this), assets);

        // Calculate shares (1:1 for simplicity, or proportional if pool exists)
        if (totalSupplyShares[id] == 0) {
            sharesSupplied = assets;
        } else {
            sharesSupplied = (assets * totalSupplyShares[id]) / totalSupplyAssets[id];
        }

        supplyShares[id][onBehalf] += sharesSupplied;
        totalSupplyAssets[id] += assets;
        totalSupplyShares[id] += sharesSupplied;

        return (assets, sharesSupplied);
    }

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256, // shares (unused)
        address onBehalf,
        address receiver
    ) external virtual override returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn) {
        bytes32 id = keccak256(abi.encode(marketParams));

        // Calculate shares to burn
        sharesWithdrawn = (assets * totalSupplyShares[id]) / totalSupplyAssets[id];

        require(supplyShares[id][onBehalf] >= sharesWithdrawn, "Insufficient shares");

        supplyShares[id][onBehalf] -= sharesWithdrawn;
        totalSupplyAssets[id] -= assets;
        totalSupplyShares[id] -= sharesWithdrawn;

        // Transfer tokens
        loanToken.transfer(receiver, assets);

        return (assets, sharesWithdrawn);
    }

    function position(
        bytes32 id,
        address user
    ) external view override returns (uint256, uint128, uint128) {
        return (supplyShares[id][user], 0, 0);
    }

    function market(
        bytes32 id
    )
        external
        view
        override
        returns (
            uint128 _totalSupplyAssets,
            uint128 _totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        )
    {
        return (uint128(totalSupplyAssets[id]), uint128(totalSupplyShares[id]), 0, 0, uint128(block.timestamp), 0);
    }

    // Stubs for interface compliance (not used by MorphoAdapter)
    function borrow(
        MarketParams memory,
        uint256,
        uint256,
        address,
        address
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function repay(
        MarketParams memory,
        uint256,
        uint256,
        address,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function isAuthorized(
        address,
        address
    ) external pure override returns (bool) {
        return false;
    }

    function setAuthorization(
        address,
        bool
    ) external override {}

    function createMarket(
        MarketParams memory
    ) external override {}

    function idToMarketParams(
        bytes32
    ) external pure override returns (MarketParams memory) {
        return MarketParams(address(0), address(0), address(0), address(0), 0);
    }

    function supplyCollateral(
        MarketParams memory,
        uint256,
        address,
        bytes calldata
    ) external override {}

    function withdrawCollateral(
        MarketParams memory,
        uint256,
        address,
        address
    ) external override {}

    function accrueInterest(
        MarketParams memory
    ) external override {}

    function liquidate(
        MarketParams memory,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function flashLoan(
        address,
        uint256,
        bytes calldata
    ) external override {
        // Not used by MorphoAdapter
    }

    // Helper: Simulate yield by increasing totalSupplyAssets
    function simulateYield(
        bytes32 id,
        uint256 yieldAmount
    ) external {
        totalSupplyAssets[id] += yieldAmount;
        // Mint tokens to back the yield
        MockERC20(address(loanToken)).mint(address(this), yieldAmount);
    }

}

// Mock Universal Rewards Distributor
contract MockURD is IUniversalRewardsDistributor {

    MockERC20 public rewardToken;
    mapping(address => uint256) public claimed;

    constructor(
        address _rewardToken
    ) {
        rewardToken = MockERC20(_rewardToken);
    }

    function claim(
        address account,
        address reward,
        uint256 claimable,
        bytes32[] calldata // proof (ignored in mock)
    ) external returns (uint256 amount) {
        // In real URD, this verifies merkle proof
        // For testing, we just check claimable > claimed
        uint256 alreadyClaimed = claimed[account];
        require(claimable > alreadyClaimed, "Nothing to claim");

        amount = claimable - alreadyClaimed;
        claimed[account] = claimable;

        // Mint reward tokens to caller (the adapter)
        rewardToken.mint(msg.sender, amount);

        return amount;
    }

}

// Mock Reward Token
contract MockRewardToken is MockERC20 {

    constructor() MockERC20("Morpho Token", "MORPHO") {}

}

contract PartialWithdrawMorpho is MockMorpho {

    uint256 public shortfall;

    constructor(
        address _loanToken
    ) MockMorpho(_loanToken) {}

    function setShortfall(
        uint256 _shortfall
    ) external {
        shortfall = _shortfall;
    }

    function withdraw(
        MarketParams memory _marketParams,
        uint256 assets,
        uint256,
        address onBehalf,
        address receiver
    ) external override returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn) {
        bytes32 id = keccak256(abi.encode(_marketParams));

        sharesWithdrawn = (assets * totalSupplyShares[id]) / totalSupplyAssets[id];
        require(supplyShares[id][onBehalf] >= sharesWithdrawn, "Insufficient shares");

        supplyShares[id][onBehalf] -= sharesWithdrawn;
        totalSupplyAssets[id] -= assets;
        totalSupplyShares[id] -= sharesWithdrawn;

        assetsWithdrawn = assets - shortfall;
        loanToken.transfer(receiver, assetsWithdrawn);
    }

}

contract MorphoAdapterTest is Test {

    MorphoAdapter adapter;

    // Mocks
    MockUSDC usdc;
    MockMorpho morpho;
    MockRewardToken rewardToken;
    MockURD urd;

    MarketParams marketParams;
    bytes32 marketId;

    address owner = address(0xAAAA);
    address user = address(0xBBBB); // Acts as SPLITTER
    address hacker = address(0x666);
    address treasury = address(0x999);

    function setUp() public {
        // 1. Deploy Mocks
        usdc = new MockUSDC();
        morpho = new MockMorpho(address(usdc));
        rewardToken = new MockRewardToken();
        urd = new MockURD(address(rewardToken));

        // 2. Fund the Morpho pool (so withdrawals work)
        usdc.mint(address(morpho), 1_000_000 * 1e6);

        // 3. Setup market params
        marketParams = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0x1), // Dummy
            oracle: address(0x2),
            irm: address(0x3),
            lltv: 0.9e18
        });
        marketId = keccak256(abi.encode(marketParams));

        // 4. Deploy Adapter (user is set as splitter for testing deposits)
        vm.prank(owner);
        adapter = new MorphoAdapter(IERC20(address(usdc)), address(morpho), marketParams, owner, user);

        // 5. Fund User
        usdc.mint(user, 1000 * 1e6);
    }

    // ==========================================
    // 1. ERC-4626 Core Flow (Deposit/Withdraw)
    // ==========================================

    function test_Deposit_SuppliesToMorpho() public {
        uint256 amount = 100 * 1e6;

        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        uint256 shares = adapter.deposit(amount, user);
        vm.stopPrank();

        // Check 1: User got shares (1:1 in this mock scenario)
        assertEq(shares, amount);
        assertEq(adapter.balanceOf(user), amount);

        // Check 2: Adapter holds NO USDC (pushed to Morpho)
        assertEq(usdc.balanceOf(address(adapter)), 0);

        // Check 3: totalAssets() reflects the Morpho position
        assertEq(adapter.totalAssets(), amount);
    }

    function test_Withdraw_PullsFromMorpho() public {
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
        assertEq(usdc.balanceOf(user), 950 * 1e6);

        // Check 2: Adapter burned shares
        assertEq(adapter.balanceOf(user), 50 * 1e6);

        // Check 3: totalAssets decreased
        assertEq(adapter.totalAssets(), 50 * 1e6);
    }

    function test_Redeem_WorksSameAsWithdraw() public {
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

        // 2. Simulate yield in Morpho
        morpho.simulateYield(marketId, 10 * 1e6);

        // Check: Total Assets should now be 110
        assertEq(adapter.totalAssets(), 110 * 1e6);

        // 3. User Withdraws Everything
        vm.startPrank(user);
        adapter.redeem(100 * 1e6, user, user);
        vm.stopPrank();

        // Check: User got Principal + Yield (allow 1 wei rounding)
        assertApproxEqAbs(usdc.balanceOf(user), 1010 * 1e6, 1);
    }

    function test_DepositAfterYield_SharePriceAboveOne() public {
        // Alice deposits $100 into an empty pool → gets 100e6 shares (1:1)
        address alice = address(0xA11CE);
        usdc.mint(user, 200 * 1e6);

        vm.startPrank(user);
        usdc.approve(address(adapter), type(uint256).max);
        adapter.deposit(100 * 1e6, alice);
        vm.stopPrank();

        assertEq(adapter.balanceOf(alice), 100 * 1e6);

        // Yield accrues: pool is now worth $110 backed by 100e6 shares
        // Share price = 110/100 = $1.10
        morpho.simulateYield(marketId, 10 * 1e6);
        assertEq(adapter.totalAssets(), 110 * 1e6);

        // Bob deposits $55 at $1.10/share → expects 50e6 shares (55/1.10 = 50)
        address bob = address(0xB0B);
        usdc.mint(user, 55 * 1e6);

        vm.startPrank(user);
        uint256 bobShares = adapter.deposit(55 * 1e6, bob);
        vm.stopPrank();

        assertEq(bobShares, 50 * 1e6, "Bob should get 50e6 shares at $1.10/share");
        assertEq(adapter.totalAssets(), 165 * 1e6, "Pool should hold $165 total");
    }

    function test_TwoDepositors_YieldSplitProportionally() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        usdc.mint(user, 500 * 1e6);

        // Alice deposits $100, Bob deposits $200 (same share price, 1:1)
        vm.startPrank(user);
        usdc.approve(address(adapter), type(uint256).max);
        adapter.deposit(100 * 1e6, alice);
        adapter.deposit(200 * 1e6, bob);
        vm.stopPrank();

        assertEq(adapter.balanceOf(alice), 100 * 1e6);
        assertEq(adapter.balanceOf(bob), 200 * 1e6);

        // $30 yield accrues → pool is $330 backed by 300e6 shares
        // Alice owns 1/3 → entitled to $110
        // Bob owns 2/3 → entitled to $220
        morpho.simulateYield(marketId, 30 * 1e6);
        assertEq(adapter.totalAssets(), 330 * 1e6);

        // Alice redeems all (1 wei rounding from integer division in share→asset)
        vm.prank(alice);
        adapter.redeem(100 * 1e6, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 110 * 1e6, 1, "Alice should get ~$110 (principal + 1/3 yield)");

        // Bob redeems all
        vm.prank(bob);
        adapter.redeem(200 * 1e6, bob, bob);
        assertApproxEqAbs(usdc.balanceOf(bob), 220 * 1e6, 1, "Bob should get ~$220 (principal + 2/3 yield)");

        assertLe(adapter.totalAssets(), 1, "Pool should be empty (1 wei rounding dust)");
    }

    function test_DepositAfterYield_WithdrawReturnsCorrectAmount() public {
        address alice = address(0xA11CE);
        usdc.mint(user, 300 * 1e6);

        // Alice deposits $200
        vm.startPrank(user);
        usdc.approve(address(adapter), type(uint256).max);
        adapter.deposit(200 * 1e6, alice);
        vm.stopPrank();

        // 50% yield → pool worth $300, still 200e6 shares, price = $1.50/share
        morpho.simulateYield(marketId, 100 * 1e6);

        // Bob deposits $150 → gets 100e6 shares (150/1.50 = 100)
        address bob = address(0xB0B);
        usdc.mint(user, 150 * 1e6);

        vm.startPrank(user);
        uint256 bobShares = adapter.deposit(150 * 1e6, bob);
        vm.stopPrank();

        assertEq(bobShares, 100 * 1e6, "Bob gets 100e6 shares at $1.50");
        assertEq(adapter.totalAssets(), 450 * 1e6);

        // Alice withdraws ~$300 (her 200 shares × $1.50, 1 wei rounding)
        vm.prank(alice);
        adapter.redeem(200 * 1e6, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 300 * 1e6, 1, "Alice gets ~$300 (200 shares at $1.50)");

        // Bob withdraws $150 (his 100 shares × $1.50)
        vm.prank(bob);
        adapter.redeem(100 * 1e6, bob, bob);
        assertApproxEqAbs(usdc.balanceOf(bob), 150 * 1e6, 1, "Bob gets ~$150 (100 shares at $1.50)");
    }

    // ==========================================
    // 3. Security Tests
    // ==========================================

    function test_Deposit_OnlySplitter() public {
        usdc.mint(hacker, 1000 * 1e6);

        vm.startPrank(hacker);
        usdc.approve(address(adapter), 1000 * 1e6);

        vm.expectRevert(MorphoAdapter.MorphoAdapter__OnlySplitter.selector);
        adapter.deposit(1000 * 1e6, hacker);
        vm.stopPrank();
    }

    function test_RescueToken_CannotStealUnderlying() public {
        vm.startPrank(owner);
        vm.expectRevert(MorphoAdapter.MorphoAdapter__CannotRescueUnderlying.selector);
        adapter.rescueToken(address(usdc), owner);
        vm.stopPrank();
    }

    function test_RescueToken_SuccessForRandomToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND");
        randomToken.mint(address(adapter), 500 ether);

        vm.prank(owner);
        adapter.rescueToken(address(randomToken), owner);

        assertEq(randomToken.balanceOf(owner), 500 ether);
    }

    // ==========================================
    // 4. Rewards Tests (URD)
    // ==========================================

    function test_SetUrd_Success() public {
        vm.prank(owner);
        adapter.setUrd(address(urd));

        assertEq(adapter.urd(), address(urd));
    }

    function test_SetUrd_EmitsEvent() public {
        address newUrd = address(0x1234);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit MorphoAdapter.UrdUpdated(address(0), newUrd);
        adapter.setUrd(newUrd);

        // Update again to verify old value is captured
        address newerUrd = address(0x5678);
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit MorphoAdapter.UrdUpdated(newUrd, newerUrd);
        adapter.setUrd(newerUrd);
    }

    function test_SetUrd_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MorphoAdapter.MorphoAdapter__InvalidAddress.selector);
        adapter.setUrd(address(0));
    }

    function test_ClaimRewards_Success() public {
        vm.prank(owner);
        adapter.setUrd(address(urd));

        // Setup: empty proof for mock
        bytes32[] memory proof = new bytes32[](0);
        uint256 claimable = 100 ether;

        vm.prank(owner);
        uint256 claimed = adapter.claimRewards(address(rewardToken), claimable, proof, treasury);

        assertEq(claimed, 100 ether);
        assertEq(rewardToken.balanceOf(treasury), 100 ether);
    }

    function test_ClaimRewards_RevertsIfNoUrd() public {
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(owner);
        vm.expectRevert(MorphoAdapter.MorphoAdapter__InvalidAddress.selector);
        adapter.claimRewards(address(rewardToken), 100 ether, proof, treasury);
    }

    function test_ClaimRewards_RevertsIfZeroRecipient() public {
        vm.startPrank(owner);
        adapter.setUrd(address(urd));

        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(MorphoAdapter.MorphoAdapter__InvalidAddress.selector);
        adapter.claimRewards(address(rewardToken), 100 ether, proof, address(0));
        vm.stopPrank();
    }

    function test_ClaimRewardsToSelf_Success() public {
        vm.prank(owner);
        adapter.setUrd(address(urd));

        bytes32[] memory proof = new bytes32[](0);
        uint256 claimable = 100 ether;

        vm.prank(owner);
        uint256 claimed = adapter.claimRewardsToSelf(address(rewardToken), claimable, proof);

        assertEq(claimed, 100 ether);
        assertEq(rewardToken.balanceOf(address(adapter)), 100 ether);
    }

    function test_ClaimRewardsToSelf_RevertsIfNoUrd() public {
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(owner);
        vm.expectRevert(MorphoAdapter.MorphoAdapter__InvalidAddress.selector);
        adapter.claimRewardsToSelf(address(rewardToken), 100 ether, proof);
    }

    // ==========================================
    // 5. Constructor Validation
    // ==========================================

    function test_Constructor_RevertsOnZeroSplitter() public {
        vm.expectRevert(MorphoAdapter.MorphoAdapter__InvalidAddress.selector);
        new MorphoAdapter(IERC20(address(usdc)), address(morpho), marketParams, owner, address(0));
    }

    function test_Constructor_RevertsOnZeroMorpho() public {
        vm.expectRevert(MorphoAdapter.MorphoAdapter__InvalidAddress.selector);
        new MorphoAdapter(IERC20(address(usdc)), address(0), marketParams, owner, user);
    }

    function test_Constructor_RevertsOnMismatchedLoanToken() public {
        MarketParams memory badParams = MarketParams({
            loanToken: address(0x999), // Wrong token
            collateralToken: address(0x1),
            oracle: address(0x2),
            irm: address(0x3),
            lltv: 0.9e18
        });

        vm.expectRevert(MorphoAdapter.MorphoAdapter__InvalidMarket.selector);
        new MorphoAdapter(IERC20(address(usdc)), address(morpho), badParams, owner, user);
    }

    // ==========================================
    // 6. Partial Withdrawal Protection
    // ==========================================

    function test_Withdraw_RevertsOnPartialMorphoReturn() public {
        PartialWithdrawMorpho partialMorpho = new PartialWithdrawMorpho(address(usdc));
        usdc.mint(address(partialMorpho), 1_000_000 * 1e6);

        MorphoAdapter partialAdapter =
            new MorphoAdapter(IERC20(address(usdc)), address(partialMorpho), marketParams, owner, user);

        uint256 amount = 100 * 1e6;

        vm.startPrank(user);
        usdc.approve(address(partialAdapter), amount);
        partialAdapter.deposit(amount, user);

        partialMorpho.setShortfall(1);

        vm.expectRevert(MorphoAdapter.MorphoAdapter__PartialWithdrawal.selector);
        partialAdapter.withdraw(amount, user, user);
        vm.stopPrank();
    }

    function test_Withdraw_SucceedsOnFullMorphoReturn() public {
        PartialWithdrawMorpho partialMorpho = new PartialWithdrawMorpho(address(usdc));
        usdc.mint(address(partialMorpho), 1_000_000 * 1e6);

        MorphoAdapter partialAdapter =
            new MorphoAdapter(IERC20(address(usdc)), address(partialMorpho), marketParams, owner, user);

        uint256 amount = 100 * 1e6;

        vm.startPrank(user);
        usdc.approve(address(partialAdapter), amount);
        partialAdapter.deposit(amount, user);

        partialAdapter.withdraw(amount, user, user);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), 1000 * 1e6);
    }

}
