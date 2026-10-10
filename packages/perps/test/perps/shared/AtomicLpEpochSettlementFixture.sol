// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";

import {PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/// @notice Caller used to prove that the Router's final ETH refund cannot reenter LP settlement.

contract LpEpochRefundReenterer {

    OrderRouter internal immutable ROUTER;

    event RefundCallback(bool reentered, bytes4 revertSelector);

    constructor(
        OrderRouter router
    ) {
        ROUTER = router;
    }

    function settle(
        bytes[] calldata updateData
    ) external payable {
        ROUTER.settleLpEpoch{value: msg.value}(updateData);
    }

    receive() external payable {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        (bool ok, bytes memory revertData) =
            address(ROUTER).call(abi.encodeCall(OrderRouter.settleLpEpoch, (updateData)));
        bytes4 revertSelector;
        if (revertData.length >= 4) {
            assembly ("memory-safe") {
                revertSelector := mload(add(revertData, 0x20))
            }
        }
        emit RefundCallback(ok, revertSelector);
    }

}

abstract contract AtomicLpEpochSettlementTestFixture is BasePerpTest {

    using stdStorage for StdStorage;

    struct SettlementHoldRollbackSnapshot {
        uint256 pythUpdateCalls;
        int64 pythPrice;
        uint256 pythPublishTime;
        uint256 callerEth;
        uint256 pythEth;
        uint256 markPrice;
        uint64 markTime;
        uint256 longCarryIndex;
        uint256 shortCarryIndex;
        uint256 lastReconcileTime;
        uint256 lastSeniorCouponCheckpointTime;
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 seniorHighWaterMark;
        uint256 accountedAssets;
        uint256 poolUsdc;
        uint256 vaultUsdc;
        uint256 juniorSupply;
        uint256 accruedJuniorSupply;
        uint256 maintenanceFeeRecipientShares;
        uint256 maintenanceFeeCheckpointBoundary;
        uint256 pendingMaintenanceFeeShares;
        uint256 depositQueueHead;
        uint256 depositQueueTail;
        uint256 redeemQueueHead;
        uint256 redeemQueueTail;
        uint256 pendingDepositEscrowAssets;
        uint256 pendingRedeemEscrowShares;
        uint256 depositClaimEscrowShares;
        uint256 withdrawalEscrowAssets;
        uint256 pendingDepositAssets;
        uint256 claimableDepositAssets;
        uint256 pendingRedeemShares;
        uint256 claimableRedeemShares;
    }

    struct MaintenanceFeeSettlementFixture {
        uint256 redeemShares;
        uint256 redeemId;
        uint256 depositAssets;
        uint256 depositId;
        uint256 feeShares;
        uint256 rawSupplyBefore;
        uint256 feeBoundaryBefore;
        address caller;
        bytes4 injectedFailure;
    }

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    uint256 internal constant HOUSE_POOL_RUNTIME_TARGET = 24_529;
    uint256 internal constant REDEMPTION_MATH_SIDECAR_RUNTIME_LIMIT = 1200;
    uint256 internal constant CFD_ENGINE_RUNTIME_BASELINE = 24_439;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA7E);
    address internal constant TRADER = address(0x7A0E2);
    address internal constant MAINTENANCE_FEE_RECIPIENT = address(0xFEE60001);

    uint256 internal constant MAINTENANCE_FEE_APR_BPS = 1000;

    uint256 internal constant FRIDAY_FAD_ONLY = 1_709_934_300;
    uint256 internal constant SATURDAY_FROZEN = 1_709_985_600;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _openMarkSensitivePosition() internal {
        _fundTrader(TRADER, 200e6);
        _open(TRADER, CfdTypes.Side.LONG, 1000e18, 100e6, 100_000_000);
    }

    function _enableJuniorMaintenanceFee() internal {
        juniorVault.proposeMaintenanceFeeConfig(MAINTENANCE_FEE_APR_BPS, MAINTENANCE_FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();
        assertEq(juniorVault.maintenanceFeeAprBps(), MAINTENANCE_FEE_APR_BPS);
        assertEq(juniorVault.maintenanceFeeRecipient(), MAINTENANCE_FEE_RECIPIENT);
    }

    function _maintenanceFeeStateDigest() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                juniorVault.totalSupply(),
                juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT),
                juniorVault.maintenanceFeeCheckpointBoundary(),
                juniorVault.pendingMaintenanceFeeShares()
            )
        );
    }

    function _prepareHeldMaintenanceFeeSettlement() internal returns (MaintenanceFeeSettlementFixture memory fixture) {
        fixture.redeemShares = _seedJuniorLp(ALICE, 100_000e6) / 5;
        _enableJuniorMaintenanceFee();
        _openMarkSensitivePosition();

        fixture.redeemId = _requestJuniorRedeem(ALICE, fixture.redeemShares);
        fixture.depositAssets = 10_000e6;
        fixture.depositId = _requestJuniorDeposit(BOB, fixture.depositAssets);
        assertEq(fixture.depositId, fixture.redeemId, "entry and exit must share the held fee epoch");

        pool.pauseLpEpochSettlement();
        vm.warp(pool.lpEpochStart(fixture.depositId) + 6 hours);
        _setBasket(100_000_000, 0, block.timestamp);
        baseMockPyth.setFee(1 ether);
        fixture.caller = address(0xC011E3);
        vm.deal(fixture.caller, 2 ether);

        fixture.feeShares = juniorVault.pendingMaintenanceFeeShares();
        assertGt(fixture.feeShares, 0, "held time must remain chargeable");
        fixture.rawSupplyBefore = juniorVault.totalSupply();
        fixture.feeBoundaryBefore = juniorVault.maintenanceFeeCheckpointBoundary();
    }

    function _prepareFailingMaintenanceFeeSettlement()
        internal
        returns (MaintenanceFeeSettlementFixture memory fixture)
    {
        fixture.redeemShares =
            _seedJuniorLp(ALICE, 100_000e6) / 5;
        _enableJuniorMaintenanceFee();
        vm.warp(block.timestamp + 6 hours);
        _openMarkSensitivePosition();

        fixture.redeemId = _requestJuniorRedeem(ALICE, fixture.redeemShares);
        fixture.depositAssets = 200_000e6;
        fixture.depositId = _requestJuniorDeposit(BOB, fixture.depositAssets);
        assertEq(fixture.depositId, fixture.redeemId, "entry and exit must share the failing fee epoch");
        _warpToEpoch(fixture.depositId);
        _setBasket(100_000_000, 0, block.timestamp);
        baseMockPyth.setFee(1 ether);
        fixture.caller = address(0xC011E4);
        vm.deal(fixture.caller, 2 ether);

        fixture.feeShares = juniorVault.pendingMaintenanceFeeShares();
        assertGt(fixture.feeShares, 0, "fixture must have a materializable fee");
        assertGt(
            juniorVault.estimateRedeemAssets(fixture.redeemShares),
            0,
            "redemption must materialize the fee before the injected failure"
        );
        assertEq(usdc.balanceOf(address(juniorVault)), fixture.depositAssets, "fixture isolates deposit escrow cash");
        fixture.injectedFailure = bytes4(keccak256("InjectedDepositTransferFailure()"));
        _mockDepositTransferFailure(fixture.depositAssets, fixture.injectedFailure);
    }

    function _mockDepositTransferFailure(
        uint256 depositAssets,
        bytes4 injectedFailure
    ) internal {
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), address(pool), depositAssets),
            abi.encodeWithSelector(injectedFailure)
        );
    }

    function _seedJuniorLp(
        address owner,
        uint256 assets
    ) internal returns (uint256 shares) {
        uint256 requestId = _requestJuniorDeposit(owner, assets);
        _warpToEpoch(requestId);
        pool.settleLpEpoch(0, 0);
        shares = _claimJuniorDeposit(requestId, owner);
    }

    function _requestJuniorDeposit(
        address owner,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(owner, assets);
        vm.startPrank(owner);
        usdc.approve(address(juniorVault), assets);
        requestId = juniorVault.requestDeposit(assets, owner, owner);
        vm.stopPrank();
    }

    function _claimJuniorDeposit(
        uint256 requestId,
        address controller
    ) internal returns (uint256 shares) {
        uint256 assets = juniorVault.claimableDepositRequest(requestId, controller);
        assertGt(assets, 0);
        vm.prank(controller);
        shares = juniorVault.claimDeposit(requestId, assets, controller, controller);
    }

    function _requestJuniorRedeem(
        address owner,
        uint256 shares
    ) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = juniorVault.requestRedeem(shares, owner, owner);
    }

    function _requestRolledJuniorDepositForLivePosition(
        uint256 imminentId,
        address owner,
        uint256 assets
    ) internal returns (uint256 rolledId) {
        uint256 cutoff = pool.lpEpochStart(imminentId) - juniorVault.LP_REQUEST_CUTOFF_DURATION();
        assertLt(block.timestamp, cutoff, "fixture must begin before the imminent request cutoff");
        vm.warp(cutoff);
        uint256 markPrice = engine.lastMarkPrice();
        _setBasket(markPrice == 0 ? 100_000_000 : markPrice, 0, cutoff);
        router.updateMarkPrice(_emptyUpdateData());
        rolledId = _requestJuniorDeposit(owner, assets);
        assertEq(rolledId, imminentId + 1, "exact cutoff must roll the request forward one epoch");
    }

    function _warpToEpoch(
        uint256 epochId
    ) internal {
        uint256 timestamp = pool.lpEpochStart(epochId);
        if (block.timestamp < timestamp) {
            vm.warp(timestamp);
        }
    }

    function _setBasket(
        uint256 price,
        uint64 confidence,
        uint256 publishTime
    ) internal {
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(price)), confidence, int32(-8), publishTime);
    }

    function _emptyUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    function _encodedUpdateData(
        uint256 price
    ) internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
    }

    function _settlementHoldSnapshot(
        address caller,
        uint256 depositId,
        uint256 redeemId
    ) internal view returns (SettlementHoldRollbackSnapshot memory snapshot) {
        PythStructs.Price memory pythPrice = baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_A);
        snapshot.pythUpdateCalls = baseMockPyth.updatePriceFeedsCallCount();
        snapshot.pythPrice = pythPrice.price;
        snapshot.pythPublishTime = pythPrice.publishTime;
        snapshot.callerEth = caller.balance;
        snapshot.pythEth = address(baseMockPyth).balance;
        snapshot.markPrice = engine.lastMarkPrice();
        snapshot.markTime = engine.lastMarkTime();
        snapshot.longCarryIndex = engine.sideCarryIndex(uint256(CfdTypes.Side.LONG));
        snapshot.shortCarryIndex = engine.sideCarryIndex(uint256(CfdTypes.Side.SHORT));
        snapshot.lastReconcileTime = pool.lastReconcileTime();
        snapshot.lastSeniorCouponCheckpointTime = pool.lastSeniorCouponCheckpointTime();
        snapshot.seniorPrincipal = pool.seniorPrincipal();
        snapshot.juniorPrincipal = pool.juniorPrincipal();
        snapshot.seniorHighWaterMark = pool.seniorHighWaterMark();
        snapshot.accountedAssets = pool.accountedAssets();
        snapshot.poolUsdc = usdc.balanceOf(address(pool));
        snapshot.vaultUsdc = usdc.balanceOf(address(juniorVault));
        snapshot.juniorSupply = juniorVault.totalSupply();
        snapshot.accruedJuniorSupply = juniorVault.accruedTotalSupply();
        snapshot.maintenanceFeeRecipientShares = juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT);
        snapshot.maintenanceFeeCheckpointBoundary = juniorVault.maintenanceFeeCheckpointBoundary();
        snapshot.pendingMaintenanceFeeShares = juniorVault.pendingMaintenanceFeeShares();
        snapshot.depositQueueHead = juniorVault.depositQueueHead();
        snapshot.depositQueueTail = juniorVault.depositQueueTail();
        snapshot.redeemQueueHead = juniorVault.redeemQueueHead();
        snapshot.redeemQueueTail = juniorVault.redeemQueueTail();
        snapshot.pendingDepositEscrowAssets = juniorVault.pendingDepositEscrowAssets();
        snapshot.pendingRedeemEscrowShares = juniorVault.pendingRedeemEscrowShares();
        snapshot.depositClaimEscrowShares = juniorVault.depositClaimEscrowShares();
        snapshot.withdrawalEscrowAssets = juniorVault.withdrawalEscrowAssets();
        snapshot.pendingDepositAssets = juniorVault.pendingDepositRequest(depositId, BOB);
        snapshot.claimableDepositAssets = juniorVault.claimableDepositRequest(depositId, BOB);
        snapshot.pendingRedeemShares = juniorVault.pendingRedeemRequest(redeemId, ALICE);
        snapshot.claimableRedeemShares = juniorVault.claimableRedeemRequest(redeemId, ALICE);
    }

    function _assertSettlementHoldSnapshot(
        SettlementHoldRollbackSnapshot memory expected,
        address caller,
        uint256 depositId,
        uint256 redeemId
    ) internal view {
        PythStructs.Price memory pythPrice = baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_A);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), expected.pythUpdateCalls, "Pyth update count must roll back");
        assertEq(pythPrice.price, expected.pythPrice, "Pyth price must roll back");
        assertEq(pythPrice.publishTime, expected.pythPublishTime, "Pyth publish time must roll back");
        assertEq(caller.balance, expected.callerEth, "caller ETH must roll back");
        assertEq(address(baseMockPyth).balance, expected.pythEth, "Pyth ETH must roll back");
        assertEq(engine.lastMarkPrice(), expected.markPrice, "Engine price must roll back");
        assertEq(engine.lastMarkTime(), expected.markTime, "Engine timestamp must roll back");
        assertEq(
            engine.sideCarryIndex(uint256(CfdTypes.Side.LONG)), expected.longCarryIndex, "long carry must roll back"
        );
        assertEq(
            engine.sideCarryIndex(uint256(CfdTypes.Side.SHORT)), expected.shortCarryIndex, "short carry must roll back"
        );
        assertEq(pool.lastReconcileTime(), expected.lastReconcileTime, "reconcile checkpoint must roll back");
        assertEq(
            pool.lastSeniorCouponCheckpointTime(),
            expected.lastSeniorCouponCheckpointTime,
            "coupon checkpoint must roll back"
        );
        assertEq(pool.seniorPrincipal(), expected.seniorPrincipal, "Senior principal must roll back");
        assertEq(pool.juniorPrincipal(), expected.juniorPrincipal, "Junior principal must roll back");
        assertEq(pool.seniorHighWaterMark(), expected.seniorHighWaterMark, "Senior HWM must roll back");
        assertEq(pool.accountedAssets(), expected.accountedAssets, "accounted assets must roll back");
        assertEq(usdc.balanceOf(address(pool)), expected.poolUsdc, "pool USDC must roll back");
        assertEq(usdc.balanceOf(address(juniorVault)), expected.vaultUsdc, "vault USDC must roll back");
        assertEq(juniorVault.totalSupply(), expected.juniorSupply, "vault supply must roll back");
        assertEq(juniorVault.accruedTotalSupply(), expected.accruedJuniorSupply, "accrued supply must roll back");
        assertEq(
            juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT),
            expected.maintenanceFeeRecipientShares,
            "fee-recipient shares must roll back"
        );
        assertEq(
            juniorVault.maintenanceFeeCheckpointBoundary(),
            expected.maintenanceFeeCheckpointBoundary,
            "maintenance-fee checkpoint must roll back"
        );
        assertEq(
            juniorVault.pendingMaintenanceFeeShares(),
            expected.pendingMaintenanceFeeShares,
            "pending maintenance fee must roll back"
        );
        assertEq(juniorVault.depositQueueHead(), expected.depositQueueHead, "deposit head must roll back");
        assertEq(juniorVault.depositQueueTail(), expected.depositQueueTail, "deposit tail must roll back");
        assertEq(juniorVault.redeemQueueHead(), expected.redeemQueueHead, "redeem head must roll back");
        assertEq(juniorVault.redeemQueueTail(), expected.redeemQueueTail, "redeem tail must roll back");
        assertEq(
            juniorVault.pendingDepositEscrowAssets(),
            expected.pendingDepositEscrowAssets,
            "pending deposit escrow must roll back"
        );
        assertEq(
            juniorVault.pendingRedeemEscrowShares(),
            expected.pendingRedeemEscrowShares,
            "pending redeem escrow must roll back"
        );
        assertEq(
            juniorVault.depositClaimEscrowShares(),
            expected.depositClaimEscrowShares,
            "deposit claim escrow must roll back"
        );
        assertEq(
            juniorVault.withdrawalEscrowAssets(), expected.withdrawalEscrowAssets, "withdrawal escrow must roll back"
        );
        assertEq(
            juniorVault.pendingDepositRequest(depositId, BOB),
            expected.pendingDepositAssets,
            "pending deposit must roll back"
        );
        assertEq(
            juniorVault.claimableDepositRequest(depositId, BOB),
            expected.claimableDepositAssets,
            "claimable deposit must roll back"
        );
        assertEq(
            juniorVault.pendingRedeemRequest(redeemId, ALICE),
            expected.pendingRedeemShares,
            "pending redemption must roll back"
        );
        assertEq(
            juniorVault.claimableRedeemRequest(redeemId, ALICE),
            expected.claimableRedeemShares,
            "claimable redemption must roll back"
        );
    }

}
