// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";

/// @dev Carry belongs to LPs at collection, including shares activated but still held in deposit-claim escrow.
///      These tests deliberately retain this timing policy. They do not treat indexed debt as an LP receivable.
contract CarryLpOwnershipTest is HousePoolAsyncTestBase {

    address private constant TRADER = address(0xCA221);
    address private constant ENTRANT = address(0xCA222);
    uint256 private constant DEPOSIT = 100_000e6;
    uint256 private constant SIZE = 100_000e18;
    uint256 private constant VIRTUAL_SHARES = 1000;

    struct CarryStart {
        uint256 borrowBase;
        uint256 depth;
        uint256 timestamp;
        uint256 checkpointedIndex;
    }

    struct ExitComparison {
        uint256 requestId;
        uint256 shares;
        uint256 carry;
        uint256 nav;
        uint256 supply;
        uint256 assetsBefore;
        uint256 assetsAfter;
    }

    function setUp() public override {
        super.setUp();
        // Separate the timing of carry ownership from Senior coupon allocation and Junior dilution.
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        _refreshMarkForAsyncSettlement();
        pool.finalizePoolConfig();
        assertEq(pool.seniorRateBps(), 0);
        assertEq(juniorVault.maintenanceFeeAprBps(), 0);
    }

    function test_EntryPricesCollectedCarryButSharesHistoricalCarryCollectedAfterActivation() public {
        CarryStart memory start = _openCarryPosition(50_000e6, 20_000e6);
        uint256 oldNav = _juniorNav();
        _warpLiveAfter(30 days);
        start.checkpointedIndex = _independentIndex(start);
        start.timestamp = vm.getBlockTimestamp();
        _refreshMarkForAsyncSettlement();
        uint256 requestId = _requestAsyncDeposit(juniorVault, ENTRANT, DEPOSIT);
        vm.warp(pool.lpEpochStart(requestId));
        _refreshMarkForAsyncSettlement();

        uint256 carry = _independentCarry(start);
        assertGt(carry, 0, "the entrant must face historical carry debt");
        assertEq(_juniorNav(), oldNav, "uncollected carry is absent from entry NAV");
        uint256 supply = juniorVault.totalSupply();
        uint256 snapshot = vm.snapshotState();

        assertEq(_collectCarry(), carry, "collection before activation must pay the independently accrued debt");
        assertEq(_juniorNav(), oldNav + carry, "neutral-mark collected carry increases Junior NAV exactly once");
        _settleLpEpochForTest();
        (, uint256 sharesAfterCollection,,, bool finalized) = juniorVault.depositEpochs(requestId);
        assertTrue(finalized, "pre-collection branch must activate the deposit");
        assertEq(
            sharesAfterCollection,
            DEPOSIT * (supply + VIRTUAL_SHARES) / (oldNav + carry + 1),
            "entry must price revenue already collected"
        );
        _claimAsyncDeposit(juniorVault, requestId, ENTRANT);
        assertLe(juniorVault.convertToAssets(sharesAfterCollection), DEPOSIT, "new shares cannot capture prior revenue");

        assertTrue(vm.revertToState(snapshot));
        _settleLpEpochForTest();
        (, uint256 escrowShares,,, bool activated) = juniorVault.depositEpochs(requestId);
        assertTrue(activated, "post-collection branch must activate the same deposit");
        assertEq(escrowShares, DEPOSIT * (supply + VIRTUAL_SHARES) / (oldNav + 1));
        assertGt(escrowShares, sharesAfterCollection, "uncollected debt must not be priced as LP-owned revenue");
        assertEq(juniorVault.balanceOf(ENTRANT), 0, "activated shares must still be in claim escrow");
        assertGe(juniorVault.balanceOf(address(juniorVault)), escrowShares);
        uint256 valueBeforeCollection = juniorVault.convertToAssets(escrowShares);

        assertEq(_collectCarry(), carry, "activation must checkpoint indexes without collecting account debt");
        assertEq(_juniorNav(), oldNav + DEPOSIT + carry);
        uint256 expectedValue = escrowShares * (oldNav + DEPOSIT + carry + 1) / (supply + escrowShares + VIRTUAL_SHARES);
        assertEq(juniorVault.convertToAssets(escrowShares), expectedValue);
        assertGt(
            expectedValue, valueBeforeCollection, "unclaimed activated shares participate in historic debt collection"
        );
        assertGt(expectedValue, DEPOSIT, "collection timing intentionally permits the incoming LP to share old carry");
        uint256 supplyBeforeClaim = juniorVault.totalSupply();
        assertEq(_claimAsyncDeposit(juniorVault, requestId, ENTRANT), escrowShares);
        assertEq(juniorVault.totalSupply(), supplyBeforeClaim, "claim transfers already participating shares");
        assertEq(juniorVault.convertToAssets(juniorVault.balanceOf(ENTRANT)), expectedValue);
        _assertNoSecondCollection();
    }

    function test_ExitOwnsCarryUntilFundingButFundedClaimDoesNotShareLaterCollection() public {
        ExitComparison memory expected;
        CarryStart memory start = _openCarryPosition(50_000e6, 20_000e6);
        _warpLiveAfter(30 days);
        expected.shares = juniorVault.balanceOf(address(this)) / 10;
        expected.requestId = _requestAsyncRedeem(juniorVault, address(this), expected.shares);
        vm.warp(pool.lpEpochStart(expected.requestId));
        _refreshMarkForAsyncSettlement();
        assertFalse(engine.isOracleFrozen(), "the exit comparison excludes frozen fees");

        expected.carry = _independentCarry(start);
        expected.nav = _juniorNav();
        expected.supply = juniorVault.totalSupply();
        uint256 snapshot = vm.snapshotState();
        assertEq(_collectCarry(), expected.carry);
        _settleLpEpochForTest();
        (uint256 fundedBefore, uint256 assetsBefore) = _fundedExit(expected.requestId);
        expected.assetsBefore = assetsBefore;
        assertEq(fundedBefore, expected.shares, "fixture must fully fund the pre-collection branch");
        assertEq(
            expected.assetsBefore,
            expected.shares * (expected.nav + expected.carry + 1) / (expected.supply + VIRTUAL_SHARES)
        );

        assertTrue(vm.revertToState(snapshot));
        _settleLpEpochForTest();
        (uint256 fundedAfter, uint256 assetsAfter) = _fundedExit(expected.requestId);
        expected.assetsAfter = assetsAfter;
        assertEq(fundedAfter, expected.shares, "fixture must fully fund the post-collection branch");
        assertEq(expected.assetsAfter, expected.shares * (expected.nav + 1) / (expected.supply + VIRTUAL_SHARES));
        assertLt(
            expected.assetsAfter, expected.assetsBefore, "shares burned before collection do not own that later revenue"
        );
        uint256 supplyAfterFunding = juniorVault.totalSupply();
        assertEq(supplyAfterFunding, expected.supply - expected.shares);
        uint256 escrowCashBefore = settlementToken.balanceOf(address(juniorVault));
        uint256 remainingNav = _juniorNav();
        assertEq(_collectCarry(), expected.carry, "funding changes depth after checkpointing historical carry");
        assertEq(_juniorNav(), remainingNav + expected.carry, "remaining shares own the collected revenue");
        (, uint256 claimAssetsAfterCollection) = _fundedExit(expected.requestId);
        assertEq(claimAssetsAfterCollection, expected.assetsAfter, "funded exit entitlement is fixed");
        assertEq(
            settlementToken.balanceOf(address(juniorVault)),
            escrowCashBefore,
            "carry does not enter funded claim escrow"
        );
        (uint256 claimedShares, uint256 claimedAssets) =
            _claimAsyncRedeem(juniorVault, expected.requestId, address(this));
        assertEq(claimedShares, expected.shares);
        assertEq(claimedAssets, expected.assetsAfter);
        assertEq(juniorVault.totalSupply(), supplyAfterFunding, "claim does not burn the shares twice");
        _assertNoSecondCollection();
    }

    function test_UnpaidArrearsAreNotLpNavAndLaterDepositRevenueIsCollectedOnce() public {
        CarryStart memory start = _openCarryPosition(2500e6, 2000e6);
        uint256 nav = _juniorNav();
        _warpLiveAfter(10 * 365 days);
        _refreshMarkForAsyncSettlement();
        uint256 due = _independentCarry(start);
        uint256 backing =
            clearinghouse.getAccountAssetBuckets(TRADER).activePositionMarginAssets + _freeSettlementAssets(TRADER);
        assertGt(due, backing, "fixture must exhaust all carry-eligible custody");
        assertEq(_juniorNav(), nav, "even unpayable indexed carry is absent from LP NAV");
        assertEq(_collectCarry(), backing);
        uint256 arrears = due - backing;
        assertEq(engine.unsettledCarryAssets(TRADER), arrears, "unpaid debt must remain owed by the trader");
        assertEq(_juniorNav(), nav + backing, "only collected backing becomes revenue");
        _assertNoSecondCollection();
        assertEq(engine.unsettledCarryAssets(TRADER), arrears, "an empty checkpoint cannot forgive retained arrears");

        uint256 replenishment = 10e6;
        assertGt(arrears, replenishment);
        uint256 poolCash = pool.accountedAssets();
        _fundTrader(TRADER, replenishment);
        assertEq(pool.accountedAssets(), poolCash + replenishment, "deposit pays existing debt at the same timestamp");
        assertEq(engine.unsettledCarryAssets(TRADER), arrears - replenishment);
        assertEq(_juniorNav(), nav + backing + replenishment);
        _assertNoSecondCollection();
    }

    function test_PledgeCappedPriceLossOffsetsCarryCashInTerminalNav() public {
        CarryStart memory start = _openCarryPosition(50_000e6, 20_000e6);
        _warpLiveAfter(30 days);
        // LONG loses when the mark rises. The $40k loss exceeds its $20k pledge before and after carry.
        vm.prank(address(router));
        engine.updateMarkPrice(1.4e8, uint64(vm.getBlockTimestamp()));
        uint256 marginBefore = clearinghouse.getAccountAssetBuckets(TRADER).activePositionMarginAssets;
        int256 priceDeltaBefore = _terminalLpPriceDelta();
        assertEq(priceDeltaBefore, int256(marginBefore), "fixture must cap price-loss receivable at pledged margin");
        uint256 navBefore = _juniorNav();
        uint256 cashBefore = pool.accountedAssets();
        uint256 carry = _independentCarry(start);
        assertLt(carry, marginBefore, "the collection must fit entirely in pledged margin");

        assertEq(_collectCarry(), carry);
        int256 priceDeltaAfter = _terminalLpPriceDelta();
        assertEq(priceDeltaAfter, priceDeltaBefore - int256(carry));
        assertEq(pool.accountedAssets(), cashBefore + carry);
        assertEq(
            int256(_juniorNav()) - int256(navBefore),
            int256(carry) + priceDeltaAfter - priceDeltaBefore,
            "LP NAV changes by cash plus the change in collectible price loss"
        );
        assertEq(_juniorNav(), navBefore, "moving already marked pledge to pool cash must not double-count revenue");
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.juniorPrincipal(), navBefore, "reconcile preserves the net economic value");
        _assertNoSecondCollection();
    }

    function _openCarryPosition(
        uint256 funding,
        uint256 margin
    ) private returns (CarryStart memory start) {
        _fundTrader(TRADER, funding);
        _open(TRADER, CfdTypes.Side.LONG, SIZE, margin, 1e8);
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, SIZE);
        uint256 actualMargin = clearinghouse.getAccountAssetBuckets(TRADER).activePositionMarginAssets;
        (start.borrowBase,,) = engine.positionCarryState(TRADER);
        assertEq(start.borrowBase, 100_000e6 - actualMargin);
        start.depth = pool.accountedAssets();
        start.timestamp = vm.getBlockTimestamp();
        assertEq(_terminalLpPriceDelta(), 0);
    }

    function _independentCarry(
        CarryStart memory start
    ) private view returns (uint256) {
        // Independent integer specification; no production carry helper, preview or collected balance supplies debt.
        return start.borrowBase * (start.checkpointedIndex + _independentIndex(start)) / 1e18;
    }

    function _independentIndex(
        CarryStart memory start
    ) private view returns (uint256) {
        uint256 utilizationBps = start.borrowBase * 10_000 / start.depth;
        if (utilizationBps > 10_000) {
            utilizationBps = 10_000;
        }
        return 500 * utilizationBps * 1e18 * (vm.getBlockTimestamp() - start.timestamp) / (365 days * 10_000 * 10_000);
    }

    function _collectCarry() private returns (uint256 collected) {
        uint256 cashBefore = pool.accountedAssets();
        vm.prank(address(clearinghouse));
        engine.realizeCarryBeforeMarginChange(TRADER);
        collected = pool.accountedAssets() - cashBefore;
    }

    function _assertNoSecondCollection() private {
        uint256 nav = _juniorNav();
        uint256 cash = settlementToken.balanceOf(address(pool));
        assertEq(_collectCarry(), 0, "the same carry must never be collected twice");
        assertEq(_juniorNav(), nav);
        assertEq(settlementToken.balanceOf(address(pool)), cash);
    }

    function _juniorNav() private view returns (uint256 nav) {
        (, nav) = pool.getPendingDepositTrancheState();
    }

    function _fundedExit(
        uint256 requestId
    ) private view returns (uint256 shares, uint256 assets) {
        (, shares, assets,,,,,,,) = juniorVault.redeemEpochs(requestId);
    }

    function _warpLiveAfter(
        uint256 elapsed
    ) private {
        // Solidity may cache block.timestamp across cheatcode warps, including loop iterations under viaIR.
        vm.warp(vm.getBlockTimestamp() + elapsed);
        while (engine.isOracleFrozen()) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
    }

}
