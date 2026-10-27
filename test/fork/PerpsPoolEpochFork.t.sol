// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../packages/perps/test/perps/BasePerpTest.sol";
import {LegacyOrderRouterHarness} from "../../packages/perps/test/utils/LegacyOrderRouterHarness.sol";
import {ArbitrumSepoliaReleaseOracle} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPyth} from "@plether/shared/interfaces/IPyth.sol";
import {ArbitrumForkSupport} from "@plether/test-utils/ArbitrumForkSupport.sol";

/// @notice Real signed Pyth components straddle a natural LP epoch while a real V3 order is open.
/// @dev Only the local protocol is deployed. Pyth code, storage, signatures, timestamps and oracle policy are untouched.
contract PerpsPoolEpochForkTest is BasePerpTest {

    address internal constant REAL_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    address internal constant TRADER = address(0xA11CE);
    address internal constant DEPOSITOR = address(0xB0B);
    uint256 internal constant DEPOSIT_ASSETS = 10_000e6;
    uint256 internal constant POSITION_SIZE = 10_000e18;
    uint256 internal constant REFUND_SURPLUS = 1 gwei;
    // Independent integer arithmetic from the six signed messages: normalize each FX price, apply its
    // inversion and floor its weighted/base-price contribution before summing. Confidence before = 7,323;
    // the finalized router policy shifts LONG entry down by floor(7,323 * 2,000 / 10,000) = 1,464.
    uint256 internal constant BEFORE_NEUTRAL_MARK = 97_578_223;
    uint256 internal constant AFTER_NEUTRAL_MARK = 97_577_193;
    uint256 internal constant OPEN_ENTRY_PRICE = 97_576_759;
    // Seed junior/senior = 1,000e6 each; first 3,600-second 8% coupon = 9,132 settlement asset atoms.
    // Initial junior supply S = 1e12 + floor(1e12 * (1e12 + 1000) / (1e9 - 9132 + 1))
    // = 1,001,009,132,083,385. The next coupon is floor(1,000,009,132 * 800 * 80,607,608
    // / (10,000 * 31,536,000)) = 204,485,905. The 100-lot LONG loses 43,400 atoms at
    // AFTER_NEUTRAL_MARK, so junior NAV N = 1,000,999,990,868 - 204,485,905 + 43,400
    // = 1,000,795,548,363. Uncollected carry is not price PnL or recognized pool revenue.
    // Redeem floor(S/100) shares: R = floor(floor(S/100) * (N+1) / (S+1000)).
    // Then deposit 1e10 atoms: mint floor(1e10 * (S-floor(S/100)+1000) / (N-R+1)).
    uint256 internal constant EXPECTED_REDEEM_ASSETS = 10_007_955_483;
    uint256 internal constant EXPECTED_DEPOSIT_SHARES = 10_002_134_139_386;

    string internal fixture;
    bytes32[] internal ids;
    uint256 internal epochStart;
    uint256 internal beforeTime;
    uint256 internal afterTime;
    uint256 internal requestId;
    uint256 internal redeemShares;

    function setUp() public override {
        fixture = vm.readFile("test/fixtures/oracle-sync/pool-epoch-sep23.json");
        uint256 forkNumber = vm.parseJsonUint(fixture, ".forkBlockNumber");
        vm.createSelectFork(vm.envString("ARB_SEPOLIA_RPC_URL"), forkNumber);
        ArbitrumForkSupport.install();
        assertEq(block.chainid, vm.parseJsonUint(fixture, ".chainId"));
        vm.roll(forkNumber + 1);
        assertEq(blockhash(forkNumber), vm.parseJsonBytes32(fixture, ".forkBlockHash"));
        vm.roll(forkNumber);
        uint256 forkTime = vm.parseJsonUint(fixture, ".forkTimestamp");
        assertEq(vm.getBlockTimestamp(), forkTime);
        assertEq(vm.parseJsonAddress(fixture, ".pyth"), REAL_PYTH);
        assertGt(REAL_PYTH.code.length, 0);
        ids = vm.parseJsonBytes32Array(fixture, ".feedIds");
        assertEq(ids.length, 6);
        uint256[] memory stored = vm.parseJsonUintArray(fixture, ".initialStoredPublishTimes");
        for (uint256 i; i < ids.length; ++i) {
            assertEq(IPyth(REAL_PYTH).getPriceUnsafe(ids[i]).publishTime, stored[i]);
        }
        epochStart = vm.parseJsonUint(fixture, ".epochStart");
        beforeTime = vm.parseJsonUintArray(fixture, ".updates.before.publishTimes")[0];
        afterTime = vm.parseJsonUintArray(fixture, ".updates.after.publishTimes")[0];
        assertEq(epochStart % 1 hours, 0);
        assertLt(beforeTime, epochStart);
        assertGe(afterTime, epochStart);

        // Local deployment/funding precedes the recorded epoch. The real Pyth deployment is never substituted.
        vm.warp(SETUP_TIMESTAMP);
        super.setUp();
        pletherOracle = new ArbitrumSepoliaReleaseOracle(
            address(engine),
            address(pool),
            REAL_PYTH,
            ids,
            vm.parseJsonUintArray(fixture, ".quantities"),
            vm.parseJsonUintArray(fixture, ".basePrices"),
            abi.decode(vm.parseJson(fixture, ".inversions"), (bool[]))
        );
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig(address(pletherOracle)));
        vm.warp(forkTime);
        assertGe(forkTime, routerAdmin.oracleConfigActivationTime());
        routerAdmin.finalizeOracleConfig();
        assertFalse(pletherOracle.isOracleFrozen());
        assertLe(afterTime - beforeTime, pletherOracle.LIVE_TICK_LOOKBACK());
        vm.deal(address(this), 10 ether);

        assertLt(forkTime, epochStart - juniorVault.LP_REQUEST_CUTOFF_DURATION());
        settlementToken.mint(DEPOSITOR, DEPOSIT_ASSETS);
        vm.startPrank(DEPOSITOR);
        settlementToken.approve(address(juniorVault), DEPOSIT_ASSETS);
        requestId = juniorVault.requestDeposit(DEPOSIT_ASSETS, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();
        assertEq(pool.lpEpochStart(requestId), epochStart);
        redeemShares = juniorVault.balanceOf(address(this)) / 100;
        assertGt(redeemShares, 0);
        assertEq(juniorVault.requestRedeem(redeemShares, address(this), address(this)), requestId);
        _fundTrader(TRADER, 10_000e6);
        _openSignedPosition();
    }

    function _deployLegacyOrderRouter(
        address engine_,
        address lens_,
        address pool_,
        address oracle_
    ) internal override returns (LegacyOrderRouterHarness deployedRouter) {
        policyEvaluator = new CfdOrderPolicyEvaluator();
        orderExecutionSidecar = new OrderRouterExecutionSidecar();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook book = new OrderLifecycleBook(predicted, engine_, address(clearinghouse), pool_);
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predicted);
        OrderRouter productionRouter = new OrderRouter(
            engine_,
            lens_,
            pool_,
            oracle_,
            address(keeperSidecar),
            address(policyEvaluator),
            address(orderExecutionSidecar),
            address(book)
        );
        assertEq(address(productionRouter), predicted);
        return LegacyOrderRouterHarness(payable(address(productionRouter)));
    }

    function _openSignedPosition() internal {
        vm.warp(beforeTime - 1);
        OrderV3Types.OrderRequest memory request = OrderV3Types.OrderRequest({
            clientOrderId: keccak256("signed-pool-epoch-open"),
            side: CfdTypes.Side.LONG,
            sizeDelta: POSITION_SIZE,
            marginDelta: 1000e6,
            targetPrice: 1,
            isClose: false,
            bounds: OrderV3Types.ExecutionBounds({
                submitBy: uint64(vm.getBlockTimestamp()),
                executionWindowSeconds: uint32(router.maxExecutionWindowSeconds()),
                allowedExecutionModes: 1,
                expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
                maxExecutionBountyAssets: 100e6,
                maxExecutionNotionalAssets: 20_000e6,
                maxGrossAccountDebitAssets: 1100e6,
                maxActionChargeAssets: 100e6,
                maxExplicitFeesAssets: 100e6,
                maxPostPositionSize: POSITION_SIZE,
                minPostSettlementBalanceAssets: 0,
                minPostPositionEquityAssets: 0,
                maxPostLeverageBps: 200_000
            })
        });
        vm.prank(TRADER);
        uint64 orderId = OrderRouter(payable(address(router))).commitOrder(request);
        vm.warp(beforeTime);
        vm.roll(vm.getBlockNumber() + 1);
        bytes[] memory beforeData = _data("before");
        OrderV3Types.ExecutionResult memory result =
            router.executeOrder{value: pletherOracle.getOrderExecutionFee(beforeData)}(orderId, beforeData);
        assertEq(uint256(result.status), uint256(OrderV3Types.LifecycleStatus.Executed));
        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(TRADER);
        assertEq(size, POSITION_SIZE, "Settlement must price an actual open position");
        assertEq(entryPrice, OPEN_ENTRY_PRICE, "Signed confidence sets the independent LONG entry price");
        assertEq(engine.positionEntryCostAssetAtoms(TRADER), 9_757_675_900);
        assertEq(engine.lastMarkTime(), beforeTime);
        // Historical settlement deliberately does not initialize the accepted live basket.
        router.updateMarkPrice{value: pletherOracle.getUpdateFee(beforeData)}(beforeData);
        _assertAccepted(beforeTime);
    }

    function test_RealSignedPreBoundaryComponentRollsBackThenFreshBasketSettlesAndClaims() public {
        vm.warp(afterTime);
        vm.roll(vm.getBlockNumber() + 1);
        bytes[] memory mixed = _data("mixed");
        uint256[] memory mixedTimes = vm.parseJsonUintArray(fixture, ".updates.mixed.publishTimes");
        assertEq(mixedTimes[0], beforeTime);
        for (uint256 i = 1; i < ids.length; ++i) {
            assertEq(mixedTimes[i], afterTime);
        }
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, POSITION_SIZE);
        uint256 fee = pletherOracle.getUpdateFee(mixed);
        bytes32 storedPythBefore = _pythStorageHash();
        bytes32 beforeState = _settlementState();
        vm.expectRevert(
            abi.encodeWithSelector(
                IPletherOracle.PletherOracle__PoolEpochComponentTooOld.selector, beforeTime, epochStart
            )
        );
        router.settleLpEpoch{value: fee + REFUND_SURPLUS}(mixed);
        assertEq(_settlementState(), beforeState, "Rejected component must roll back mark, escrow, queues and funding");

        bytes[] memory fresh = _data("after");
        uint256 cashBefore = _trackedCash();
        uint256 poolCashBefore = settlementToken.balanceOf(address(pool));
        uint256 payerEthBefore = address(this).balance;
        uint256 pythEthBefore = REAL_PYTH.balance;
        fee = pletherOracle.getUpdateFee(fresh);
        router.settleLpEpoch{value: fee + REFUND_SURPLUS}(fresh);
        _assertAccepted(afterTime);
        assertEq(_pythStorageHash(), storedPythBefore, "Live settlement must not mutate Pyth latest-price storage");
        assertEq(engine.terminalNavSnapshot().terminalLpPriceDeltaAssets, int256(43_400));
        assertEq(pool.seniorPrincipal(), 1_204_495_037, "Senior receives the elapsed 8% coupon");
        assertEq(pool.juniorPrincipal(), 1_000_787_592_880, "Junior NAV includes price PnL and both LP flows");
        assertEq(juniorVault.totalSupply(), 1_001_001_174_901_938);
        assertEq(juniorVault.pendingDepositRequest(requestId, DEPOSITOR), 0);
        assertEq(juniorVault.claimableDepositRequest(requestId, DEPOSITOR), DEPOSIT_ASSETS);
        assertEq(juniorVault.pendingRedeemRequest(requestId, address(this)), 0);
        assertEq(juniorVault.claimableRedeemRequest(requestId, address(this)), redeemShares);
        uint256 redeemAssets = juniorVault.claimableRedeemAssets(requestId, address(this));
        assertEq(redeemAssets, EXPECTED_REDEEM_ASSETS, "Redemption uses independently derived epoch NAV");
        assertEq(juniorVault.claimableDepositShares(requestId, DEPOSITOR), EXPECTED_DEPOSIT_SHARES);
        assertEq(settlementToken.balanceOf(address(pool)), poolCashBefore + DEPOSIT_ASSETS - EXPECTED_REDEEM_ASSETS);
        assertEq(_trackedCash(), cashBefore, "Settlement conserves LP settlement assets across pool and vault escrow");
        assertEq(REAL_PYTH.balance - pythEthBefore, fee);
        assertEq(payerEthBefore - address(this).balance, fee, "Router returns the positive execution surplus");
        assertEq(address(router).balance, 0);
        assertEq(pletherOracle.claimableEth(address(this)), 0);
        assertEq(routerAdmin.claimableEth(address(this)), 0);

        uint256 receiverSharesBefore = juniorVault.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        uint256 mintedShares = juniorVault.claimDeposit(requestId, DEPOSIT_ASSETS, DEPOSITOR, DEPOSITOR);
        assertEq(mintedShares, EXPECTED_DEPOSIT_SHARES, "Deposit is priced after the queued redemption");
        assertEq(juniorVault.balanceOf(DEPOSITOR) - receiverSharesBefore, EXPECTED_DEPOSIT_SHARES);
        uint256 receiverCashBefore = settlementToken.balanceOf(address(this));
        assertEq(juniorVault.claimRedeem(requestId, redeemShares, address(this), address(this)), EXPECTED_REDEEM_ASSETS);
        assertEq(settlementToken.balanceOf(address(this)) - receiverCashBefore, EXPECTED_REDEEM_ASSETS);
        assertEq(juniorVault.claimableDepositRequest(requestId, DEPOSITOR), 0);
        assertEq(juniorVault.claimableRedeemRequest(requestId, address(this)), 0);
        assertEq(_trackedCash(), cashBefore, "Claim transfers conserve all LP settlement assets");
        (size,,,,,,) = engine.positions(TRADER);
        assertEq(size, POSITION_SIZE, "LP settlement must not close the trader's position");
    }

    function _data(
        string memory key
    ) internal view returns (bytes[] memory data) {
        string memory path = string.concat(".updates.", key);
        data = abi.decode(vm.parseJson(fixture, string.concat(path, ".updateData")), (bytes[]));
        bytes memory encoded;
        for (uint256 i; i < data.length; ++i) {
            encoded = bytes.concat(encoded, data[i]);
        }
        assertEq(sha256(encoded), vm.parseJsonBytes32(fixture, string.concat(path, ".payloadSha256")));
    }

    function _assertAccepted(
        uint256 expectedTime
    ) internal view {
        (bool accepted, uint256 price, uint64 published) = pletherOracle.getAcceptedBasketMark();
        assertTrue(accepted);
        assertEq(price, expectedTime == beforeTime ? BEFORE_NEUTRAL_MARK : AFTER_NEUTRAL_MARK);
        assertEq(published, expectedTime);
        assertEq(engine.lastMarkTime(), expectedTime);
        assertEq(engine.lastMarkPrice(), price);
        uint256[] memory feedTimes = pletherOracle.getAcceptedFeedPublishTimes();
        for (uint256 i; i < ids.length; ++i) {
            assertEq(feedTimes[i], expectedTime);
        }
    }

    function _trackedCash() internal view returns (uint256) {
        return settlementToken.balanceOf(address(pool)) + settlementToken.balanceOf(address(juniorVault))
            + settlementToken.balanceOf(DEPOSITOR) + settlementToken.balanceOf(address(this));
    }

    function _pythStorageHash() internal view returns (bytes32) {
        bytes memory state;
        for (uint256 i; i < ids.length; ++i) {
            state = bytes.concat(state, abi.encode(IPyth(REAL_PYTH).getPriceUnsafe(ids[i])));
        }
        return keccak256(state);
    }

    function _settlementState() internal view returns (bytes32) {
        bytes memory state = abi.encode(
            engine.lastMarkPrice(),
            engine.lastMarkTime(),
            engine.sideCarryIndex(0),
            engine.sideCarryIndex(1),
            pool.lastReconcileTime(),
            pool.lastSeniorCouponCheckpointTime(),
            pool.seniorPrincipal(),
            pool.juniorPrincipal(),
            pool.accountedAssets(),
            juniorVault.totalSupply(),
            juniorVault.depositQueueHead(),
            juniorVault.depositQueueTail(),
            juniorVault.redeemQueueHead(),
            juniorVault.redeemQueueTail(),
            juniorVault.pendingDepositEscrowAssets(),
            juniorVault.pendingRedeemEscrowShares(),
            juniorVault.depositClaimEscrowShares(),
            juniorVault.withdrawalEscrowAssets()
        );
        state = bytes.concat(
            state,
            abi.encode(
                juniorVault.pendingDepositRequest(requestId, DEPOSITOR),
                juniorVault.claimableDepositRequest(requestId, DEPOSITOR),
                juniorVault.pendingRedeemRequest(requestId, address(this)),
                juniorVault.claimableRedeemRequest(requestId, address(this)),
                settlementToken.balanceOf(address(pool)),
                settlementToken.balanceOf(address(juniorVault)),
                _trackedCash(),
                address(this).balance,
                REAL_PYTH.balance,
                address(router).balance,
                address(pletherOracle).balance,
                address(routerAdmin).balance,
                pletherOracle.claimableEth(address(this)),
                routerAdmin.claimableEth(address(this)),
                pletherOracle.getAcceptedFeedPublishTimes()
            )
        );
        (bool accepted, uint256 price, uint64 published) = pletherOracle.getAcceptedBasketMark();
        state = bytes.concat(state, abi.encode(accepted, price, published));
        return keccak256(bytes.concat(state, abi.encode(_pythStorageHash())));
    }

}
