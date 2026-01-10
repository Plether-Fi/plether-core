// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "./utils/MockYieldAdapter.sol";
import "../src/interfaces/AggregatorV3Interface.sol";
import "../src/libraries/OracleLib.sol";

/**
 * @title OracleEdgeCasesTest
 * @notice Tests for oracle edge cases and price manipulation scenarios
 * @dev Tests:
 *      - Price oscillation between preview and execute
 *      - Stale oracle data handling
 *      - Curve price_oracle() edge cases
 *      - TOCTOU (Time-of-Check-to-Time-of-Use) vulnerabilities
 */
contract OracleEdgeCasesTest is Test {
    SyntheticSplitter splitter;
    MockYieldAdapter adapter;
    MockUSDC usdc;
    MockOracle oracle;
    MockOracle sequencer;

    address owner = address(0x1);
    address alice = address(0xA);
    address treasury = address(0x99);

    uint256 constant CAP = 200_000_000; // $2.00

    function setUp() public {
        vm.warp(1735689600);

        usdc = new MockUSDC();
        oracle = new MockOracle(100_000_000, block.timestamp, block.timestamp); // $1.00
        sequencer = new MockOracle(0, block.timestamp - 2 hours, block.timestamp);

        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address futureSplitter = vm.computeCreateAddress(owner, nonce + 1);
        adapter = new MockYieldAdapter(IERC20(address(usdc)), owner, futureSplitter);
        splitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(sequencer));
        vm.stopPrank();

        // Fund test accounts
        usdc.mint(alice, 10_000_000e6);

        vm.label(alice, "Alice");
        vm.label(address(splitter), "Splitter");
    }

    // ==========================================
    // PRICE OSCILLATION TESTS
    // ==========================================

    /// @notice Test: Price changes between preview and mint execution
    function test_PriceOscillation_PreviewToMint() public {
        uint256 mintAmount = 1000 ether;

        // Preview at $1.00
        (uint256 previewUsdc,,) = splitter.previewMint(mintAmount);

        // Price increases to $1.50
        oracle.setPrice(150_000_000);

        // Execute mint - should still work (price below CAP)
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(mintAmount);
        vm.stopPrank();

        // Alice should have received tokens
        assertEq(splitter.TOKEN_A().balanceOf(alice), mintAmount);
        assertEq(splitter.TOKEN_B().balanceOf(alice), mintAmount);
    }

    /// @notice Test: Price reaches CAP between preview and mint
    function test_PriceReachesCap_PreviewToMint() public {
        uint256 mintAmount = 1000 ether;

        // Preview at $1.00
        (uint256 previewUsdc,,) = splitter.previewMint(mintAmount);

        // Price reaches CAP ($2.00)
        oracle.setPrice(int256(CAP));

        // Mint should revert
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.mint(mintAmount);
        vm.stopPrank();
    }

    /// @notice Test: Price oscillates but stays below CAP
    function test_PriceOscillation_MultipleChanges() public {
        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // Mint at $1.00
        splitter.mint(1000 ether);

        // Price drops to $0.50
        oracle.setPrice(50_000_000);
        splitter.mint(1000 ether);

        // Price rises to $1.80
        oracle.setPrice(180_000_000);
        splitter.mint(1000 ether);

        // Price drops back to $1.00
        oracle.setPrice(100_000_000);
        splitter.mint(1000 ether);

        vm.stopPrank();

        // All mints should have succeeded
        assertEq(splitter.TOKEN_A().balanceOf(alice), 4000 ether);
    }

    // ==========================================
    // STALE ORACLE TESTS
    // ==========================================

    /// @notice Test: Oracle data becomes stale (8+ hours old)
    function test_StaleOracle_BlocksMint() public {
        uint256 mintAmount = 1000 ether;

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // First mint works
        splitter.mint(mintAmount);

        // Advance time by 9 hours (staleness threshold is typically 8 hours)
        vm.warp(block.timestamp + 9 hours);

        // Oracle data is now stale - mint should revert
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        splitter.mint(mintAmount);

        vm.stopPrank();
    }

    /// @notice Test: Oracle updates after being stale
    function test_StaleOracle_Recovery() public {
        uint256 mintAmount = 1000 ether;

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // First mint works
        splitter.mint(mintAmount);

        // Advance time by 9 hours
        vm.warp(block.timestamp + 9 hours);

        // Oracle updates with fresh data
        oracle.setPrice(100_000_000); // Updates updatedAt to current timestamp

        // Mint should work again
        splitter.mint(mintAmount);

        vm.stopPrank();

        assertEq(splitter.TOKEN_A().balanceOf(alice), 2 * mintAmount);
    }

    // ==========================================
    // SEQUENCER UPTIME TESTS
    // ==========================================

    /// @notice Test: Sequencer down blocks operations
    function test_SequencerDown_BlocksMint() public {
        uint256 mintAmount = 1000 ether;

        // Set sequencer as down (answer != 0 means down)
        sequencer.setAnswer(1);
        sequencer.setStartedAt(block.timestamp);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // Mint should revert
        vm.expectRevert(OracleLib.OracleLib__SequencerDown.selector);
        splitter.mint(mintAmount);

        vm.stopPrank();
    }

    /// @notice Test: Sequencer just came back up (grace period)
    function test_SequencerGracePeriod_BlocksMint() public {
        uint256 mintAmount = 1000 ether;

        // Sequencer up but just started (within grace period)
        sequencer.setAnswer(0);
        sequencer.setStartedAt(block.timestamp); // Just came up

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // Mint should revert due to grace period
        vm.expectRevert(OracleLib.OracleLib__SequencerGracePeriod.selector);
        splitter.mint(mintAmount);

        vm.stopPrank();
    }

    // ==========================================
    // TOCTOU (Time-of-Check-to-Time-of-Use) TESTS
    // ==========================================

    /// @notice Test: Price changes during multi-step operation
    function test_TOCTOU_PriceChangeDuringBurn() public {
        uint256 mintAmount = 1000 ether;

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.mint(mintAmount);

        // Preview burn at $1.00
        (uint256 previewRefund,) = splitter.previewBurn(500 ether);

        // Price changes to $1.50 before burn executes
        oracle.setPrice(150_000_000);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Burn executes - refund should be at CAP regardless of oracle
        splitter.burn(500 ether);

        vm.stopPrank();

        // Should have received CAP-based refund (not affected by oracle price)
        (uint256 expectedRefund,) = splitter.previewBurn(500 ether);
        uint256 actualRefund = usdc.balanceOf(alice) - aliceUsdcBefore;
        assertEq(actualRefund, expectedRefund, "Refund should match preview");
    }

    /// @notice Test: Preview accurate despite flash price manipulation
    function test_Preview_NoFlashPriceManipulation() public {
        uint256 mintAmount = 1000 ether;

        // Get preview at current price
        (uint256 preview1,,) = splitter.previewMint(mintAmount);

        // Simulate oracle price change
        oracle.setPrice(150_000_000);
        (uint256 preview2,,) = splitter.previewMint(mintAmount);

        // Restore price
        oracle.setPrice(100_000_000);
        (uint256 preview3,,) = splitter.previewMint(mintAmount);

        // Previews at same price should be equal
        assertEq(preview1, preview3, "Same price should give same preview");
        // Preview at higher price might differ based on implementation
    }

    // ==========================================
    // EDGE CASE PRICES
    // ==========================================

    /// @notice Test: Price at exactly CAP boundary
    function test_PriceAtExactCAP_BlocksMint() public {
        uint256 mintAmount = 1000 ether;

        // Set price exactly at CAP
        oracle.setPrice(int256(CAP));

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // Should revert at exact CAP
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.mint(mintAmount);

        vm.stopPrank();
    }

    /// @notice Test: Price just below CAP
    function test_PriceJustBelowCAP_AllowsMint() public {
        uint256 mintAmount = 1000 ether;

        // Set price just below CAP ($1.99999999)
        oracle.setPrice(int256(CAP) - 1);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // Should succeed
        splitter.mint(mintAmount);

        vm.stopPrank();

        assertEq(splitter.TOKEN_A().balanceOf(alice), mintAmount);
    }

    /// @notice Test: Very low price (near zero)
    function test_VeryLowPrice_AllowsMint() public {
        uint256 mintAmount = 1000 ether;

        // Set price very low ($0.01)
        oracle.setPrice(1_000_000);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // Should succeed
        splitter.mint(mintAmount);

        vm.stopPrank();

        assertEq(splitter.TOKEN_A().balanceOf(alice), mintAmount);
    }

    /// @notice Test: Zero price reverts to prevent operations during oracle failures
    /// @dev OracleLib reverts on invalid prices to halt operations when oracle is broken
    function test_ZeroPrice_RevertsOnMint() public {
        uint256 mintAmount = 1000 ether;

        // Set price to zero
        oracle.setPrice(0);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // Mint reverts because oracle reports invalid price
        vm.expectRevert(OracleLib.OracleLib__InvalidPrice.selector);
        splitter.mint(mintAmount);

        vm.stopPrank();
    }

    /// @notice Test: Negative price reverts to prevent operations during oracle failures
    /// @dev OracleLib reverts on invalid prices to halt operations when oracle is broken
    function test_NegativePrice_RevertsOnMint() public {
        uint256 mintAmount = 1000 ether;

        // Set price negative
        oracle.setPrice(-100_000_000);

        vm.startPrank(alice);
        usdc.approve(address(splitter), type(uint256).max);

        // Mint reverts because oracle reports invalid price
        vm.expectRevert(OracleLib.OracleLib__InvalidPrice.selector);
        splitter.mint(mintAmount);

        vm.stopPrank();
    }
}

// ==========================================
// MOCKS
// ==========================================

contract MockUSDC is IERC20 {
    string public constant name = "USDC";
    string public constant symbol = "USDC";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() public pure returns (uint8) {
        return 6;
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

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
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

    function setAnswer(int256 _answer) external {
        price = _answer;
    }

    function setStartedAt(uint256 _startedAt) external {
        startedAt = _startedAt;
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
