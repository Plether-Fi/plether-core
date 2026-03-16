// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IRewardDistributor} from "../src/interfaces/IRewardDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

/// @title SimulateDistribution
/// @notice Simulates harvestYield → distributeRewards flow on a mainnet fork.
/// @dev Uses current on-chain state (no time warp). Mocks oracles fresh to avoid staleness reverts.
///      Usage: source .env && forge script script/SimulateDistribution.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract SimulateDistribution is Script {

    address constant SPLITTER = 0x81D7f6eE951f5272043de05E6EE25c58a440c2DF;
    address constant RD = 0x34558F6eC05F91773b7d269f50ce0bbeC4403760;
    address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant BEAR_ADDR = 0xEDE56A22771c7fDA8b80Cc1A1fa2B54420cD4A5d;
    address constant BULL_ADDR = 0xF20D4E93ee2F3948E4aE998F7C3A5Ec9E0aBD4c4;
    address constant STAKED_BEAR = 0x4f7310E8bDa646A7DA4b8F1bBE83073380C5Dc53;
    address constant STAKED_BULL = 0x3B859C74d628dAe76C95fA3b2A9d1A50aB153E2D;
    address constant TREASURY = 0x8f30b1C4e425087545df14e445Eb43cF339f3C9C;
    address constant PYTH_ADAPTER = 0xEf0e44465a18f848165Bf1A007BE51f628a6FC06;
    address constant ORACLE = 0xfFc35FD33C2acF241F6e46625C7571D64f8AddbD;
    address constant OWNER = 0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B;
    address constant INVAR_COIN = 0x125B1F77Ef927eFf08EDd362c00BF059FFD9d3E6;

    IERC20 constant USDC = IERC20(USDC_ADDR);
    IERC20 constant BEAR = IERC20(BEAR_ADDR);
    IERC20 constant BULL = IERC20(BULL_ADDR);

    function run() external {
        console2.log("");
        console2.log("=============================================");
        console2.log("  HARVEST + DISTRIBUTE SIMULATION");
        console2.log("=============================================");

        address caller = address(0xBEEF);
        vm.deal(caller, 1 ether);

        _mockOraclesFresh();

        _maybeFinalizeFees();

        _snapshot("CURRENT STATE");

        (bool canHarvest, uint256 surplus,,,) = SyntheticSplitter(SPLITTER).previewHarvest();

        console2.log(string.concat("  Current surplus: ", _fmtUsdc(surplus)));

        if (!canHarvest) {
            console2.log("  Below $50 threshold - cannot harvest yet.");
            console2.log("");
            console2.log("=============================================");
            return;
        }

        console2.log("");
        console2.log("--- Step 1: harvestYield() ---");

        uint256 rdBefore = USDC.balanceOf(RD);
        uint256 treasuryBefore = USDC.balanceOf(TREASURY);
        uint256 callerBefore = USDC.balanceOf(caller);

        vm.prank(caller);
        SyntheticSplitter(SPLITTER).harvestYield();

        uint256 rdGot = USDC.balanceOf(RD) - rdBefore;
        uint256 treasuryGot = USDC.balanceOf(TREASURY) - treasuryBefore;
        uint256 callerGot = USDC.balanceOf(caller) - callerBefore;
        uint256 totalHarvested = rdGot + treasuryGot + callerGot;

        console2.log(string.concat("  Total harvested:     ", _fmtUsdc(totalHarvested)));
        console2.log(string.concat("  Caller reward (0.1%): ", _fmtUsdc(callerGot)));
        console2.log(string.concat("  Treasury (20%):      ", _fmtUsdc(treasuryGot)));
        console2.log(string.concat("  -> RewardDist (80%): ", _fmtUsdc(rdGot)));

        console2.log("");
        console2.log("--- Step 2: distributeRewards() ---");

        (uint256 bearPct, uint256 bullPct,,) = IRewardDistributor(RD).previewDistribution();

        console2.log(string.concat("  BEAR allocation: ", vm.toString(bearPct / 100), ".", _pad2(bearPct % 100), "%"));
        console2.log(string.concat("  BULL allocation: ", vm.toString(bullPct / 100), ".", _pad2(bullPct % 100), "%"));

        uint256 rdUsdc = USDC.balanceOf(RD);
        uint256 sBearBefore = BEAR.balanceOf(STAKED_BEAR);
        uint256 sBullBefore = BULL.balanceOf(STAKED_BULL);
        uint256 callerBefore2 = USDC.balanceOf(caller);
        uint256 invarBefore = USDC.balanceOf(INVAR_COIN);

        vm.prank(caller);
        IRewardDistributor(RD).distributeRewards();

        uint256 bearDonated = BEAR.balanceOf(STAKED_BEAR) - sBearBefore;
        uint256 bullDonated = BULL.balanceOf(STAKED_BULL) - sBullBefore;
        uint256 callerReward2 = USDC.balanceOf(caller) - callerBefore2;
        uint256 invarGot = USDC.balanceOf(INVAR_COIN) - invarBefore;
        uint256 rdUsdcAfter = USDC.balanceOf(RD);

        console2.log("");
        console2.log(string.concat("  USDC distributed:      ", _fmtUsdc(rdUsdc - rdUsdcAfter)));
        console2.log(string.concat("  Caller reward (0.1%):  ", _fmtUsdc(callerReward2)));
        console2.log(string.concat("  USDC -> InvarCoin:     ", _fmtUsdc(invarGot)));
        console2.log(string.concat("  BEAR -> StakedBear:    ", _fmtToken(bearDonated)));
        console2.log(string.concat("  BULL -> StakedBull:    ", _fmtToken(bullDonated)));
        console2.log(string.concat("  USDC dust in RD:       ", _fmtUsdc(rdUsdcAfter)));

        _snapshot("AFTER DISTRIBUTION");

        console2.log("");
        console2.log("=============================================");
    }

    function _mockOraclesFresh() internal {
        vm.mockCall(
            PYTH_ADAPTER,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(9_500_000), block.timestamp, block.timestamp, uint80(1))
        );

        (, int256 oraclePrice,,,) = AggregatorV3Interface(ORACLE).latestRoundData();
        if (oraclePrice <= 0) {
            oraclePrice = int256(99_000_000);
        }

        vm.mockCall(
            ORACLE,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), oraclePrice, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _maybeFinalizeFees() internal {
        if (SyntheticSplitter(SPLITTER).staking() != address(0)) {
            return;
        }
        vm.prank(OWNER);
        SyntheticSplitter(SPLITTER).finalizeFeeReceivers();
    }

    function _snapshot(
        string memory label
    ) internal view {
        console2.log("");
        console2.log(string.concat("--- ", label, " ---"));
        console2.log(string.concat("  Splitter USDC:  ", _fmtUsdc(USDC.balanceOf(SPLITTER))));
        console2.log(string.concat("  RD USDC:        ", _fmtUsdc(USDC.balanceOf(RD))));
        console2.log(string.concat("  Treasury USDC:  ", _fmtUsdc(USDC.balanceOf(TREASURY))));
        console2.log(string.concat("  StakedBear BAL: ", _fmtToken(BEAR.balanceOf(STAKED_BEAR))));
        console2.log(string.concat("  StakedBull BAL: ", _fmtToken(BULL.balanceOf(STAKED_BULL))));
    }

    function _fmtUsdc(
        uint256 v
    ) internal pure returns (string memory) {
        return string.concat("$", vm.toString(v / 1e6), ".", _pad2(v % 1e6 / 1e4));
    }

    function _fmtToken(
        uint256 v
    ) internal pure returns (string memory) {
        return string.concat(vm.toString(v / 1e18), ".", _pad2(v % 1e18 / 1e16));
    }

    function _pad2(
        uint256 v
    ) internal pure returns (string memory) {
        if (v < 10) {
            return string.concat("0", vm.toString(v));
        }
        return vm.toString(v);
    }

}
