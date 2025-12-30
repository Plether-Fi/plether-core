// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SyntheticSplitter.sol";
import "../src/YieldAdapter.sol";

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
// TEST ADAPTER
// ==========================================

contract LimitedWithdrawAdapter is YieldAdapter {
    uint256 public maxWithdrawPerTx;

    constructor(
        IERC20 _asset,
        address _aavePool,
        address _aToken,
        address _owner,
        address _splitter,
        uint256 _maxWithdrawPerTx
    ) YieldAdapter(_asset, _aavePool, _aToken, _owner, _splitter) {
        maxWithdrawPerTx = _maxWithdrawPerTx;
    }

    function maxWithdraw(address) public view override returns (uint256) {
        return maxWithdrawPerTx;
    }
}

// ==========================================
// MAIN TEST
// ==========================================

contract SyntheticSplitterConcurrentTest is Test {
    SyntheticSplitter splitter;
    YieldAdapter unlimitedAdapter;
    LimitedWithdrawAdapter limitedAdapter;

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

        unlimitedAdapter =
            new YieldAdapter(IERC20(address(usdc)), address(pool), address(aUsdc), owner, futureSplitterAddr);

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

    function test_RevertWhen_ConcurrentBurns_LiquidityLimit() public {
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address futureSplitterAddr = vm.computeCreateAddress(owner, nonce + 1);

        limitedAdapter = new LimitedWithdrawAdapter(
            IERC20(address(usdc)), address(pool), address(aUsdc), owner, futureSplitterAddr, 10_000 * 1e6
        );

        vm.stopPrank();
        vm.prank(address(limitedAdapter));
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(owner);

        splitter = new SyntheticSplitter(
            address(oracle), address(usdc), address(limitedAdapter), CAP, treasury, address(sequencer)
        );
        vm.stopPrank();

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

        vm.prank(alice);
        vm.expectRevert();
        splitter.burn(burnAmount);

        vm.prank(bob);
        vm.expectRevert();
        splitter.burn(burnAmount);

        vm.prank(carol);
        vm.expectRevert();
        splitter.burn(burnAmount);

        uint256 totalAssets = handlerLikeTotalAssets(limitedAdapter);
        uint256 totalLiabilities = (splitter.TOKEN_A().totalSupply() * CAP) / splitter.USDC_MULTIPLIER();
        assertGe(
            totalAssets,
            totalLiabilities,
            "System should remain globally solvent despite individual burns reverting due to adapter liquidity limit"
        );
    }

    function handlerLikeTotalAssets(YieldAdapter currentAdapter) internal view returns (uint256) {
        uint256 buffer = usdc.balanceOf(address(splitter));
        uint256 shares = currentAdapter.balanceOf(address(splitter));
        uint256 adapterAssets = shares > 0 ? currentAdapter.convertToAssets(shares) : 0;
        return buffer + adapterAssets;
    }
}
