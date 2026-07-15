// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

interface IRecoverySplitter {

    function owner() external view returns (address);
    function paused() external view returns (bool);
    function treasury() external view returns (address);
    function yieldAdapter() external view returns (IERC4626);
    function BEAR() external view returns (IERC20);
    function BULL() external view returns (IERC20);
    function CAP() external view returns (uint256);
    function USDC_MULTIPLIER() external view returns (uint256);
    function unpause() external;
    function harvestYield() external;
    function ejectLiquidity() external;

}

interface IRecoveryRewardDistributor {

    function STAKED_BEAR() external view returns (address);
    function STAKED_BULL() external view returns (address);
    function lastDistributionTime() external view returns (uint256);

    function distributeRewardsWithPriceUpdate(
        bytes[] calldata pythUpdateData
    ) external payable returns (uint256 callerReward);

}

interface IRecoveryPythAdapter {

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint256 fee);

}

/// @notice Replays the proposed four-transaction recovery bundle against the
/// exact deployed Ethereum mainnet contracts and current mainnet state.
contract MainnetRecoveryBundleForkTest is Test {

    address internal constant OWNER = 0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B;
    address internal constant SPLITTER_ADDRESS = 0x81D7f6eE951f5272043de05E6EE25c58a440c2DF;
    address internal constant REWARD_DISTRIBUTOR_ADDRESS = 0x34558F6eC05F91773b7d269f50ce0bbeC4403760;
    address internal constant PYTH_ADAPTER_ADDRESS = 0xEf0e44465a18f848165Bf1A007BE51f628a6FC06;
    address internal constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    IRecoverySplitter internal constant SPLITTER = IRecoverySplitter(SPLITTER_ADDRESS);
    IRecoveryRewardDistributor internal constant DISTRIBUTOR = IRecoveryRewardDistributor(REWARD_DISTRIBUTOR_ADDRESS);
    IRecoveryPythAdapter internal constant PYTH_ADAPTER = IRecoveryPythAdapter(PYTH_ADAPTER_ADDRESS);
    IERC20 internal constant USDC = IERC20(USDC_ADDRESS);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function test_RecoveryBundle_UnpauseHarvestDistributeEject() public {
        bytes[] memory pythUpdateData = new bytes[](1);
        pythUpdateData[0] = vm.envBytes("PYTH_UPDATE_DATA");
        uint256 pythPublishTime = vm.envUint("PYTH_PUBLISH_TIME");
        if (block.timestamp <= pythPublishTime) {
            vm.warp(pythPublishTime + 1);
        }
        uint256 pythFee = PYTH_ADAPTER.getUpdateFee(pythUpdateData);

        assertTrue(SPLITTER.paused(), "precondition: splitter must be paused");
        assertEq(SPLITTER.owner(), OWNER, "precondition: unexpected splitter owner");

        IERC4626 yieldAdapter = SPLITTER.yieldAdapter();
        address stakedBear = DISTRIBUTOR.STAKED_BEAR();
        address stakedBull = DISTRIBUTOR.STAKED_BULL();
        IERC20 bear = SPLITTER.BEAR();
        IERC20 bull = SPLITTER.BULL();

        uint256 distributorUsdcBefore = USDC.balanceOf(address(DISTRIBUTOR));
        uint256 ownerUsdcBefore = USDC.balanceOf(OWNER);
        uint256 treasuryUsdcBefore = USDC.balanceOf(SPLITTER.treasury());
        uint256 stakedBearUnderlyingBefore = bear.balanceOf(stakedBear);
        uint256 stakedBullUnderlyingBefore = bull.balanceOf(stakedBull);

        assertGt(distributorUsdcBefore, 0, "precondition: distributor has no USDC");

        vm.deal(OWNER, 1 ether);
        vm.startPrank(OWNER);
        SPLITTER.unpause();
        SPLITTER.harvestYield();
        DISTRIBUTOR.distributeRewardsWithPriceUpdate{value: pythFee}(pythUpdateData);
        SPLITTER.ejectLiquidity();
        vm.stopPrank();

        uint256 splitterUsdcAfter = USDC.balanceOf(address(SPLITTER));
        uint256 requiredBacking = (bear.totalSupply() * SPLITTER.CAP()) / SPLITTER.USDC_MULTIPLIER();
        uint256 backingDeficit = requiredBacking > splitterUsdcAfter ? requiredBacking - splitterUsdcAfter : 0;
        uint256 stakedBearIncrease = bear.balanceOf(stakedBear) - stakedBearUnderlyingBefore;
        uint256 stakedBullIncrease = bull.balanceOf(stakedBull) - stakedBullUnderlyingBefore;

        assertTrue(SPLITTER.paused(), "eject must leave splitter paused");
        assertEq(yieldAdapter.balanceOf(address(SPLITTER)), 0, "adapter shares must be fully ejected");
        assertLe(backingDeficit, 1, "backing deficit exceeds known one-micro-USDC adapter dust");
        assertEq(USDC.balanceOf(address(DISTRIBUTOR)), 0, "all distributor USDC must be consumed");
        assertGt(USDC.balanceOf(OWNER), ownerUsdcBefore, "owner must receive both caller incentives");
        assertGt(USDC.balanceOf(SPLITTER.treasury()), treasuryUsdcBefore, "treasury must receive harvested yield");
        assertGt(stakedBearIncrease + stakedBullIncrease, 0, "staking vaults must receive rewards");
        assertEq(DISTRIBUTOR.lastDistributionTime(), block.timestamp, "distribution timestamp not updated");

        console2.log("RewardDistributor USDC distributed", distributorUsdcBefore);
        console2.log("Pyth update fee", pythFee);
        console2.log("BEAR staking reward", stakedBearIncrease);
        console2.log("BULL staking reward", stakedBullIncrease);
        console2.log("Splitter USDC after final eject", splitterUsdcAfter);
        console2.log("Required USDC backing", requiredBacking);
        console2.log("Final backing deficit", backingDeficit);
    }

}
