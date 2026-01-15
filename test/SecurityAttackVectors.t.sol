// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {BasketOracle} from "../src/oracles/BasketOracle.sol";
import {MorphoOracle} from "../src/oracles/MorphoOracle.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {MockYieldAdapter} from "./utils/MockYieldAdapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {

    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockCurvePool {

    uint256 public oraclePrice;

    constructor(
        uint256 _price
    ) {
        oraclePrice = _price;
    }

    function price_oracle() external view returns (uint256) {
        return oraclePrice;
    }

    function setPrice(
        uint256 _price
    ) external {
        oraclePrice = _price;
    }

}

/// @title Security Attack Vectors - TDD Failing Tests
/// @notice All tests assert CORRECT behavior and FAIL until fixes are applied
contract SecurityAttackVectorsTest is Test {

    uint256 constant CAP = 200_000_000; // $2.00 in 8 decimals

    // ===========================================
    // FINDING #2: MorphoOracle CAP Boundary
    // ===========================================
    // Bug: At exactly CAP, bullOracle.price() returns 0
    // Impact: Morpho sees collateral as $0 → instant liquidation
    // Fix: Return minimal non-zero value (1) at exact CAP

    function test_SECURITY_F2_MorphoOracle_ShouldNotReturnZeroAtCAP() public {
        MockOracle basket = new MockOracle(int256(CAP), "Basket");
        MorphoOracle bullOracle = new MorphoOracle(address(basket), CAP, true);

        uint256 price = bullOracle.price();

        // EXPECTED: price > 0 (minimal non-zero to prevent liquidation cliff)
        // CURRENT BUG: price == 0
        assertGt(price, 0, "F2: Price must not be 0 at exact CAP");
    }

    function test_SECURITY_F2_MorphoOracle_NoPriceCliffAtCAP() public {
        MockOracle basket = new MockOracle(int256(CAP - 1), "Basket");
        MorphoOracle bullOracle = new MorphoOracle(address(basket), CAP, true);

        uint256 priceBelowCAP = bullOracle.price();
        assertGt(priceBelowCAP, 0, "Price below CAP is positive");

        basket.updatePrice(int256(CAP));
        uint256 priceAtCAP = bullOracle.price();

        // EXPECTED: priceAtCAP > 0 (graceful degradation, not cliff)
        // CURRENT BUG: priceAtCAP == 0 (instant cliff)
        assertGt(priceAtCAP, 0, "F2: Price must not cliff to 0 at CAP");
    }

    // ===========================================
    // FINDING #3: BasketOracle Deviation Asymmetry
    // ===========================================
    // Bug: Uses MIN(theoretical, spot) as base for threshold
    // Impact: 2% below reverts, 2% above passes (asymmetric)
    // Fix: Use MAX for symmetric tolerance

    function test_SECURITY_F3_BasketOracle_DeviationMustBeSymmetric() public {
        MockOracle feedEUR = new MockOracle(110_000_000, "EUR/USD");
        MockOracle feedJPY = new MockOracle(1_000_000, "JPY/USD");

        address[] memory feeds = new address[](2);
        feeds[0] = address(feedEUR);
        feeds[1] = address(feedJPY);

        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 0.5 ether;
        quantities[1] = 50 ether;

        // theoreticalBear = 0.95 ether
        BasketOracle basket = new BasketOracle(feeds, quantities, 200, 2e8, address(this));

        // 2% above: 0.95 * 1.02 = 0.969 ether - this PASSES with current code
        MockCurvePool curvePool = new MockCurvePool(0.969 ether);
        basket.setCurvePool(address(curvePool));
        basket.latestRoundData(); // passes

        // 2% below: 0.95 * 0.98 = 0.931 ether
        curvePool.setPrice(0.931 ether);

        // EXPECTED: Should also pass (symmetric 2% tolerance)
        // CURRENT BUG: Reverts because MIN-based threshold is smaller
        basket.latestRoundData();
    }

    // ===========================================
    // FINDING #10: MorphoOracle Missing Staleness
    // ===========================================
    // Bug: No staleness check on oracle data
    // Impact: Stale prices used for liquidation decisions
    // Fix: Add 8-hour staleness check with revert

    function test_SECURITY_F10_MorphoOracle_MustRevertOnStalePrice() public {
        vm.warp(1_735_689_600);

        MockOracle basket = new MockOracle(100_000_000, "Basket");
        MorphoOracle bearOracle = new MorphoOracle(address(basket), CAP, false);

        // Set timestamp to 9 hours ago (beyond 8-hour threshold)
        basket.setUpdatedAt(block.timestamp - 9 hours);

        // EXPECTED: Should revert with staleness error
        // CURRENT BUG: Accepts stale price without checking
        vm.expectRevert();
        bearOracle.price();
    }

    // ===========================================
    // FINDING #8: SyntheticSplitter Withdrawal Rounding
    // ===========================================
    // Bug: _withdrawFromAdapter does sharesToRedeem += 1
    // Impact: If shares + 1 > maxRedeem, redeem fails
    // Fix: Cap sharesToRedeem at maxRedeem

    function test_SECURITY_F8_WithdrawRounding_PlusOneExceedsMaxRedeem() public {
        vm.warp(1_735_689_600);

        MockUSDC usdc = new MockUSDC();
        MockOracle oracle = new MockOracle(100_000_000, "Basket");
        address treasury = address(0x999);

        uint64 nonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), nonce + 1);
        MockYieldAdapter adapter = new MockYieldAdapter(IERC20(address(usdc)), address(this), predictedSplitter);
        SyntheticSplitter splitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(0));

        address alice = address(0x1);
        usdc.mint(alice, 1000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(splitter), 1000 * 1e6);
        splitter.mint(500 * 1e18);
        vm.stopPrank();

        // Mock withdraw to always fail, forcing the redeem fallback path
        vm.mockCallRevert(address(adapter), abi.encodeWithSelector(IERC4626.withdraw.selector), "WITHDRAW_DISABLED");

        // Burn all tokens - requires full adapter withdrawal (900e6 USDC)
        // Splitter has 900e6 shares, convertToShares(900e6) = 900e6
        // Bug: sharesToRedeem = 900e6 + 1 = 900000001, but maxRedeem = 900000000
        vm.startPrank(alice);

        // EXPECTED: Should succeed even when sharesToRedeem + 1 > maxRedeem
        // CURRENT BUG: Reverts because redeem(shares + 1) exceeds available shares
        splitter.burn(500 * 1e18);

        vm.stopPrank();
    }

}
