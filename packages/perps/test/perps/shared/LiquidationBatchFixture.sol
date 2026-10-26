// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

import {Vm} from "forge-std/Vm.sol";

interface ILiquidationBatchSidecarErrors {

    error OrderRouterLiquidationBatchSidecar__OnlyDelegateCall();

}

interface IDelegatedRouterConfig {

    function applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external;

}

contract ForeignLiquidationBatchDelegateHarness {

    function execute(
        address sidecar,
        address[] calldata accounts,
        bytes[] calldata updateData
    ) external payable returns (bool ok, bytes memory result) {
        (ok, result) =
            sidecar.delegatecall(abi.encodeCall(IPerpsKeeper.executeLiquidationBatch, (accounts, updateData)));
    }

    function applyRouterConfig(
        address sidecar,
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external returns (bool ok, bytes memory result) {
        (ok, result) = sidecar.delegatecall(abi.encodeCall(IDelegatedRouterConfig.applyRouterConfig, (config)));
    }

}

abstract contract LiquidationBatchTestFixture is BasePerpTest {

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;
    uint256 internal constant LIQUIDATION_PRICE = 102_000_000;
    uint256 internal constant NEUTRAL_PRICE = 100_000_000;
    uint256 internal constant LONG_ADVERSE_PRICE = 100_020_000;
    uint256 internal constant SHORT_ADVERSE_PRICE = 99_980_000;
    uint256 internal constant SATURDAY_NOON = 1_710_021_600;

    address internal constant ELIGIBLE_ONE = address(0xBA7C0001);
    address internal constant SOLVENT = address(0xBA7C0002);
    address internal constant NO_POSITION = address(0xBA7C0003);
    address internal constant ELIGIBLE_TWO = address(0xBA7C0004);
    address internal constant KEEPER = address(0xBA7CB0B0);

    bytes32 internal constant POSITION_LIQUIDATED_TOPIC =
        keccak256("PositionLiquidated(address,uint8,uint256,uint256,uint256)");
    bytes32 internal constant LIQUIDATION_BATCH_ITEM_TOPIC =
        keccak256("LiquidationBatchItem(uint256,address,uint8,uint256,bytes4)");

    function _assertDirectionalLiquidationBatch(
        bool checkpointSetupCarry
    ) internal {
        address long = address(0xBA7CB011);
        address short = address(0xBA7CBEA2);

        _fundTrader(long, 2100e6);
        _fundTrader(short, 2100e6);
        _open(long, CfdTypes.Side.LONG, 100_000e18, 2000e6, NEUTRAL_PRICE);
        _open(short, CfdTypes.Side.SHORT, 100_000e18, 2000e6, NEUTRAL_PRICE);

        vm.warp(SATURDAY_NOON - 90_001);
        router.updateMarkPrice(_liveLiquidationData(NEUTRAL_PRICE));
        uint64 precloseMarkTime = engine.lastMarkTime();
        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup must use the frozen FAD oracle policy");

        // Coverage's minimum-optimization bytecode can exhaust the production item cap when it also collects carry.
        // Keep pricing assertions independent of that cost; the production gas test retains pending carry and the cap.
        assertGt(_expectedIndexedCarryAssets(long), 0, "setup must accrue long carry");
        assertGt(_expectedIndexedCarryAssets(short), 0, "setup must accrue short carry");
        if (checkpointSetupCarry) {
            vm.startPrank(address(clearinghouse));
            engine.realizeCarryBeforeMarginChange(long);
            engine.realizeCarryBeforeMarginChange(short);
            vm.stopPrank();
        }

        baseMockPyth.setAllPrices(
            _basePythFeedIds(), int64(uint64(NEUTRAL_PRICE)), uint64(100_000), int32(-8), block.timestamp
        );
        assertTrue(
            engineLens.previewLiquidation(long, LONG_ADVERSE_PRICE).liquidatable, "FAD long setup must be liquidatable"
        );
        assertTrue(
            engineLens.previewLiquidation(short, SHORT_ADVERSE_PRICE).liquidatable,
            "FAD short setup must be liquidatable"
        );

        address[] memory accounts = new address[](2);
        accounts[0] = long;
        accounts[1] = short;
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.recordLogs();
        vm.prank(KEEPER);
        uint256 nextIndex = IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(nextIndex, accounts.length, "both items must finish within their gas caps");
        assertEq(_positionSize(long), 0, "long liquidation must commit");
        assertEq(_positionSize(short), 0, "short liquidation must commit");

        (bool foundLong, CfdTypes.Side longSide, uint256 longPrice) = _liquidationEvent(logs, long);
        (bool foundShort, CfdTypes.Side shortSide, uint256 shortPrice) = _liquidationEvent(logs, short);

        assertTrue(foundLong, "long liquidation event must be emitted");
        assertTrue(foundShort, "short liquidation event must be emitted");
        assertEq(uint256(longSide), uint256(CfdTypes.Side.LONG), "long event side");
        assertEq(uint256(shortSide), uint256(CfdTypes.Side.SHORT), "short event side");
        assertEq(longPrice, LONG_ADVERSE_PRICE, "long must execute above the neutral basket");
        assertEq(shortPrice, SHORT_ADVERSE_PRICE, "short must execute below the neutral basket");
        assertEq(engine.lastMarkPrice(), NEUTRAL_PRICE, "global mark must remain the neutral basket price");
        assertEq(engine.lastMarkTime(), precloseMarkTime, "frozen liquidation must replay the final live mark");
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount() - pythCallsBefore,
            0,
            "frozen liquidation must not update Pyth storage"
        );
    }

    function _liveLiquidationData(
        uint256 price
    ) internal returns (bytes[] memory data) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        bytes32[] memory ids = _basePythFeedIds();
        MockPyth.FeedUpdate[] memory ticks = new MockPyth.FeedUpdate[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            ticks[i] = MockPyth.FeedUpdate(ids[i], MockPyth.MockPrice(int64(uint64(price)), 0, -8, block.timestamp, 0));
        }
        data = new bytes[](1);
        data[0] = abi.encode(ticks);
    }

    function _fundAndOpenThinLong(
        address account
    ) internal {
        _fundTrader(account, 300e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, NEUTRAL_PRICE);
    }

    function _queueOpen(
        address account,
        uint256 marginAssets
    ) internal returns (uint64 orderId) {
        orderId = router.nextCommitId();
        vm.prank(account);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, marginAssets, type(uint256).max, false);
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

    function _assertReservationUnchanged(
        address account,
        IOrderRouterAccounting.AccountReservationView memory expected
    ) internal view {
        IOrderRouterAccounting.AccountReservationView memory actual = router.getAccountReservations(account);
        assertEq(actual.committedMarginAssets, expected.committedMarginAssets, "committed margin reservation changed");
        assertEq(actual.executionBountyAssets, expected.executionBountyAssets, "execution bounty reservation changed");
        assertEq(actual.pendingOrderCount, expected.pendingOrderCount, "pending order count changed");
    }

    function _assertBatchItemEvent(
        Vm.Log[] memory logs,
        uint256 expectedIndex,
        address expectedAccount,
        IOrderRouterErrors.LiquidationBatchResult expectedResult,
        bytes4 expectedSelector
    ) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length != 3 || logs[i].topics[0] != LIQUIDATION_BATCH_ITEM_TOPIC
                    || uint256(logs[i].topics[1]) != expectedIndex
                    || address(uint160(uint256(logs[i].topics[2]))) != expectedAccount
            ) {
                continue;
            }

            assertEq(logs[i].emitter, address(router), "delegatecall event must be emitted from Router");
            (uint8 result, uint256 keeperBountyAssets, bytes4 selector) =
                abi.decode(logs[i].data, (uint8, uint256, bytes4));
            assertEq(result, uint8(expectedResult), "batch result classification");
            assertEq(keeperBountyAssets, 0, "skipped or failed item must not report a bounty");
            assertEq(selector, expectedSelector, "batch result selector");
            return;
        }
        fail("expected liquidation batch item event not found");
    }

    function _liquidationEvent(
        Vm.Log[] memory logs,
        address account
    ) internal view returns (bool found, CfdTypes.Side side, uint256 executionPrice) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter != address(engine) || logs[i].topics.length < 2
                    || logs[i].topics[0] != POSITION_LIQUIDATED_TOPIC
            ) {
                continue;
            }
            address eventAccount = address(uint160(uint256(logs[i].topics[1])));
            if (eventAccount != account) {
                continue;
            }

            uint256 size;
            uint256 keeperBounty;
            (side, size, executionPrice, keeperBounty) =
                abi.decode(logs[i].data, (CfdTypes.Side, uint256, uint256, uint256));
            size;
            keeperBounty;
            return (true, side, executionPrice);
        }
    }

}
