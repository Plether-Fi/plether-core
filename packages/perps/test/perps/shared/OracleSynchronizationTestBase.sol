// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

contract SynchronizationRefundReceiver {

    IPletherOracle public immutable oracle;
    bool public reject = true;
    bool public reentryRejected;

    constructor(
        IPletherOracle oracle_
    ) {
        oracle = oracle_;
    }

    receive() external payable {
        require(!reject, "reject refund");
        (bool ok,) = address(oracle).call(abi.encodeCall(IPletherOracle.claimEthRefund, ()));
        reentryRejected = !ok;
    }

    function claim() external {
        reject = false;
        oracle.claimEthRefund();
    }

    function execute(
        address router,
        uint64 id,
        bytes[] calldata data
    ) external payable {
        IPerpsKeeper(router).executeOrderBatch{value: msg.value}(id, data);
    }

}

/// @notice Explicit payload fixtures never source signed history from stored MockPyth prices.
abstract contract OracleSynchronizationTestBase is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant FEE = 1 gwei;
    // plether-app ccb8788ed7a3fbdcc258fc0c91f277949913974a: Keeper.hs v2OrderGasLimitCap.
    uint256 internal constant KEEPER_GAS_CAP = 30_000_000;

    function setUp() public override {
        super.setUp();
        bytes32[] memory ids = _synchronizationFeedIds();
        uint256[] memory weights = new uint256[](6);
        uint256[] memory bases = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            weights[i] = i == 5 ? 0.5e18 : 0.1e18;
            bases[i] = 1e8;
        }
        baseMockPyth.setAllPrices(ids, 100_000_000, -8, SETUP_TIMESTAMP);
        pletherOracle = new PletherOracle(
            address(engine), address(pool), address(baseMockPyth), ids, weights, bases, new bool[](6)
        );
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig(address(pletherOracle)));
        vm.warp(routerAdmin.oracleConfigActivationTime());
        routerAdmin.finalizeOracleConfig();
        baseMockPyth.setAllPrices(ids, 100_000_000, -8, block.timestamp);
        baseMockPyth.setSynchronizeLegacyUniquePrices(false);
        baseMockPyth.setFee(FEE);
        vm.deal(address(this), 100 ether);
        _fundTrader(ALICE, 10_000e6);
        _fundTrader(BOB, 10_000e6);
    }

    function _synchronizationFeedIds() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](6);
        for (uint256 i; i < 6; ++i) {
            ids[i] = bytes32(i + 1);
        }
    }

    function _payload(
        uint64 tick,
        uint64 previous
    ) internal pure returns (bytes[] memory data) {
        bytes32[] memory ids = _synchronizationFeedIds();
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            updates[i] = MockPyth.FeedUpdate(ids[i], MockPyth.MockPrice(100_000_000, 100_000, -8, tick, previous));
        }
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

    function _request(
        uint64 commit,
        bool strict
    ) internal pure returns (IPletherOracle.OrderExecutionRequest memory) {
        return IPletherOracle.OrderExecutionRequest(commit, 0, CfdTypes.Side.LONG, false, strict);
    }

    function _commit(
        address trader,
        uint256 target
    ) internal returns (uint64) {
        vm.prank(trader);
        return router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, target, false);
    }

    function _advance(
        uint64 tick
    ) internal {
        vm.warp(tick);
        vm.roll(block.number + 1);
    }

    function _assertCoverage(
        uint256 required
    ) internal view {
        bytes32[] memory ids = _synchronizationFeedIds();
        for (uint256 i; i < ids.length; ++i) {
            assertGe(baseMockPyth.getPriceUnsafe(ids[i]).publishTime, required);
        }
    }

    function _mixedBatch() internal returns (bytes[] memory data) {
        uint64 commit = uint64(block.timestamp);
        _commit(ALICE, 0);
        _advance(commit + 2);
        _commit(BOB, 0);
        _advance(commit + 3);
        bytes[] memory a = _payload(commit + 1, commit);
        bytes[] memory b = _payload(commit + 3, commit + 2);
        MockPyth.FeedUpdate[] memory first = abi.decode(a[0], (MockPyth.FeedUpdate[]));
        MockPyth.FeedUpdate[] memory second = abi.decode(b[0], (MockPyth.FeedUpdate[]));
        MockPyth.FeedUpdate[] memory both = new MockPyth.FeedUpdate[](first.length + second.length);
        for (uint256 i; i < first.length; ++i) {
            both[i] = first[i];
            both[first.length + i] = second[i];
        }
        data = new bytes[](1);
        data[0] = abi.encode(both);
    }

}
