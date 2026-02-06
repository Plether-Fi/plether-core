// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {IIrm, MorphoBalancesLib} from "../src/libraries/MorphoBalancesLib.sol";
import {Test} from "forge-std/Test.sol";

contract MorphoBalancesHarness {

    using MorphoBalancesLib for IMorpho;

    function expectedTotalSupplyAssets(
        IMorpho morpho,
        MarketParams memory marketParams
    ) external view returns (uint256) {
        return morpho.expectedTotalSupplyAssets(marketParams);
    }

    function expectedSupplyAssets(
        IMorpho morpho,
        MarketParams memory marketParams,
        uint256 shares
    ) external view returns (uint256) {
        return morpho.expectedSupplyAssets(marketParams, shares);
    }

}

contract MockIrm is IIrm {

    uint256 public rate;

    constructor(
        uint256 _rate
    ) {
        rate = _rate;
    }

    function borrowRateView(
        MarketParams memory,
        IMorpho.MarketState memory
    ) external view override returns (uint256) {
        return rate;
    }

}

contract MockMorphoForBalances {

    struct MarketData {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    mapping(bytes32 => MarketData) internal markets;

    function setMarket(
        bytes32 id,
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint128 lastUpdate,
        uint128 fee
    ) external {
        markets[id] =
            MarketData(totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee);
    }

    function market(
        bytes32 id
    ) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        MarketData memory m = markets[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee);
    }

}

contract MorphoBalancesLibTest is Test {

    MorphoBalancesHarness harness;
    MockMorphoForBalances mockMorpho;
    MockIrm irm;

    MarketParams params;
    bytes32 marketId;

    uint256 constant WAD = 1e18;

    function setUp() public {
        harness = new MorphoBalancesHarness();
        mockMorpho = new MockMorphoForBalances();
        irm = new MockIrm(0.05e18); // 5% per second for easy math

        params = MarketParams({
            loanToken: address(0x1),
            collateralToken: address(0x2),
            oracle: address(0x3),
            irm: address(irm),
            lltv: 0.9e18
        });
        marketId = keccak256(abi.encode(params));
    }

    function test_ExpectedTotalSupply_ElapsedZero() public {
        mockMorpho.setMarket(
            marketId,
            1000e6, // totalSupplyAssets
            1000e6, // totalSupplyShares
            500e6, // totalBorrowAssets (non-zero)
            500e6, // totalBorrowShares
            uint128(block.timestamp), // lastUpdate = now → elapsed = 0
            0
        );

        uint256 result = harness.expectedTotalSupplyAssets(IMorpho(address(mockMorpho)), params);
        assertEq(result, 1000e6);
    }

    function test_ExpectedTotalSupply_TotalBorrowAssetsZero() public {
        vm.warp(100);
        mockMorpho.setMarket(
            marketId,
            1000e6,
            1000e6,
            0, // totalBorrowAssets = 0
            0,
            uint128(block.timestamp - 10), // elapsed = 10
            0
        );

        uint256 result = harness.expectedTotalSupplyAssets(IMorpho(address(mockMorpho)), params);
        assertEq(result, 1000e6);
    }

    function test_ExpectedTotalSupply_AccruesInterest() public {
        vm.warp(100);
        // rate = 0.05e18, borrows = 1000e6, elapsed = 10, fee = 0
        // interest = 1000e6 * 0.05e18 * 10 / 1e18 = 500e6
        // feeAmount = 0, supplyInterest = 500e6
        // result = 2000e6 + 500e6 = 2500e6
        mockMorpho.setMarket(
            marketId,
            2000e6,
            2000e6,
            1000e6,
            1000e6,
            uint128(block.timestamp - 10),
            0 // no fee
        );

        uint256 result = harness.expectedTotalSupplyAssets(IMorpho(address(mockMorpho)), params);
        assertEq(result, 2500e6);
    }

    function test_ExpectedTotalSupply_AccruesInterestWithFee() public {
        vm.warp(100);
        // rate = 0.05e18, borrows = 1000e6, elapsed = 10, fee = 0.1e18 (10%)
        // interest = 1000e6 * 0.05e18 * 10 / 1e18 = 500e6
        // feeAmount = 500e6 * 0.1e18 / 1e18 = 50e6
        // supplyInterest = 500e6 - 50e6 = 450e6
        // result = 2000e6 + 450e6 = 2450e6
        mockMorpho.setMarket(
            marketId,
            2000e6,
            2000e6,
            1000e6,
            1000e6,
            uint128(block.timestamp - 10),
            uint128(0.1e18) // 10% fee
        );

        uint256 result = harness.expectedTotalSupplyAssets(IMorpho(address(mockMorpho)), params);
        assertEq(result, 2450e6);
    }

    function test_ExpectedSupplyAssets_SharesZero() public {
        mockMorpho.setMarket(marketId, 1000e6, 1000e6, 0, 0, uint128(block.timestamp), 0);

        uint256 result = harness.expectedSupplyAssets(IMorpho(address(mockMorpho)), params, 0);
        assertEq(result, 0);
    }

    function test_ExpectedSupplyAssets_TotalSupplySharesZero() public {
        mockMorpho.setMarket(marketId, 0, 0, 0, 0, uint128(block.timestamp), 0);

        uint256 result = harness.expectedSupplyAssets(IMorpho(address(mockMorpho)), params, 500e6);
        assertEq(result, 500e6);
    }

    function test_ExpectedSupplyAssets_ProRata() public {
        vm.warp(100);
        // totalSupplyAssets=2000e6, totalSupplyShares=1000e6
        // borrows=0, elapsed=0 → expectedTotal = 2000e6
        // shares=250e6 → 250e6 * 2000e6 / 1000e6 = 500e6
        mockMorpho.setMarket(marketId, 2000e6, 1000e6, 0, 0, uint128(block.timestamp), 0);

        uint256 result = harness.expectedSupplyAssets(IMorpho(address(mockMorpho)), params, 250e6);
        assertEq(result, 500e6);
    }

}
