// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {ZapRouter} from "../../src/ZapRouter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {BaseForkTest} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

/// @title Yield Integration Fork Tests
/// @notice E2E test proving real Morpho vault yield flows through the full pipeline:
/// VaultAdapter → harvestYield → RewardDistributor → StakedToken → increased share price
contract YieldIntegrationForkTest is BaseForkTest {

    RewardDistributor distributor;
    StakedToken stBear;
    StakedToken stBull;
    ZapRouter zapRouter;

    address treasury;
    address alice = address(0xA11CE);

    uint256 aliceBearShares;
    uint256 aliceBullShares;

    function setUp() public {
        _setupFork();
        treasury = makeAddr("treasury");
        deal(USDC, address(this), 50_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(treasury);

        _mintInitialTokens(2_000_000e18);

        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");
        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

        _deployCurvePool(1_500_000e18);

        zapRouter = new ZapRouter(address(splitter), bearToken, bullToken, USDC, curvePool);

        distributor = new RewardDistributor(
            address(splitter),
            USDC,
            bearToken,
            bullToken,
            address(stBear),
            address(stBull),
            curvePool,
            address(zapRouter),
            address(basketOracle),
            address(0)
        );

        // Wire staking address via governance timelock
        splitter.proposeFeeReceivers(treasury, address(distributor));
        _warpAndRefreshOracle(7 days);
        splitter.finalizeFeeReceivers();

        // Alice mints tokens and stakes into both vaults
        uint256 aliceMint = 100_000e18;
        deal(USDC, alice, 1_000_000e6);

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(aliceMint);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(aliceMint);

        IERC20(bearToken).approve(address(stBear), aliceMint);
        aliceBearShares = stBear.deposit(aliceMint, alice);

        IERC20(bullToken).approve(address(stBull), aliceMint);
        aliceBullShares = stBull.deposit(aliceMint, alice);
        vm.stopPrank();

        // Push USDC to Morpho vault for yield generation
        splitter.deployToAdapter();
    }

    function _warpAndRefreshOracle(
        uint256 duration
    ) internal {
        vm.warp(block.timestamp + duration);
        (, int256 clPrice,,,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        vm.mockCall(
            CL_EUR,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), clPrice, uint256(0), block.timestamp, uint80(1))
        );
    }

    /// @notice Full pipeline: Morpho yield → harvest → distribute → staker share price increases
    function test_YieldToStakers_EndToEnd() public {
        uint256 bearValueBefore = stBear.convertToAssets(aliceBearShares);
        uint256 bullValueBefore = stBull.convertToAssets(aliceBullShares);
        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);

        // 30 days of real Morpho vault yield accrual
        _warpAndRefreshOracle(30 days);

        // Harvest: 0.1% caller, 20% treasury, 79.9% to RewardDistributor
        splitter.harvestYield();

        uint256 distributorUsdc = IERC20(USDC).balanceOf(address(distributor));
        assertGt(distributorUsdc, 0, "RewardDistributor should have USDC from harvest");

        // Distribute: USDC → mint BEAR+BULL pairs → donateYield to StakedTokens
        distributor.distributeRewards();

        // Stream fully vests after 1 hour
        _warpAndRefreshOracle(1 hours);

        uint256 bearValueAfter = stBear.convertToAssets(aliceBearShares);
        uint256 bullValueAfter = stBull.convertToAssets(aliceBullShares);

        assertGt(bearValueAfter, bearValueBefore, "Staked BEAR value should increase");
        assertGt(bullValueAfter, bullValueBefore, "Staked BULL value should increase");

        uint256 treasuryAfter = IERC20(USDC).balanceOf(treasury);
        assertGt(treasuryAfter, treasuryBefore, "Treasury should receive yield");

        console.log("Yield E2E results:");
        console.log("  Distributor USDC:", distributorUsdc);
        console.log("  BEAR value delta:", bearValueAfter - bearValueBefore);
        console.log("  BULL value delta:", bullValueAfter - bullValueBefore);
        console.log("  Treasury gain:", treasuryAfter - treasuryBefore);
    }

    /// @notice Three consecutive harvest cycles produce cumulative staker gains
    function test_MultipleCycles_CumulativeYield() public {
        uint256[] memory bearValues = new uint256[](4);
        uint256[] memory bullValues = new uint256[](4);
        uint256[] memory treasuryBalances = new uint256[](4);

        bearValues[0] = stBear.convertToAssets(aliceBearShares);
        bullValues[0] = stBull.convertToAssets(aliceBullShares);
        treasuryBalances[0] = IERC20(USDC).balanceOf(treasury);

        for (uint256 i = 1; i <= 3; i++) {
            _warpAndRefreshOracle(30 days);
            splitter.harvestYield();
            distributor.distributeRewards();
            _warpAndRefreshOracle(1 hours);

            bearValues[i] = stBear.convertToAssets(aliceBearShares);
            bullValues[i] = stBull.convertToAssets(aliceBullShares);
            treasuryBalances[i] = IERC20(USDC).balanceOf(treasury);
        }

        for (uint256 i = 1; i <= 3; i++) {
            assertGt(bearValues[i], bearValues[i - 1], "BEAR value should increase each cycle");
            assertGt(bullValues[i], bullValues[i - 1], "BULL value should increase each cycle");
            assertGt(treasuryBalances[i], treasuryBalances[i - 1], "Treasury should grow each cycle");
        }

        console.log("Multi-cycle results (3 rounds):");
        console.log("  BEAR start:", bearValues[0], "end:", bearValues[3]);
        console.log("  BULL start:", bullValues[0], "end:", bullValues[3]);
        console.log("  Treasury start:", treasuryBalances[0], "end:", treasuryBalances[3]);
    }

}
