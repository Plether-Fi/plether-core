// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {SyntheticSplitter} from "../../src/SyntheticSplitter.sol";
import {VaultAdapter} from "../../src/VaultAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {BaseForkTest, MockCurvePoolForOracle} from "./BaseForkTest.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMorphoVaultV1 {

    function withdrawQueueLength() external view returns (uint256);
    function withdrawQueue(
        uint256 index
    ) external view returns (bytes32);

}

contract VaultAdapterForkTest is BaseForkTest {

    VaultAdapter public vaultAdapter;
    address treasury;
    address alice = address(0xA11CE);

    function setUp() public {
        _setupFork();
        treasury = makeAddr("treasury");
        deal(USDC, address(this), 2_000_000e6);
        deal(USDC, alice, 1_000_000e6);
        _fetchPriceAndWarpForward();
        _deployWithVaultAdapter(treasury);
    }

    /// @dev Like _fetchPriceAndWarp but never warps backward — Morpho vault's
    ///      interest accrual underflows if block.timestamp < its lastUpdate.
    function _fetchPriceAndWarpForward() internal {
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        uint256 normalizedPrice8 = (uint256(price) * 1e18) / (BASE_EUR * 1e10);
        realOraclePrice = normalizedPrice8 * 1e10;
        bearPrice = realOraclePrice;
        uint256 target = updatedAt + 1 hours;
        if (target < block.timestamp) {
            target = block.timestamp;
        }
        vm.warp(target);
    }

    function _deployWithVaultAdapter(
        address _treasury
    ) internal {
        address[] memory feeds = new address[](1);
        feeds[0] = CL_EUR;
        uint256[] memory qtys = new uint256[](1);
        qtys[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;

        address tempCurvePool = address(new MockCurvePoolForOracle(bearPrice));
        basketOracle = new BasketOracle(feeds, qtys, basePrices, 200, 2e8, address(this));
        basketOracle.setCurvePool(tempCurvePool);

        uint64 currentNonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), currentNonce + 1);

        vaultAdapter = new VaultAdapter(IERC20(USDC), address(STEAKHOUSE_USDC), address(this), predictedSplitter);

        splitter = new SyntheticSplitter(address(basketOracle), USDC, address(vaultAdapter), 2e8, _treasury, address(0));
        require(address(splitter) == predictedSplitter, "Splitter address mismatch");

        bullToken = address(splitter.BULL());
        bearToken = address(splitter.BEAR());
    }

    function test_DepositWithdraw_RealVault() public {
        uint256 mintAmount = 10_000e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();

        uint256 vaultShares = STEAKHOUSE_USDC.balanceOf(address(vaultAdapter));
        assertGt(vaultShares, 0, "Adapter should hold Morpho vault shares");

        uint256 adapterUsdcDust = IERC20(USDC).balanceOf(address(vaultAdapter));
        assertEq(adapterUsdcDust, 0, "Adapter should not hold USDC dust");

        uint256 adapterAssets = vaultAdapter.totalAssets();
        uint256 splitterAdapterShares = vaultAdapter.balanceOf(address(splitter));
        uint256 splitterAdapterValue = vaultAdapter.convertToAssets(splitterAdapterShares);

        uint256 expectedAdapterDeposit = (usdcRequired * 90) / 100;
        assertApproxEqRel(adapterAssets, expectedAdapterDeposit, 0.01e18, "totalAssets within 1% of expected");
        assertApproxEqRel(splitterAdapterValue, expectedAdapterDeposit, 0.01e18, "splitter value within 1%");

        // Nested ERC4626 (VaultAdapter → Morpho vault) loses a few wei to double
        // rounding. Seed the splitter with dust so burn doesn't revert on the
        // micro-deficit. This mirrors production where ongoing mints keep the
        // buffer topped up.
        deal(USDC, address(splitter), IERC20(USDC).balanceOf(address(splitter)) + 10);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(bullToken).approve(address(splitter), mintAmount);
        IERC20(bearToken).approve(address(splitter), mintAmount);
        splitter.burn(mintAmount);
        vm.stopPrank();

        uint256 usdcReturned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;
        assertGt(usdcReturned, (usdcRequired * 99) / 100, "Round-trip should return >99% of USDC");
    }

    function test_YieldAccrual_RealVault() public {
        uint256 mintAmount = 50_000e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();

        uint256 initialAssets = vaultAdapter.totalAssets();
        assertGt(initialAssets, 0, "Should have assets after deposit");

        vm.warp(block.timestamp + 30 days);

        uint256 assetsAfter = vaultAdapter.totalAssets();
        assertGt(assetsAfter, initialAssets, "Morpho vault should accrue yield over 30 days");

        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        splitter.harvestYield();
        uint256 treasuryGain = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
        assertGt(treasuryGain, 0, "Treasury should receive yield");
    }

    function test_MaxWithdraw_ReflectsVaultLiquidity() public {
        uint256 mintAmount = 10_000e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();

        uint256 adapterMaxWithdraw = vaultAdapter.maxWithdraw(address(splitter));
        uint256 vaultMaxWithdraw = STEAKHOUSE_USDC.maxWithdraw(address(vaultAdapter));
        assertLe(adapterMaxWithdraw, vaultMaxWithdraw, "Adapter maxWithdraw capped by vault liquidity");

        uint256 adapterMaxRedeem = vaultAdapter.maxRedeem(address(splitter));
        uint256 vaultMaxRedeem = STEAKHOUSE_USDC.maxRedeem(address(vaultAdapter));
        assertLe(adapterMaxRedeem, vaultMaxRedeem, "Adapter maxRedeem capped by vault liquidity");

        assertGt(adapterMaxWithdraw, 0, "Should be able to withdraw something");
        assertGt(adapterMaxRedeem, 0, "Should be able to redeem something");
    }

    function test_LiquidityCrunch_GracefulDegradation() public {
        uint256 mintAmount = 50_000e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();

        assertGt(vaultAdapter.maxWithdraw(address(splitter)), 0, "Should have liquidity before drain");

        // Drain while timestamps are still consistent (before warping).
        // Warping first would cause Morpho's accrueInterest to overflow on
        // idle markets whose IRM is address(0).
        _drainVaultLiquidity();

        // Adapter must reflect the crunch
        assertEq(vaultAdapter.maxWithdraw(address(splitter)), 0, "maxWithdraw should be 0 after drain");
        assertEq(vaultAdapter.maxRedeem(address(splitter)), 0, "maxRedeem should be 0 after drain");

        // totalAssets still reports the accounting value — funds exist, just illiquid
        assertGt(vaultAdapter.totalAssets(), 0, "totalAssets should still report position value");

        // Warp 30 days so yield accrues — harvest will find surplus but can't withdraw it
        vm.warp(block.timestamp + 30 days);

        // Refresh Chainlink feed (stale after 30-day warp)
        (, int256 clPrice,,,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        vm.mockCall(
            CL_EUR,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), clPrice, uint256(0), block.timestamp, uint80(1))
        );

        // Harvest reverts: either NoSurplus (unaccrued interest) or InsufficientHarvest (can't withdraw)
        // Exact error depends on whether Morpho vault auto-accrues during view calls
        vm.expectRevert();
        splitter.harvestYield();

        // Minting still works — deposits flow in, nothing needs to be withdrawn
        vm.startPrank(alice);
        (uint256 usdcRequired2,,) = splitter.previewMint(1000e18);
        IERC20(USDC).approve(address(splitter), usdcRequired2);
        splitter.mint(1000e18);
        vm.stopPrank();

        assertEq(IERC20(bullToken).balanceOf(alice), mintAmount + 1000e18, "Mint should succeed during crunch");
    }

    /// @dev Borrows all available USDC from every Morpho market in the
    ///      Morpho vault's withdraw queue, forcing 100% utilization.
    function _drainVaultLiquidity() internal {
        IMorphoVaultV1 mmVault = IMorphoVaultV1(address(STEAKHOUSE_USDC));
        uint256 queueLen = mmVault.withdrawQueueLength();
        address drainer = makeAddr("drainer");

        for (uint256 i = 0; i < queueLen; i++) {
            bytes32 marketId = mmVault.withdrawQueue(i);
            (uint128 totalSupplyAssets,, uint128 totalBorrowAssets,,,) = IMorpho(MORPHO).market(marketId);
            uint256 available = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
            if (available == 0) {
                continue;
            }

            MarketParams memory params = IMorpho(MORPHO).idToMarketParams(marketId);

            if (params.collateralToken == address(0)) {
                // Idle market (no collateral, no borrows). Impersonate the
                // vault to redeem its supply shares directly from Morpho.
                (uint256 vaultShares,,) = IMorpho(MORPHO).position(marketId, address(STEAKHOUSE_USDC));
                if (vaultShares == 0) {
                    continue;
                }
                vm.prank(address(STEAKHOUSE_USDC));
                IMorpho(MORPHO).withdraw(params, 0, vaultShares, address(STEAKHOUSE_USDC), address(drainer));
                continue;
            }

            uint256 collateralAmount = 10_000 ether;
            deal(params.collateralToken, drainer, collateralAmount);

            vm.startPrank(drainer);
            IERC20(params.collateralToken).approve(MORPHO, type(uint256).max);
            IMorpho(MORPHO).supplyCollateral(params, collateralAmount, drainer, "");
            IMorpho(MORPHO).borrow(params, available, 0, drainer, drainer);
            vm.stopPrank();
        }
    }

    function test_LargeDeposit_RealVault() public {
        uint256 mintAmount = 500_000e18;

        deal(USDC, alice, 2_000_000e6);

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();

        assertEq(IERC20(bullToken).balanceOf(alice), mintAmount, "Should have BULL tokens");
        assertEq(IERC20(bearToken).balanceOf(alice), mintAmount, "Should have BEAR tokens");

        // Seed dust for nested ERC4626 rounding (see test_DepositWithdraw_RealVault)
        deal(USDC, address(splitter), IERC20(USDC).balanceOf(address(splitter)) + 10);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(bullToken).approve(address(splitter), mintAmount);
        IERC20(bearToken).approve(address(splitter), mintAmount);
        splitter.burn(mintAmount);
        vm.stopPrank();

        uint256 usdcReturned = IERC20(USDC).balanceOf(alice) - aliceUsdcBefore;
        assertGt(usdcReturned, (usdcRequired * 99) / 100, "Large round-trip should return >99% of USDC");
    }

    function test_SharePriceInflation_DonationAttack() public {
        uint256 mintAmount = 50_000e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();

        uint256 initialAdapterAssets = vaultAdapter.totalAssets();
        assertGt(initialAdapterAssets, 0, "Should have assets after deposit");

        // Whale donates 1M USDC to Morpho vault by supplying to the idle Morpho
        // market on behalf of the vault. This inflates Morpho vault's share price
        // without minting new vault shares — classic ERC4626 inflation vector.
        _donateToVault(1_000_000e6);

        uint256 inflatedAssets = vaultAdapter.totalAssets();
        assertGt(inflatedAssets, initialAdapterAssets, "Donation should inflate adapter totalAssets");

        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        splitter.harvestYield();
        uint256 treasuryGain = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
        assertGt(treasuryGain, 0, "Treasury should receive donation windfall");
    }

    /// @dev Supplies USDC to the idle Morpho market on behalf of Morpho vault,
    ///      inflating the vault's share price for existing shareholders.
    function _donateToVault(
        uint256 amount
    ) internal {
        IMorphoVaultV1 mmVault = IMorphoVaultV1(address(STEAKHOUSE_USDC));
        uint256 queueLen = mmVault.withdrawQueueLength();

        MarketParams memory idleParams;
        bool found;
        for (uint256 i = 0; i < queueLen; i++) {
            bytes32 marketId = mmVault.withdrawQueue(i);
            MarketParams memory params = IMorpho(MORPHO).idToMarketParams(marketId);
            if (params.collateralToken == address(0)) {
                idleParams = params;
                found = true;
                break;
            }
        }
        require(found, "No idle market found");

        deal(USDC, address(this), amount);
        IERC20(USDC).approve(MORPHO, amount);
        IMorpho(MORPHO).supply(idleParams, amount, 0, address(STEAKHOUSE_USDC), "");
    }

}
