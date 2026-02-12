// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {StakedToken} from "../../src/StakedToken.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {MorphoOracle} from "../../src/oracles/MorphoOracle.sol";
import {StakedOracle} from "../../src/oracles/StakedOracle.sol";
import {BaseForkTest} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MorphoBorrowInvariantFork
/// @notice Verifies that borrowing against BEAR+BULL collateral never yields more USDC than the mint cost.
/// BEAR price + BULL price = CAP, so combined collateral value = mint cost.
/// With any LLTV < 100%, max borrow must be strictly less than mint cost.
contract MorphoBorrowInvariantFork is BaseForkTest {

    StakedToken stBear;
    StakedToken stBull;

    MorphoOracle morphoOracleBear;
    MorphoOracle morphoOracleBull;
    StakedOracle stakedOracleBear;
    StakedOracle stakedOracleBull;

    MarketParams bearMarket;
    MarketParams bullMarket;

    uint256 constant CAP = 2e8;
    uint256 constant LLTV = 915_000_000_000_000_000; // 91.5%

    address alice = address(0xA11CE);

    function setUp() public {
        _setupFork();
        deal(USDC, address(this), 10_000_000e6);
        deal(USDC, alice, 1_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");
        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

        morphoOracleBear = new MorphoOracle(address(basketOracle), CAP, false);
        morphoOracleBull = new MorphoOracle(address(basketOracle), CAP, true);
        stakedOracleBear = new StakedOracle(address(stBear), address(morphoOracleBear));
        stakedOracleBull = new StakedOracle(address(stBull), address(morphoOracleBull));

        _mintInitialTokens(500_000e18);

        bearMarket = MarketParams({
            loanToken: USDC,
            collateralToken: address(stBear),
            oracle: address(stakedOracleBear),
            irm: ADAPTIVE_CURVE_IRM,
            lltv: LLTV
        });
        bullMarket = MarketParams({
            loanToken: USDC,
            collateralToken: address(stBull),
            oracle: address(stakedOracleBull),
            irm: ADAPTIVE_CURVE_IRM,
            lltv: LLTV
        });

        IMorpho(MORPHO).createMarket(bearMarket);
        IMorpho(MORPHO).createMarket(bullMarket);

        IERC20(USDC).approve(MORPHO, 4_000_000e6);
        IMorpho(MORPHO).supply(bearMarket, 2_000_000e6, 0, address(this), "");
        IMorpho(MORPHO).supply(bullMarket, 2_000_000e6, 0, address(this), "");
    }

    /// @notice Core invariant: max borrow from both markets < mint cost
    function test_MaxBorrowNeverExceedsMintCost() public {
        uint256 mintAmount = 10_000e18;
        (uint256 mintCost,,) = splitter.previewMint(mintAmount);

        _mintStakeAndDeposit(alice, mintAmount);

        (uint256 maxBorrowBear, uint256 maxBorrowBull) = _maxBorrowable(alice);
        uint256 totalMaxBorrow = maxBorrowBear + maxBorrowBull;

        assertLt(totalMaxBorrow, mintCost, "Combined max borrow must be less than mint cost");
        assertApproxEqRel(totalMaxBorrow, (mintCost * LLTV) / 1e18, 0.01e18);
    }

    /// @notice Actually borrow max from both markets and verify total < mint cost
    function test_ActualBorrowNeverExceedsMintCost() public {
        uint256 mintAmount = 10_000e18;
        (uint256 mintCost,,) = splitter.previewMint(mintAmount);

        _mintStakeAndDeposit(alice, mintAmount);

        (uint256 maxBorrowBear, uint256 maxBorrowBull) = _maxBorrowable(alice);

        uint256 balBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        if (maxBorrowBear > 0) {
            IMorpho(MORPHO).borrow(bearMarket, maxBorrowBear, 0, alice, alice);
        }
        if (maxBorrowBull > 0) {
            IMorpho(MORPHO).borrow(bullMarket, maxBorrowBull, 0, alice, alice);
        }
        vm.stopPrank();
        uint256 totalBorrowed = IERC20(USDC).balanceOf(alice) - balBefore;

        assertLt(totalBorrowed, mintCost, "Actual borrowed must be less than mint cost");
    }

    /// @notice Invariant holds when BEAR is expensive (basket near CAP)
    function test_InvariantHolds_HighBasketPrice() public {
        uint256 highPrice = 180_000_000; // $1.80 basket → BEAR=$1.80, BULL=$0.20
        _mockOraclePriceWithCurve(highPrice);

        uint256 mintAmount = 10_000e18;
        (uint256 mintCost,,) = splitter.previewMint(mintAmount);

        _mintStakeAndDeposit(alice, mintAmount);

        (uint256 maxBorrowBear, uint256 maxBorrowBull) = _maxBorrowable(alice);
        assertLt(maxBorrowBear + maxBorrowBull, mintCost);
    }

    /// @notice Invariant holds when BULL is expensive (basket near zero)
    function test_InvariantHolds_LowBasketPrice() public {
        uint256 lowPrice = 20_000_000; // $0.20 basket → BEAR=$0.20, BULL=$1.80
        _mockOraclePriceWithCurve(lowPrice);

        uint256 mintAmount = 10_000e18;
        (uint256 mintCost,,) = splitter.previewMint(mintAmount);

        _mintStakeAndDeposit(alice, mintAmount);

        (uint256 maxBorrowBear, uint256 maxBorrowBull) = _maxBorrowable(alice);
        assertLt(maxBorrowBear + maxBorrowBull, mintCost);
    }

    /// @notice Invariant holds at balanced price ($1.00)
    function test_InvariantHolds_BalancedPrice() public {
        uint256 balanced = 100_000_000; // $1.00 basket → BEAR=$1.00, BULL=$1.00
        _mockOraclePriceWithCurve(balanced);

        uint256 mintAmount = 10_000e18;
        (uint256 mintCost,,) = splitter.previewMint(mintAmount);

        _mintStakeAndDeposit(alice, mintAmount);

        (uint256 maxBorrowBear, uint256 maxBorrowBull) = _maxBorrowable(alice);
        assertLt(maxBorrowBear + maxBorrowBull, mintCost);
    }

    /// @notice After yield accrual, extra borrowing power comes from real yield, not thin air
    function test_ExtraBorrowAfterYieldComesFromRealValue() public {
        uint256 mintAmount = 10_000e18;
        (uint256 mintCost,,) = splitter.previewMint(mintAmount);

        _mintStakeAndDeposit(alice, mintAmount);

        (uint256 maxBorrowBefore,) = _totalMaxBorrow(alice);

        // Donate 10% yield to BEAR vault
        uint256 yieldAmount = mintAmount / 10;
        deal(bearToken, address(this), yieldAmount);
        IERC20(bearToken).approve(address(stBear), yieldAmount);
        stBear.donateYield(yieldAmount);
        vm.warp(block.timestamp + stBear.STREAM_DURATION());
        _refreshOracle();

        (uint256 maxBorrowAfter,) = _totalMaxBorrow(alice);
        uint256 extraBorrow = maxBorrowAfter - maxBorrowBefore;

        // The extra borrowable USDC should not exceed the dollar value of donated yield
        uint256 yieldValueUsdc = (yieldAmount * bearPrice) / 1e18 / 1e12;
        assertLt(extraBorrow, yieldValueUsdc, "Extra borrow should not exceed yield value");
    }

    /// @notice Recursive borrow→mint→deposit loop converges to theoretical maximum
    function test_RecursiveLeverageIsBounded() public {
        uint256 initialUsdc = 100e6;
        deal(USDC, alice, initialUsdc);

        // Geometric series: max position = initial / (1 - LLTV) ≈ 11.76x
        uint256 maxTheoreticalDebt = (initialUsdc * LLTV) / (1e18 - LLTV);

        for (uint256 i = 0; i < 15; i++) {
            uint256 available = IERC20(USDC).balanceOf(alice);
            if (available < 2e6) {
                break;
            }

            // Each pair costs CAP ($2) in USDC, so tokenAmount = usdcAvailable * 1e12 / 2
            uint256 mintAmount = ((available - 1) * 1e12) / 2;
            if (mintAmount == 0) {
                break;
            }
            (uint256 mintCost,,) = splitter.previewMint(mintAmount);
            if (mintCost == 0 || mintCost > available) {
                break;
            }

            vm.startPrank(alice);
            IERC20(USDC).approve(address(splitter), mintCost);
            splitter.mint(mintAmount);

            IERC20(bearToken).approve(address(stBear), mintAmount);
            uint256 bShares = stBear.deposit(mintAmount, alice);
            IERC20(bullToken).approve(address(stBull), mintAmount);
            uint256 uShares = stBull.deposit(mintAmount, alice);

            IERC20(address(stBear)).approve(MORPHO, bShares);
            IMorpho(MORPHO).supplyCollateral(bearMarket, bShares, alice, "");
            IERC20(address(stBull)).approve(MORPHO, uShares);
            IMorpho(MORPHO).supplyCollateral(bullMarket, uShares, alice, "");

            (uint256 maxBear, uint256 maxBull) = _maxBorrowable(alice);
            uint256 debtBear = _currentDebt(bearMarket, alice);
            uint256 debtBull = _currentDebt(bullMarket, alice);
            uint256 addlBear = maxBear > debtBear ? ((maxBear - debtBear) * 99) / 100 : 0;
            uint256 addlBull = maxBull > debtBull ? ((maxBull - debtBull) * 99) / 100 : 0;

            if (addlBear > 0) {
                IMorpho(MORPHO).borrow(bearMarket, addlBear, 0, alice, alice);
            }
            if (addlBull > 0) {
                IMorpho(MORPHO).borrow(bullMarket, addlBull, 0, alice, alice);
            }
            vm.stopPrank();
        }

        uint256 totalDebt = _currentDebt(bearMarket, alice) + _currentDebt(bullMarket, alice);
        assertGt(totalDebt, 0, "Should have borrowed");
        assertLt(totalDebt, maxTheoreticalDebt, "Recursive debt bounded by geometric series");
    }

    /// @notice Conservative position (50% LTV) survives 1 year of interest accrual
    function test_InterestAccrualDoesNotLiquidateConservativePosition() public {
        uint256 mintAmount = 10_000e18;
        _mintStakeAndDeposit(alice, mintAmount);

        (uint256 maxBear, uint256 maxBull) = _maxBorrowable(alice);
        vm.startPrank(alice);
        IMorpho(MORPHO).borrow(bearMarket, maxBear / 2, 0, alice, alice);
        IMorpho(MORPHO).borrow(bullMarket, maxBull / 2, 0, alice, alice);
        vm.stopPrank();

        uint256 debtBefore = _currentDebt(bearMarket, alice) + _currentDebt(bullMarket, alice);

        vm.warp(block.timestamp + 365 days);
        _refreshOracle();
        IMorpho(MORPHO).accrueInterest(bearMarket);
        IMorpho(MORPHO).accrueInterest(bullMarket);

        uint256 debtAfter = _currentDebt(bearMarket, alice) + _currentDebt(bullMarket, alice);
        assertGt(debtAfter, debtBefore, "Interest must accrue over 1 year");

        bytes32 bearId = _marketId(bearMarket);
        bytes32 bullId = _marketId(bullMarket);
        (,, uint128 bearColl) = IMorpho(MORPHO).position(bearId, alice);
        (,, uint128 bullColl) = IMorpho(MORPHO).position(bullId, alice);
        uint256 collateralValue =
            uint256(bearColl) * stakedOracleBear.price() / 1e36 + uint256(bullColl) * stakedOracleBull.price() / 1e36;
        uint256 maxBorrowAfterInterest = (collateralValue * LLTV) / 1e18;

        assertGt(maxBorrowAfterInterest, debtAfter, "50% LTV position must survive 1 year of interest");

        (uint256 mintCost,,) = splitter.previewMint(mintAmount);
        assertLt(debtAfter, mintCost, "Debt after interest must still be less than mint cost");
    }

    // ==========================================
    // HELPERS
    // ==========================================

    /// @dev Same technique as MarketParamsLib.id() — hashes raw struct memory
    function _marketId(
        MarketParams memory mp
    ) internal pure returns (bytes32 id) {
        assembly ("memory-safe") {
            id := keccak256(mp, 160)
        }
    }

    function _currentDebt(
        MarketParams memory mp,
        address user
    ) internal view returns (uint256) {
        bytes32 mid = _marketId(mp);
        (, uint128 borrowShares,) = IMorpho(MORPHO).position(mid, user);
        if (borrowShares == 0) {
            return 0;
        }
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(MORPHO).market(mid);
        if (totalBorrowShares == 0) {
            return 0;
        }
        return (uint256(borrowShares) * uint256(totalBorrowAssets) + uint256(totalBorrowShares) - 1)
            / uint256(totalBorrowShares);
    }

    function _mintStakeAndDeposit(
        address user,
        uint256 mintAmount
    ) internal {
        (uint256 mintCost,,) = splitter.previewMint(mintAmount);
        deal(USDC, user, IERC20(USDC).balanceOf(user) + mintCost);

        vm.startPrank(user);
        IERC20(USDC).approve(address(splitter), mintCost);
        splitter.mint(mintAmount);

        IERC20(bearToken).approve(address(stBear), mintAmount);
        uint256 bearShares = stBear.deposit(mintAmount, user);

        IERC20(bullToken).approve(address(stBull), mintAmount);
        uint256 bullShares = stBull.deposit(mintAmount, user);

        IERC20(address(stBear)).approve(MORPHO, bearShares);
        IMorpho(MORPHO).supplyCollateral(bearMarket, bearShares, user, "");

        IERC20(address(stBull)).approve(MORPHO, bullShares);
        IMorpho(MORPHO).supplyCollateral(bullMarket, bullShares, user, "");
        vm.stopPrank();
    }

    function _maxBorrowable(
        address user
    ) internal view returns (uint256 maxBear, uint256 maxBull) {
        bytes32 bearId = _marketId(bearMarket);
        bytes32 bullId = _marketId(bullMarket);

        (,, uint128 bearCollateral) = IMorpho(MORPHO).position(bearId, user);
        (,, uint128 bullCollateral) = IMorpho(MORPHO).position(bullId, user);

        uint256 bearValue = uint256(bearCollateral) * stakedOracleBear.price() / 1e36;
        uint256 bullValue = uint256(bullCollateral) * stakedOracleBull.price() / 1e36;

        maxBear = (bearValue * LLTV) / 1e18;
        maxBull = (bullValue * LLTV) / 1e18;
    }

    function _totalMaxBorrow(
        address user
    ) internal view returns (uint256 total, uint256 mintCostEquivalent) {
        (uint256 maxBear, uint256 maxBull) = _maxBorrowable(user);
        total = maxBear + maxBull;
    }

    function _mockOraclePrice(
        uint256 price8dec
    ) internal {
        uint256 mockEurUsd = (price8dec * BASE_EUR * 1e10) / 1e18;
        vm.mockCall(
            CL_EUR,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(mockEurUsd), uint256(0), block.timestamp, uint80(1))
        );
    }

    function _mockOraclePriceWithCurve(
        uint256 price8dec
    ) internal {
        _mockOraclePrice(price8dec);
        uint256 curvePrice18 = price8dec * 1e10;
        vm.mockCall(
            address(basketOracle.curvePool()), abi.encodeWithSignature("price_oracle()"), abi.encode(curvePrice18)
        );
    }

    function _refreshOracle() internal {
        (, int256 clPrice,,,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        vm.mockCall(
            CL_EUR,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), clPrice, uint256(0), block.timestamp, uint80(1))
        );
    }

}
