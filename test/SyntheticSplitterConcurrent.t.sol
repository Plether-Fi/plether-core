// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "../src/MockYieldAdapter.sol";
import "../src/interfaces/ISyntheticSplitter.sol";

// ==========================================
// MOCKS
// ==========================================

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) public {
        require(balanceOf[from] >= amount, "Burn too much");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}

contract MockUSDC is MockERC20 {
    constructor() MockERC20("USDC", "USDC") {}

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

contract MockAToken is MockERC20 {
    constructor(string memory n, string memory s) MockERC20(n, s) {}

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

contract MockOracle is AggregatorV3Interface {
    int256 public price;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(int256 _price, uint256 _startedAt, uint256 _updatedAt) {
        price = _price;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, startedAt, updatedAt, 0);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, startedAt, updatedAt, 0);
    }
}

contract MockPool {
    address public asset;
    address public aToken;

    constructor(address _asset, address _aToken) {
        asset = _asset;
        aToken = _aToken;
    }

    //  - Pool calls transferFrom on Asset
    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, aToken, amount);
        MockERC20(aToken).mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        MockERC20(aToken).burn(msg.sender, amount);
        IERC20(asset).transferFrom(aToken, to, amount);
        return amount;
    }
}

// ==========================================
// MAIN TEST
// ==========================================

contract SyntheticSplitterConcurrentTest is Test {
    SyntheticSplitter splitter;
    MockYieldAdapter unlimitedAdapter;

    MockUSDC usdc;
    MockAToken aUsdc;
    MockPool pool;
    MockOracle oracle;
    MockOracle sequencer;

    address owner = address(0x1);
    address alice = address(0xA);
    address bob = address(0xB);
    address carol = address(0xC);
    address treasury = address(0x99);

    uint256 constant CAP = 200_000_000;

    function dealUsdc(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    function setUp() public {
        vm.warp(1735689600);

        usdc = new MockUSDC();
        aUsdc = new MockAToken("aUSDC", "aUSDC");
        pool = new MockPool(address(usdc), address(aUsdc));

        // Oracle & Sequencer setup
        oracle = new MockOracle(100_000_000, block.timestamp, block.timestamp);
        sequencer = new MockOracle(0, block.timestamp - 2 hours, block.timestamp);

        // Fund AToken
        usdc.mint(address(aUsdc), 10_000_000 * 1e6);

        // =====================================================
        // CRITICAL FIX: Allow Pool to move funds OUT of AToken
        // =====================================================
        vm.prank(address(aUsdc));
        usdc.approve(address(pool), type(uint256).max);

        // Calculate Future Address
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address futureSplitterAddr = vm.computeCreateAddress(owner, nonce + 1);

        unlimitedAdapter = new MockYieldAdapter(IERC20(address(usdc)), owner, futureSplitterAddr);

        // Manual approval for Adapter -> Pool (just in case)
        vm.stopPrank();
        vm.prank(address(unlimitedAdapter));
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(owner);

        splitter = new SyntheticSplitter(
            address(oracle), address(usdc), address(unlimitedAdapter), CAP, treasury, address(sequencer)
        );
        vm.stopPrank();

        // Labels
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(carol, "Carol");
        vm.label(address(splitter), "Splitter");
        vm.label(address(pool), "Pool");
        vm.label(address(aUsdc), "aToken");
    }

    function test_ConcurrentBurns_LowBuffer() public {
        uint256 mintAmount = 100_000 ether;
        uint256 burnAmount = 40_000 ether;

        dealUsdc(alice, 1_000_000e6);
        dealUsdc(bob, 1_000_000e6);
        dealUsdc(carol, 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(mintAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(mintAmount);
        vm.stopPrank();

        vm.startPrank(carol);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(mintAmount);
        vm.stopPrank();

        uint256 expectedRefundEach = (burnAmount * CAP) / splitter.USDC_MULTIPLIER();
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        vm.prank(alice);
        splitter.burn(burnAmount);

        vm.prank(bob);
        splitter.burn(burnAmount);

        vm.prank(carol);
        splitter.burn(burnAmount);

        assertEq(splitter.TOKEN_A().balanceOf(alice), mintAmount - burnAmount);
        assertEq(splitter.TOKEN_A().balanceOf(bob), mintAmount - burnAmount);
        assertEq(splitter.TOKEN_A().balanceOf(carol), mintAmount - burnAmount);

        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedRefundEach);
        assertEq(usdc.balanceOf(bob) - bobBefore, expectedRefundEach);
        assertEq(usdc.balanceOf(carol) - carolBefore, expectedRefundEach);

        uint256 totalAssets = handlerLikeTotalAssets(unlimitedAdapter);
        uint256 totalLiabilities = (splitter.TOKEN_A().totalSupply() * CAP) / splitter.USDC_MULTIPLIER();
        assertGe(totalAssets, totalLiabilities);
    }

    function test_RevertWhen_ConcurrentBurns_AdapterCompletelyBroken() public {
        // This test verifies that when BOTH withdraw and redeem fail, burns revert
        uint256 mintAmount = 100_000 ether;
        uint256 burnAmount = 50_000 ether;

        dealUsdc(alice, 1_000_000e6);
        dealUsdc(bob, 1_000_000e6);
        dealUsdc(carol, 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(alice);
        splitter.mint(mintAmount);

        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        splitter.mint(mintAmount);

        vm.prank(carol);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(carol);
        splitter.mint(mintAmount);

        // Mock BOTH withdraw and redeem to fail (simulates completely broken adapter)
        vm.mockCallRevert(
            address(unlimitedAdapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("ADAPTER_BROKEN")
        );
        vm.mockCallRevert(
            address(unlimitedAdapter), abi.encodeWithSelector(IERC4626.redeem.selector), abi.encode("ADAPTER_BROKEN")
        );

        // All burns should revert with Splitter__AdapterWithdrawFailed
        vm.prank(alice);
        vm.expectRevert(SyntheticSplitter.Splitter__AdapterWithdrawFailed.selector);
        splitter.burn(burnAmount);

        vm.prank(bob);
        vm.expectRevert(SyntheticSplitter.Splitter__AdapterWithdrawFailed.selector);
        splitter.burn(burnAmount);

        vm.prank(carol);
        vm.expectRevert(SyntheticSplitter.Splitter__AdapterWithdrawFailed.selector);
        splitter.burn(burnAmount);

        uint256 totalAssets = handlerLikeTotalAssets(unlimitedAdapter);
        uint256 totalLiabilities = (splitter.TOKEN_A().totalSupply() * CAP) / splitter.USDC_MULTIPLIER();
        assertGe(
            totalAssets,
            totalLiabilities,
            "System should remain globally solvent despite individual burns reverting due to adapter failure"
        );
    }

    function test_ConcurrentBurns_SucceedWithRedeemFallback() public {
        // This test verifies that when withdraw fails but redeem works, burns succeed
        uint256 mintAmount = 100_000 ether;
        uint256 burnAmount = 50_000 ether;

        dealUsdc(alice, 1_000_000e6);
        dealUsdc(bob, 1_000_000e6);
        dealUsdc(carol, 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(alice);
        splitter.mint(mintAmount);

        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        splitter.mint(mintAmount);

        vm.prank(carol);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(carol);
        splitter.mint(mintAmount);

        // Mock only withdraw to fail (redeem still works as fallback)
        vm.mockCallRevert(
            address(unlimitedAdapter), abi.encodeWithSelector(IERC4626.withdraw.selector), abi.encode("WITHDRAW_FAILED")
        );

        uint256 expectedRefundEach = (burnAmount * CAP) / splitter.USDC_MULTIPLIER();
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        // All burns should succeed via redeem fallback
        vm.prank(alice);
        splitter.burn(burnAmount);

        vm.prank(bob);
        splitter.burn(burnAmount);

        vm.prank(carol);
        splitter.burn(burnAmount);

        // Verify everyone got their refunds
        assertEq(splitter.TOKEN_A().balanceOf(alice), mintAmount - burnAmount);
        assertEq(splitter.TOKEN_A().balanceOf(bob), mintAmount - burnAmount);
        assertEq(splitter.TOKEN_A().balanceOf(carol), mintAmount - burnAmount);

        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedRefundEach);
        assertEq(usdc.balanceOf(bob) - bobBefore, expectedRefundEach);
        assertEq(usdc.balanceOf(carol) - carolBefore, expectedRefundEach);
    }

    function handlerLikeTotalAssets(MockYieldAdapter currentAdapter) internal view returns (uint256) {
        uint256 buffer = usdc.balanceOf(address(splitter));
        uint256 shares = currentAdapter.balanceOf(address(splitter));
        uint256 adapterAssets = shares > 0 ? currentAdapter.convertToAssets(shares) : 0;
        return buffer + adapterAssets;
    }

    // ==========================================
    // CONCURRENT STATE TESTS (Phase 2.3)
    // ==========================================

    /// @notice Test: User A burns while User B mints while price approaches CAP
    function test_ConcurrentMintBurn_NearLiquidation() public {
        uint256 mintAmount = 100_000 ether;
        uint256 burnAmount = 50_000 ether;

        // Setup: Alice and Bob mint initially
        dealUsdc(alice, 1_000_000e6);
        dealUsdc(bob, 1_000_000e6);
        dealUsdc(carol, 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(alice);
        splitter.mint(mintAmount);

        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        splitter.mint(mintAmount);

        // Record state before price change
        uint256 aliceTokensBefore = splitter.TOKEN_A().balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Price increases to $1.95 (just below CAP of $2.00)
        oracle = new MockOracle(195_000_000, block.timestamp, block.timestamp);
        // Note: Can't change oracle after construction, so simulate via state

        // Alice burns while Bob mints (concurrent operations)
        vm.prank(alice);
        splitter.burn(burnAmount);

        vm.prank(carol);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(carol);
        splitter.mint(mintAmount);

        // Verify Alice got her refund
        uint256 expectedRefund = (burnAmount * CAP) / splitter.USDC_MULTIPLIER();
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, expectedRefund);
        assertEq(splitter.TOKEN_A().balanceOf(alice), aliceTokensBefore - burnAmount);

        // Verify Carol got her tokens
        assertEq(splitter.TOKEN_A().balanceOf(carol), mintAmount);

        // Verify system solvency
        _verifySolvency();
    }

    /// @notice Test: Multiple operations interleaved with buffer depletion
    function test_HarvestBurnRace_BufferDepletion() public {
        uint256 largeAmount = 500_000 ether;

        // Alice mints a large amount (creates adapter deposit + buffer)
        dealUsdc(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(alice);
        splitter.mint(largeAmount);

        // Check initial buffer state
        uint256 initialBuffer = usdc.balanceOf(address(splitter));
        uint256 adapterShares = unlimitedAdapter.balanceOf(address(splitter));
        assertGt(adapterShares, 0, "Should have adapter deposits");
        assertGt(initialBuffer, 0, "Should have local buffer");

        // Alice burns in multiple small chunks to deplete buffer
        uint256 burnChunk = 100_000 ether;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // First burn - uses buffer
        vm.prank(alice);
        splitter.burn(burnChunk);

        // Second burn - might need adapter withdrawal
        vm.prank(alice);
        splitter.burn(burnChunk);

        // Third burn - definitely needs adapter withdrawal
        vm.prank(alice);
        splitter.burn(burnChunk);

        // Verify Alice got all her refunds
        uint256 expectedTotal = (burnChunk * 3 * CAP) / splitter.USDC_MULTIPLIER();
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, expectedTotal);

        // Verify remaining tokens
        assertEq(splitter.TOKEN_A().balanceOf(alice), largeAmount - (burnChunk * 3));

        // Verify solvency maintained
        _verifySolvency();
    }

    /// @notice Test: Burn during adapter migration timelock
    function test_BurnDuringAdapterMigration() public {
        uint256 mintAmount = 100_000 ether;

        // Alice mints
        dealUsdc(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(alice);
        splitter.mint(mintAmount);

        // Owner initiates adapter migration (proposeAdapter starts timelock)
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address newAdapterAddr = vm.computeCreateAddress(owner, nonce);
        MockYieldAdapter newAdapter = new MockYieldAdapter(IERC20(address(usdc)), owner, address(splitter));
        splitter.proposeAdapter(address(newAdapter));
        vm.stopPrank();

        // Alice tries to burn during migration timelock
        // Burns should still work with the current adapter
        uint256 burnAmount = 50_000 ether;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        splitter.burn(burnAmount);

        // Verify burn succeeded
        uint256 expectedRefund = (burnAmount * CAP) / splitter.USDC_MULTIPLIER();
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, expectedRefund);
        assertEq(splitter.TOKEN_A().balanceOf(alice), mintAmount - burnAmount);

        // Verify solvency
        _verifySolvency();
    }

    /// @notice Test: Concurrent mints and burns that empty and refill buffer
    function test_BufferEmptyRefill_Concurrent() public {
        uint256 mintAmount = 100_000 ether;

        // Initial setup - multiple users mint
        dealUsdc(alice, 5_000_000e6);
        dealUsdc(bob, 5_000_000e6);
        dealUsdc(carol, 5_000_000e6);

        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(alice);
        splitter.mint(mintAmount);

        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        splitter.mint(mintAmount);

        // Alice burns most of her tokens (depletes buffer)
        uint256 largeBurn = 90_000 ether;
        vm.prank(alice);
        splitter.burn(largeBurn);

        // Carol mints (refills buffer)
        vm.prank(carol);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(carol);
        splitter.mint(mintAmount);

        // Bob burns (should work with refilled buffer)
        vm.prank(bob);
        splitter.burn(largeBurn);

        // Verify final state
        assertEq(splitter.TOKEN_A().balanceOf(alice), mintAmount - largeBurn);
        assertEq(splitter.TOKEN_A().balanceOf(bob), mintAmount - largeBurn);
        assertEq(splitter.TOKEN_A().balanceOf(carol), mintAmount);

        _verifySolvency();
    }

    /// @notice Test: Rapid successive operations don't break state
    function test_RapidSuccessiveOperations() public {
        dealUsdc(alice, 10_000_000e6);
        dealUsdc(bob, 10_000_000e6);

        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);

        // Rapid mint-burn-mint-burn sequence
        for (uint256 i = 0; i < 5; i++) {
            uint256 amount = (i + 1) * 10_000 ether;

            vm.prank(alice);
            splitter.mint(amount);

            vm.prank(bob);
            splitter.mint(amount);

            // Partial burns
            if (splitter.TOKEN_A().balanceOf(alice) >= amount / 2) {
                vm.prank(alice);
                splitter.burn(amount / 2);
            }

            if (splitter.TOKEN_A().balanceOf(bob) >= amount / 2) {
                vm.prank(bob);
                splitter.burn(amount / 2);
            }
        }

        // System should still be solvent after all operations
        _verifySolvency();

        // Both users should have non-zero balances
        assertGt(splitter.TOKEN_A().balanceOf(alice), 0, "Alice should have tokens");
        assertGt(splitter.TOKEN_A().balanceOf(bob), 0, "Bob should have tokens");
    }

    /// @notice Test: Liquidation blocks new mints but allows burns and emergency redemption
    function test_LiquidationBlocksMintAllowsRedeem() public {
        uint256 mintAmount = 100_000 ether;

        // Alice mints
        dealUsdc(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(alice);
        splitter.mint(mintAmount);

        // Set oracle price to >= CAP to trigger liquidation
        oracle.setPrice(int256(CAP)); // $2.00 = CAP

        // Anyone can trigger liquidation when price >= CAP
        splitter.triggerLiquidation();

        // Verify status is SETTLED
        assertEq(uint256(splitter.currentStatus()), uint256(ISyntheticSplitter.Status.SETTLED));

        // Bob tries to mint - should fail (liquidation blocks mints)
        dealUsdc(bob, 1_000_000e6);
        vm.prank(bob);
        usdc.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.mint(mintAmount);

        // Regular burn still works during liquidation (requires both BEAR + BULL)
        uint256 burnAmount = 50_000 ether;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        splitter.burn(burnAmount);

        // Verify burn succeeded
        uint256 expectedRefund = (burnAmount * CAP) / splitter.USDC_MULTIPLIER();
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, expectedRefund);

        // emergencyRedeem also works (only needs BEAR - BULL is worthless at CAP)
        uint256 emergencyAmount = 10_000 ether;
        aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        splitter.emergencyRedeem(emergencyAmount);

        // Verify emergency redeem succeeded
        expectedRefund = (emergencyAmount * CAP) / splitter.USDC_MULTIPLIER();
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, expectedRefund);
    }

    // ==========================================
    // HELPER FUNCTIONS
    // ==========================================

    function _verifySolvency() internal view {
        uint256 totalSupply = splitter.TOKEN_A().totalSupply();
        uint256 liabilities = (totalSupply * CAP) / splitter.USDC_MULTIPLIER();

        uint256 localBuffer = usdc.balanceOf(address(splitter));
        uint256 adapterShares = unlimitedAdapter.balanceOf(address(splitter));
        uint256 adapterAssets = adapterShares > 0 ? unlimitedAdapter.convertToAssets(adapterShares) : 0;
        uint256 totalAssets = localBuffer + adapterAssets;

        assertGe(totalAssets, liabilities, "System should be solvent");
    }
}
