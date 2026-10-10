// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {SettlementMonitorLens} from "@plether/perps/SettlementMonitorLens.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {SettlementMonitorViewTypes} from "@plether/perps/interfaces/SettlementMonitorViewTypes.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract SettlementMonitorOracleBindingMock {

    address public immutable engine;
    address public immutable housePool;
    address public immutable pyth;

    constructor(
        address engine_,
        address housePool_,
        address pyth_
    ) {
        engine = engine_;
        housePool = housePool_;
        pyth = pyth_;
    }

}

abstract contract SettlementMonitorLensTestFixture is BasePerpTest {

    using stdStorage for StdStorage;

    uint256 internal constant EPOCH_DURATION = 1 hours;
    uint256 internal constant REQUEST_CUTOFF = 5 minutes;
    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    bytes4 internal constant DEPOSIT_QUEUE_HEAD_SELECTOR = bytes4(keccak256("depositQueueHead()"));
    bytes4 internal constant DEPOSIT_QUEUE_TAIL_SELECTOR = bytes4(keccak256("depositQueueTail()"));
    bytes4 internal constant REDEEM_QUEUE_HEAD_SELECTOR = bytes4(keccak256("redeemQueueHead()"));
    bytes4 internal constant REDEEM_QUEUE_TAIL_SELECTOR = bytes4(keccak256("redeemQueueTail()"));
    bytes4 internal constant DEPOSIT_EPOCHS_SELECTOR = bytes4(keccak256("depositEpochs(uint256)"));
    bytes4 internal constant DEPOSIT_QUEUE_STATE_SELECTOR = bytes4(keccak256("depositEpochQueueState(uint256)"));
    bytes4 internal constant REDEEM_EPOCHS_SELECTOR = bytes4(keccak256("redeemEpochs(uint256)"));
    bytes4 internal constant REDEEM_QUEUE_STATE_SELECTOR = bytes4(keccak256("redeemEpochQueueState(uint256)"));
    bytes4 internal constant MATURED_DEPOSIT_HEAD_SELECTOR = bytes4(keccak256("getMaturedDepositHead(uint256)"));
    bytes4 internal constant MATURED_REDEEM_HEAD_SELECTOR = bytes4(keccak256("getMaturedRedeemHead(uint256)"));
    bytes4 internal constant LP_EPOCH_SETTLEMENT_PAUSED_SELECTOR = bytes4(keccak256("lpEpochSettlementPaused()"));
    bytes4 internal constant MAINTENANCE_FEE_APR_BPS_SELECTOR = bytes4(keccak256("maintenanceFeeAprBps()"));
    bytes4 internal constant MAINTENANCE_FEE_RECIPIENT_SELECTOR = bytes4(keccak256("maintenanceFeeRecipient()"));

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA7E);
    address internal constant EVE = address(0xE0E);
    address internal constant TRADER = address(0x7A0E2);
    uint256 internal constant SATURDAY_FROZEN = 1_709_985_600;

    SettlementMonitorLens internal monitorLens;

    function setUp() public override {
        super.setUp();
        monitorLens = new SettlementMonitorLens(address(router));
    }

    function _assertCorruptPendingDepositHead(
        uint256 headEpoch,
        uint256[4] memory epoch
    ) internal {
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(DEPOSIT_EPOCHS_SELECTOR, headEpoch),
            abi.encode(epoch[0], epoch[1], epoch[2], epoch[3], false)
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(headEpoch + 1);

        assertTrue(status.hasMaturedWork, "canonical getter still exposes the real pending head");
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "impossible pending-deposit lifecycle fields must be critical"
        );
        vm.clearMockedCalls();
    }

    function _assertCorruptPendingRedeemHead(
        uint256 headEpoch,
        uint256[9] memory epoch
    ) internal {
        vm.mockCall(
            address(juniorVault),
            abi.encodeWithSelector(REDEEM_EPOCHS_SELECTOR, headEpoch),
            abi.encode(epoch[0], epoch[1], epoch[2], epoch[3], epoch[4], epoch[5], epoch[6], epoch[7], epoch[8], false)
        );

        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(headEpoch + 1);

        assertTrue(status.hasMaturedWork, "canonical getter still exposes the real pending head");
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertTrue(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "impossible pending-redeem lifecycle fields must be critical"
        );
        vm.clearMockedCalls();
    }

    function _assertAuxiliaryHeadUnknownKeepsWork(
        uint256 headEpoch
    ) internal view {
        SettlementMonitorViewTypes.SettlementStatus memory status = monitorLens.getSettlementStatus(headEpoch + 1);
        assertTrue(status.hasMaturedWork);
        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertEq(status.executionPathDependencyMask, 0);
        assertTrue(_hasDependency(status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.JuniorVault));
        assertFalse(
            _hasCriticalFault(status.junior.faultMask, SettlementMonitorViewTypes.CriticalFault.QueueEndpoint),
            "noncanonical ABI booleans are unreadable rather than proven corruption"
        );
    }

    function _requestTwoDepositEpochs() internal returns (uint256 firstEpoch, uint256 secondEpoch) {
        uint256 firstStart = ((block.timestamp + 2 hours) / EPOCH_DURATION) * EPOCH_DURATION;
        vm.warp(firstStart - REQUEST_CUTOFF - 1);
        firstEpoch = _requestDeposit(juniorVault, ALICE, 10_000e6);
        vm.warp(firstStart + EPOCH_DURATION - REQUEST_CUTOFF - 1);
        secondEpoch = _requestDeposit(juniorVault, BOB, 10_000e6);
        assertEq(secondEpoch, firstEpoch + 1);
    }

    function _requestDeposit(
        TrancheVault vault,
        address owner,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(owner, assets);
        vm.startPrank(owner);
        usdc.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, owner, owner);
        vm.stopPrank();
    }

    function _requestRedeem(
        TrancheVault vault,
        address owner,
        uint256 shares
    ) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner, owner);
    }

    function _openMonitorPosition() internal {
        _fundTrader(TRADER, 200e6);
        _open(TRADER, CfdTypes.Side.LONG, 1000e18, 100e6, 100_000_000);
    }

    function _setCurrentBasket(
        uint256 price,
        uint64 confidence,
        uint256 publishTime
    ) internal {
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(price)), confidence, int32(-8), publishTime);
    }

    function _validPoolReconcileSnapshot() internal returns (IPletherOracle.PriceSnapshot memory snapshot) {
        vm.clearMockedCalls();
        (snapshot,) = router.pletherOracle().getLatestPoolReconcilePrice();
    }

    function _assertMalformedOracleSnapshot(
        uint256 observedEpoch,
        IPletherOracle.PriceSnapshot memory snapshot
    ) internal {
        vm.clearMockedCalls();
        vm.mockCall(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            abi.encode(snapshot, uint256(50_000))
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(observedEpoch);

        assertEq(
            uint8(observation.status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh),
            "malformed oracle output must not erase a known atomic route"
        );
        assertFalse(observation.oracle.readSucceeded);
        assertFalse(observation.oracle.policyValid);
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );
        assertTrue(
            _hasDependency(observation.status.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle)
        );
        assertEq(observation.status.executionPathDependencyMask, 0);
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function _assertMalformedNarrowOracleError(
        bytes memory revertData
    ) internal {
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(router.pletherOracle()),
            abi.encodeWithSelector(IPletherOracle.getLatestPoolReconcilePrice.selector),
            revertData
        );

        SettlementMonitorViewTypes.SettlementObservation memory observation =
            monitorLens.getSettlementObservation(pool.currentLpEpoch());

        assertEq(
            uint8(observation.status.requiredExecutionPath),
            uint8(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork)
        );
        assertTrue(
            _hasDependency(observation.oracle.dependencyFailureMask, SettlementMonitorViewTypes.Dependency.Oracle),
            "noncanonical narrow ABI words are not authentic policy evidence"
        );
        assertFalse(observation.observationComplete);
        assertEq(observation.completeObservationDigest, bytes32(0));
    }

    function _hasWarning(
        uint256 mask,
        SettlementMonitorViewTypes.Warning warning
    ) internal pure returns (bool) {
        return mask & (1 << uint256(warning)) != 0;
    }

    function _hasOperationalBlocker(
        uint256 mask,
        SettlementMonitorViewTypes.OperationalBlocker blocker
    ) internal pure returns (bool) {
        return mask & (1 << uint256(blocker)) != 0;
    }

    function _hasCriticalFault(
        uint256 mask,
        SettlementMonitorViewTypes.CriticalFault fault
    ) internal pure returns (bool) {
        return mask & (1 << uint256(fault)) != 0;
    }

    function _hasDependency(
        uint256 mask,
        SettlementMonitorViewTypes.Dependency dependency
    ) internal pure returns (bool) {
        return mask & (1 << uint256(dependency)) != 0;
    }

    function _hasDeferral(
        uint256 mask,
        SettlementMonitorViewTypes.DepositDeferral deferral
    ) internal pure returns (bool) {
        return mask & (1 << uint256(deferral)) != 0;
    }

}
