// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";

/// @notice LP liquidity changes leave trader carry lazy and independent of the pool's stored index.
contract LpLiquidityCarryIndependenceTest is HousePoolAsyncTestBase {

    address private constant TRADER = address(0xCA771);
    address private constant ENTRANT = address(0xCA772);
    uint256 private constant PRICE = 80_000_000;
    uint256 private constant DEPOSIT = 100_000e6;
    uint256 private constant YEAR = 365 days;

    struct CarrySnapshot {
        uint256 index;
        uint64 timestamp;
        bytes32 position;
        uint256 traderCustody;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_AccountExcessDoesNotCheckpointOrCollectCarry() public {
        uint256 started = _openCarryPosition();
        vm.warp(started + YEAR / 2);
        CarrySnapshot memory beforeCarry = _carrySnapshot();
        uint256 assetsBefore = pool.accountedAssets();
        _rejectEngineCarryCheckpoint();

        settlementToken.mint(address(pool), DEPOSIT);
        pool.accountExcess();

        assertEq(pool.accountedAssets(), assetsBefore + DEPOSIT, "the donation becomes accounted pool backing");
        assertEq(pool.excessAssets(), 0);
        _assertCarryUnchanged(beforeCarry);
        _assertFullYearCarry(started);
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_DepositActivationDoesNotCheckpointOrCollectCarry() public {
        uint256 started = _openCarryPosition();
        vm.warp(started + YEAR / 4);
        _refreshMarkForAsyncSettlement();
        _rejectEngineCarryCheckpoint();
        uint256 requestId = _requestAsyncDeposit(juniorVault, ENTRANT, DEPOSIT);
        assertLt(pool.lpEpochStart(requestId), started + YEAR / 2, "the request must mature before settlement");

        // The Router's mark refresh legitimately checkpoints carry. Snapshot only after preparing that mark.
        vm.warp(started + YEAR / 2);
        _refreshMarkForAsyncSettlement();
        vm.warp(vm.getBlockTimestamp() + 1);
        CarrySnapshot memory beforeCarry = _carrySnapshot();
        uint256 assetsBefore = pool.accountedAssets();
        uint256 supplyBefore = juniorVault.totalSupply();
        _settleLpEpochForTest();

        (uint256 assets, uint256 shares,,, bool finalized) = juniorVault.depositEpochs(requestId);
        assertTrue(finalized);
        assertEq(assets, DEPOSIT);
        assertGt(shares, 0, "real activation must mint participating shares");
        assertEq(pool.accountedAssets(), assetsBefore + DEPOSIT);
        assertEq(juniorVault.totalSupply(), supplyBefore + shares);
        assertEq(juniorVault.balanceOf(ENTRANT), 0, "activated shares are held in claim escrow");
        _assertCarryUnchanged(beforeCarry);
        assertEq(_claimAsyncDeposit(juniorVault, requestId, ENTRANT), shares);
        assertEq(juniorVault.balanceOf(ENTRANT), shares);
        _assertCarryUnchanged(beforeCarry);
        _assertFullYearCarry(started);
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_RedemptionFundingDoesNotCheckpointOrCollectCarry() public {
        uint256 started = _openCarryPosition();
        vm.warp(started + YEAR / 4);
        _refreshMarkForAsyncSettlement();
        _rejectEngineCarryCheckpoint();
        uint256 shares = juniorVault.balanceOf(address(this)) / 10;
        uint256 requestId = _requestAsyncRedeem(juniorVault, address(this), shares);
        assertLt(pool.lpEpochStart(requestId), started + YEAR / 2);

        vm.warp(started + YEAR / 2);
        _refreshMarkForAsyncSettlement();
        vm.warp(vm.getBlockTimestamp() + 1);
        CarrySnapshot memory beforeCarry = _carrySnapshot();
        uint256 assetsBefore = pool.accountedAssets();
        uint256 supplyBefore = juniorVault.totalSupply();
        uint256 escrowBefore = juniorVault.withdrawalEscrowAssets();
        _settleLpEpochForTest();

        (, uint256 fundedShares, uint256 fundedAssets,,,,,,,) = juniorVault.redeemEpochs(requestId);
        assertEq(fundedShares, shares, "the pool has enough unreserved backing to fund this request fully");
        assertGt(fundedAssets, 0);
        assertEq(pool.accountedAssets(), assetsBefore - fundedAssets);
        assertEq(juniorVault.totalSupply(), supplyBefore - shares, "funding burns the requested LP shares once");
        assertEq(juniorVault.withdrawalEscrowAssets(), escrowBefore + fundedAssets);
        _assertCarryUnchanged(beforeCarry);
        (uint256 claimedShares, uint256 claimedAssets) = _claimAsyncRedeem(juniorVault, requestId, address(this));
        assertEq(claimedShares, shares);
        assertEq(claimedAssets, fundedAssets);
        _assertCarryUnchanged(beforeCarry);
        _assertFullYearCarry(started);
    }

    function _openCarryPosition() private returns (uint256 started) {
        _fundTrader(TRADER, 120_000e6);
        // Whole-hour entry makes the quarter/year intervals exact and preserves a non-parity neutral mark.
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 100_000e6, PRICE);
        assertEq(engine.lastMarkPrice(), PRICE);
        assertEq(_positionMaxProfitAssets(TRADER), 80_000e6);
        started = vm.getBlockTimestamp();
    }

    function _rejectEngineCarryCheckpoint() private {
        vm.mockCallRevert(
            address(engine), abi.encodeWithSelector(engine.checkpointCarryIndex.selector), bytes("LP checkpoint")
        );
    }

    function _carrySnapshot() private view returns (CarrySnapshot memory snapshot) {
        snapshot.index = engine.carryIndex();
        snapshot.timestamp = engine.carryTimestamp();
        (uint256 exposure, uint256 index, uint64 timestamp) = engine.positionCarryState(TRADER);
        snapshot.position = keccak256(abi.encode(exposure, index, timestamp));
        snapshot.traderCustody = clearinghouse.balanceAssets(TRADER);
    }

    function _assertCarryUnchanged(
        CarrySnapshot memory expected
    ) private view {
        CarrySnapshot memory actual = _carrySnapshot();
        assertEq(actual.index, expected.index, "LP liquidity must not advance the stored global carry index");
        assertEq(actual.timestamp, expected.timestamp, "LP liquidity must not checkpoint the Engine clock");
        assertEq(actual.position, expected.position, "LP liquidity must not checkpoint the trader position");
        assertEq(actual.traderCustody, expected.traderCustody, "LP liquidity must not collect trader debt");
    }

    function _assertFullYearCarry(
        uint256 started
    ) private {
        vm.clearMockedCalls();
        vm.warp(started + YEAR);
        uint256 assetsBefore = pool.accountedAssets();
        uint256 custodyBefore = clearinghouse.balanceAssets(TRADER);
        vm.prank(address(clearinghouse));
        engine.realizeCarryBeforeMarginChange(TRADER);
        assertEq(pool.accountedAssets() - assetsBefore, 4000e6, "$80,000 maximum profit costs $4,000 for a year");
        assertEq(custodyBefore - clearinghouse.balanceAssets(TRADER), 4000e6);
        assertEq(engine.unsettledCarryAssets(TRADER), 0);
    }

}

/// @notice Bootstrap must not depend on a carry checkpoint before any trading can begin.
contract LpSeedCarryIndependenceTest is HousePoolAsyncTestBase {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#lp-capital-carry.
    function test_SeedBootstrapDoesNotDependOnEngineCarryCheckpoint() public {
        uint256 indexBefore = engine.carryIndex();
        uint64 timestampBefore = engine.carryTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.mockCallRevert(
            address(engine), abi.encodeWithSelector(engine.checkpointCarryIndex.selector), bytes("LP checkpoint")
        );
        settlementToken.mint(address(this), 2000e6);
        settlementToken.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));

        assertTrue(pool.isSeedLifecycleComplete());
        assertFalse(pool.isTradingActive(), "seeding does not activate trading");
        assertEq(pool.accountedAssets(), 2000e6);
        assertEq(juniorVault.totalSupply(), juniorVault.seedShareFloor());
        assertEq(seniorVault.totalSupply(), seniorVault.seedShareFloor());
        assertGt(juniorVault.seedShareFloor(), 0);
        assertGt(seniorVault.seedShareFloor(), 0);
        assertEq(engine.carryIndex(), indexBefore);
        assertEq(engine.carryTimestamp(), timestampBefore, "seed liquidity must not checkpoint even an idle Engine");
    }

}
