// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

// ==========================================
// MOCKS (all inline)
// ==========================================

contract MockERC20 is ERC20 {

    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function mint(
        address to,
        uint256 amount
    ) public {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

}

contract MockOracle is AggregatorV3Interface {

    int256 public price;

    constructor(
        int256 _price
    ) {
        price = _price;
    }

    function setPrice(
        int256 _price
    ) external {
        price = _price;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "Mock";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    ) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, 0, 0);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, block.timestamp, block.timestamp, 0);
    }

}

contract MockSequencer is AggregatorV3Interface {

    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function description() external pure override returns (string memory) {
        return "Sequencer";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    ) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, block.timestamp, 0);
    }

}

contract MockAdapter is IERC4626, ERC20 {

    using Math for uint256;
    IERC20 public assetToken;

    constructor(
        address _asset
    ) ERC20("MockVault", "mvUSDC") {
        assetToken = IERC20(_asset);
    }

    function asset() external view override returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view override returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDiv(supply, totalAssets(), Math.Rounding.Floor);
    }

    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply, Math.Rounding.Floor);
    }

    function maxDeposit(
        address
    ) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(
        address
    ) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(
        address
    ) external view override returns (uint256) {
        return totalAssets();
    }

    function maxRedeem(
        address
    ) external view override returns (uint256) {
        return totalSupply();
    }

    function previewDeposit(
        uint256 assets
    ) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(
        uint256 shares
    ) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(
        uint256 assets
    ) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(
        uint256 shares
    ) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(
        uint256 assets,
        address receiver
    ) external override returns (uint256) {
        uint256 shares = convertToShares(assets);
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return shares;
    }

    function mint(
        uint256 shares,
        address receiver
    ) external override returns (uint256) {
        uint256 assets = convertToAssets(shares);
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external override returns (uint256) {
        uint256 shares = convertToShares(assets);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        assetToken.transfer(receiver, assets);
        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external override returns (uint256) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        uint256 assets = convertToAssets(shares);
        _burn(owner, shares);
        assetToken.transfer(receiver, assets);
        return assets;
    }

}

// ==========================================
// TESTS
// ==========================================

contract SyntheticSplitterFullTest is Test {

    SyntheticSplitter splitter;
    MockERC20 usdc;
    MockOracle oracle;
    MockAdapter adapter;
    MockSequencer sequencer;

    address user = address(0x1);
    address treasury = address(0x2);
    uint256 constant CAP = 200e8;

    function setUp() public {
        vm.warp(2 days); // skip sequencer grace period
        usdc = new MockERC20("USDC", "USDC", 6);
        oracle = new MockOracle(100e8);
        sequencer = new MockSequencer();
        adapter = new MockAdapter(address(usdc));

        splitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(sequencer));

        usdc.mint(user, type(uint128).max);
        vm.startPrank(user);
        usdc.approve(address(splitter), type(uint256).max);
        vm.stopPrank();
    }

    // ====================== ORIGINAL PREVIEW TESTS ======================

    function testFuzz_PreviewMint(
        uint256 amount
    ) public {
        uint256 minAmount = splitter.USDC_MULTIPLIER() / splitter.CAP() + 1;
        vm.assume(amount >= minAmount && amount < 1_000_000_000e18);

        (uint256 required, uint256 toAdapter, uint256 toBuffer) = splitter.previewMint(amount);

        assertEq(toAdapter, 0, "toAdapter should always be 0");
        assertEq(toBuffer, required, "toBuffer should equal required");

        uint256 userBalBefore = usdc.balanceOf(user);
        uint256 splitterBalBefore = usdc.balanceOf(address(splitter));

        vm.prank(user);
        splitter.mint(amount);

        assertEq(userBalBefore - usdc.balanceOf(user), required, "Incorrect USDC required");
        assertEq(usdc.balanceOf(address(splitter)) - splitterBalBefore, required, "All USDC stays local");
    }

    function testFuzz_PreviewBurn_Standard(
        uint256 mintAmount,
        uint256 burnAmount
    ) public {
        uint256 minAmount = splitter.USDC_MULTIPLIER() / splitter.CAP() + 1;
        vm.assume(mintAmount > minAmount && mintAmount < 1_000_000e18);
        // burnAmount must be large enough for non-zero USDC refund
        vm.assume(burnAmount >= minAmount && burnAmount <= mintAmount);

        vm.prank(user);
        splitter.mint(mintAmount);

        (uint256 usdcReturn, uint256 fromAdapter) = splitter.previewBurn(burnAmount);

        uint256 userBalBefore = usdc.balanceOf(user);
        uint256 adapterBalBefore = usdc.balanceOf(address(adapter));

        vm.prank(user);
        splitter.burn(burnAmount);

        assertEq(usdc.balanceOf(user) - userBalBefore, usdcReturn, "Incorrect return amount");

        uint256 actualWithdrawal = adapterBalBefore > usdc.balanceOf(address(adapter))
            ? adapterBalBefore - usdc.balanceOf(address(adapter))
            : 0;
        assertEq(actualWithdrawal, fromAdapter, "Incorrect adapter usage");
    }

    function test_PreviewBurn_CapsAtAdapterLiquidity() public {
        vm.prank(user);
        splitter.mint(100e18);
        splitter.deployToAdapter();

        // Drain local buffer completely
        uint256 buffer = usdc.balanceOf(address(splitter));
        vm.prank(address(splitter));
        usdc.transfer(address(0xdead), buffer);

        // Drain most of adapter's assets so maxWithdraw < needed
        uint256 adapterBalance = usdc.balanceOf(address(adapter));
        vm.prank(address(adapter));
        usdc.transfer(address(0xdead), adapterBalance - 1e6);

        // previewBurn returns capped refund instead of reverting
        (uint256 usdcRefund, uint256 fromAdapter) = splitter.previewBurn(100e18);
        assertEq(fromAdapter, 1e6, "Should cap at adapter liquidity");
        assertEq(usdcRefund, 1e6, "Refund = buffer (0) + adapter (1e6)");
    }

    function test_PreviewBurn_LowBuffer() public {
        uint256 mintAmount = 100e18;
        vm.prank(user);
        splitter.mint(mintAmount);
        splitter.deployToAdapter();

        uint256 buffer = usdc.balanceOf(address(splitter));
        vm.prank(address(splitter));
        usdc.transfer(address(1337), buffer);

        usdc.mint(address(adapter), buffer * 2);

        (uint256 usdcReturn, uint256 fromAdapter) = splitter.previewBurn(mintAmount);
        assertEq(fromAdapter, usdcReturn, "Should pull full from adapter");

        uint256 adapterBalBefore = usdc.balanceOf(address(adapter));
        vm.prank(user);
        splitter.burn(mintAmount);
        assertEq(adapterBalBefore - usdc.balanceOf(address(adapter)), fromAdapter);
    }

    function test_PreviewHarvest() public {
        uint256 mintAmount = 1000e18;
        vm.prank(user);
        splitter.mint(mintAmount);
        splitter.deployToAdapter();

        uint256 yieldAmount = 500e6;
        usdc.mint(address(adapter), yieldAmount);

        (bool canHarvest, uint256 surplus, uint256 callerReward, uint256 treasuryShare, uint256 stakingShare) =
            splitter.previewHarvest();

        assertTrue(canHarvest);
        assertApproxEqAbs(surplus, yieldAmount, 2);

        uint256 userBalBefore = usdc.balanceOf(user);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        vm.prank(user);
        splitter.harvestYield();

        assertEq(usdc.balanceOf(user) - userBalBefore, callerReward);
        assertEq(usdc.balanceOf(treasury) - treasuryBalBefore, treasuryShare + stakingShare); // staking == address(0)
    }

    // ====================== NEW EDGE CASE TESTS ======================

    function test_PreviewMint_ZeroAmount_ReturnsZeros() public {
        (uint256 usdcRequired, uint256 depositToAdapter, uint256 keptInBuffer) = splitter.previewMint(0);
        assertEq(usdcRequired, 0);
        assertEq(depositToAdapter, 0);
        assertEq(keptInBuffer, 0);
    }

    function test_PreviewMint_RevertsWhenLiquidated() public {
        vm.prank(user);
        splitter.mint(1e18);

        oracle.setPrice(int256(CAP + 1));
        splitter.triggerLiquidation();

        // Price recovers below CAP, but liquidation flag persists
        oracle.setPrice(int256(100e8));

        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.previewMint(1e18);
    }

    function test_PreviewMint_RevertsWhenPriceAtOrAboveCap() public {
        vm.prank(user);
        splitter.mint(1e18);

        // Explicit cast to int256
        oracle.setPrice(int256(CAP));
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.previewMint(1e18);

        // CAP + 1 could overflow uint256 in extreme cases, but here it's safe
        oracle.setPrice(int256(CAP + 1));
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.previewMint(1e18);
    }

    function test_PreviewBurn_RevertsWhenPausedAndInsolvent() public {
        vm.prank(user);
        splitter.mint(10e18);
        splitter.deployToAdapter();

        // Drain the local buffer completely
        uint256 buffer = usdc.balanceOf(address(splitter));
        vm.prank(address(splitter));
        usdc.transfer(address(0xdead), buffer);

        // Remove enough from adapter to break solvency
        // For 10e18 mint: ~2000 USDC total backing needed
        // After deploy: buffer ~200 USDC, adapter ~1800 USDC
        // Remove e.g. 500 USDC (500e6) from adapter → totalAssets ~1500 USDC < 2000 needed
        vm.prank(address(adapter));
        usdc.transfer(address(0xdead), 500e6);

        // Pause
        vm.prank(splitter.owner());
        splitter.pause();

        // previewBurn reverts due to insolvency check
        vm.expectRevert(SyntheticSplitter.Splitter__Insolvent.selector);
        splitter.previewBurn(1e18);
    }

    function test_PreviewBurn_SucceedsWhenPausedAndSolvent() public {
        vm.prank(user);
        splitter.mint(10e18);

        vm.prank(splitter.owner());
        splitter.pause();

        (uint256 usdcReturn,) = splitter.previewBurn(1e18);
        assertGt(usdcReturn, 0);
    }

    function test_GetSystemStatus_Empty() public {
        SyntheticSplitter.SystemStatus memory s = splitter.getSystemStatus();
        assertEq(s.currentPrice, 100e8);
        assertEq(s.capPrice, CAP);
        assertFalse(s.liquidated);
        assertFalse(s.isPaused);
        assertEq(s.totalAssets, 0);
        assertEq(s.totalLiabilities, 0);
        assertEq(s.collateralRatio, 0);
    }

    function test_GetSystemStatus_AfterMintAndYield() public {
        vm.prank(user);
        splitter.mint(10e18);
        splitter.deployToAdapter();
        usdc.mint(address(adapter), 1000e6); // simulate yield

        SyntheticSplitter.SystemStatus memory s = splitter.getSystemStatus();
        assertGt(s.totalAssets, s.totalLiabilities);
        assertGt(s.collateralRatio, 10_000);
        assertFalse(s.liquidated);
        assertFalse(s.isPaused);
    }

    function test_GetSystemStatus_WhenLiquidated() public {
        vm.prank(user);
        splitter.mint(1e18);

        oracle.setPrice(int256(201e8));

        splitter.triggerLiquidation(); // Now properly sets the flag

        SyntheticSplitter.SystemStatus memory s = splitter.getSystemStatus();
        assertTrue(s.liquidated);
        assertEq(s.currentPrice, 201e8);
    }

    /// @notice getSystemStatus() gracefully handles oracle failures for UI diagnostics
    /// @dev Returns 0 for currentPrice when oracle reports invalid data (view function, no revert)
    function test_GetSystemStatus_OracleZeroPrice_ReturnsZero() public {
        oracle.setPrice(int256(0));
        SyntheticSplitter.SystemStatus memory s = splitter.getSystemStatus();
        // View function returns 0 to indicate oracle error (doesn't revert for UI compatibility)
        assertEq(s.currentPrice, 0);
    }

    // ====================== LIQUIDATION TRIGGER TESTS ======================

    function test_TriggerLiquidation_SucceedsWhenPriceAboveCap() public {
        vm.prank(user);
        splitter.mint(5e18);

        // Set price above CAP
        oracle.setPrice(int256(201e8));

        // Anyone can trigger
        splitter.triggerLiquidation();

        SyntheticSplitter.SystemStatus memory s = splitter.getSystemStatus();
        assertTrue(s.liquidated);
        assertEq(s.currentPrice, 201e8);
    }

    function test_TriggerLiquidation_PersistsAfterRevert() public {
        vm.prank(user);
        splitter.mint(5e18);

        oracle.setPrice(int256(201e8));

        // Trigger liquidation
        splitter.triggerLiquidation();

        // Subsequent mint should now revert with LiquidationActive (and NOT set flag again)
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        vm.prank(user);
        splitter.mint(1e18);

        // Flag remains true
        assertTrue(splitter.isLiquidated());
    }

    function test_TriggerLiquidation_RevertsWhenPriceBelowCap() public {
        vm.prank(user);
        splitter.mint(5e18);

        // Price still below CAP
        oracle.setPrice(int256(199e8));

        vm.expectRevert(SyntheticSplitter.Splitter__NotLiquidated.selector);
        splitter.triggerLiquidation();
    }

    function test_TriggerLiquidation_RevertsIfAlreadyLiquidated() public {
        vm.prank(user);
        splitter.mint(5e18);

        oracle.setPrice(int256(201e8));
        splitter.triggerLiquidation();

        // Calling again should revert
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        splitter.triggerLiquidation();
    }

    function test_TriggerLiquidation_CanBeCalledByAnyone() public {
        vm.prank(user);
        splitter.mint(5e18);

        oracle.setPrice(int256(201e8));

        // Call from a different address (not owner, not user)
        address randomCaller = address(0x9999);
        vm.prank(randomCaller);
        splitter.triggerLiquidation();

        assertTrue(splitter.isLiquidated());
    }

    function test_TriggerLiquidation_EmitsEvent() public {
        vm.prank(user);
        splitter.mint(5e18);

        oracle.setPrice(int256(210e8));

        vm.expectEmit(true, false, false, true);
        emit SyntheticSplitter.LiquidationTriggered(210e8);

        splitter.triggerLiquidation();
    }

    function test_TriggerLiquidation_UpdatesStatusCorrectly() public {
        vm.prank(user);
        splitter.mint(10e18);

        oracle.setPrice(int256(CAP + 50_000_000)); // 200.05

        splitter.triggerLiquidation();

        SyntheticSplitter.SystemStatus memory s = splitter.getSystemStatus();
        assertTrue(s.liquidated);
        assertEq(s.currentPrice, CAP + 50_000_000);
        assertEq(s.capPrice, CAP);
    }

    function test_Liquidation_IsIrreversible_EvenIfPriceRecovers() public {
        // Step 1: Mint some tokens to have supply
        vm.prank(user);
        splitter.mint(10e18);

        // Step 2: Push price above CAP and trigger liquidation
        oracle.setPrice(int256(201e8));
        splitter.triggerLiquidation();

        // Verify liquidated state
        assertTrue(splitter.isLiquidated());
        SyntheticSplitter.SystemStatus memory s1 = splitter.getSystemStatus();
        assertTrue(s1.liquidated);

        // Step 3: Drop price back to safe level (well below CAP)
        oracle.setPrice(int256(150e8));

        // Verify price is now safe
        SyntheticSplitter.SystemStatus memory s2 = splitter.getSystemStatus();
        assertEq(s2.currentPrice, 150e8);

        // Step 4: Attempt to mint again — should STILL revert because liquidation is irreversible
        vm.expectRevert(SyntheticSplitter.Splitter__LiquidationActive.selector);
        vm.prank(user);
        splitter.mint(1e18);

        // Final check: flag remains true
        assertTrue(splitter.isLiquidated());
        SyntheticSplitter.SystemStatus memory s3 = splitter.getSystemStatus();
        assertTrue(s3.liquidated);
        assertEq(s3.currentPrice, 150e8); // price updated correctly, but system stays dead
    }

}
