// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {ICfdEngineCore} from "../../src/perps/interfaces/ICfdEngineCore.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {PositionRiskAccountingLib} from "../../src/perps/libraries/PositionRiskAccountingLib.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract OrderRouterFailurePolicyHarness is OrderRouter {

    constructor(
        address engine_,
        address engineLens_,
        address vault_
    )
        OrderRouter(
            engine_,
            engineLens_,
            vault_,
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        )
    {}

    function failedOutcomeFromEngineRevert(
        CfdTypes.Order memory order,
        bytes memory revertData
    ) external pure returns (uint8) {
        return uint8(_failedOutcomeFromEngineRevert(order, revertData));
    }

}

contract OrderRouterPolicyMatrixTest is BasePerpTest {

    using stdStorage for StdStorage;

    address internal constant ALICE = address(0x111);
    address internal constant BOB = address(0x222);
    address internal constant KEEPER = address(0x999);

    function test_ExpiredOpenPaysClearerAndDoesNotRefundTrader() public {
        _fundTrader(ALICE, 10_000e6);
        bytes32 traderAccountId = bytes32(uint256(uint160(ALICE)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(KEEPER)));

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(traderAccountId);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);

        vm.warp(block.timestamp + router.maxOrderAge() + 1);
        bytes[] memory empty;
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId) - keeperSettlementBefore,
            pending.executionBountyUsdc,
            "Expired open should pay the clearer from reserved bounty settlement"
        );
        assertEq(
            clearinghouse.balanceUsdc(traderAccountId) - traderSettlementBefore,
            0,
            "Expired open cleanup should not refund the trader after the bounty was already escrowed"
        );
    }

    function test_ExpiredClosePaysClearer() public {
        bytes32 accountId = bytes32(uint256(uint160(ALICE)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(KEEPER)));
        _fundTrader(ALICE, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, true);

        uint256 traderWalletBefore = usdc.balanceOf(ALICE);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);

        vm.warp(block.timestamp + router.maxOrderAge() + 1);
        bytes[] memory empty;
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId) - keeperSettlementBefore,
            200_000,
            "Expired close should still credit the clearer even after carry-aware settlement crediting"
        );
        assertEq(usdc.balanceOf(ALICE) - traderWalletBefore, 0, "Expired close should not refund the trader wallet");
    }

    function test_SlippageOpenForfeitsBountyToProtocol() public {
        _fundJunior(BOB, 1_000_000e6);
        _fundTrader(ALICE, 50_000e6);
        bytes32 traderAccountId = bytes32(uint256(uint160(ALICE)));

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1.5e8, false);

        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(traderAccountId);
        uint256 keeperEthBefore = KEEPER.balance;

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.deal(ALICE, 1 ether);
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        assertEq(KEEPER.balance - keeperEthBefore, 0, "Open slippage miss should not pay the clearer");
        assertEq(
            clearinghouse.balanceUsdc(traderAccountId) - traderSettlementBefore,
            0,
            "Open slippage miss should not further change trader settlement after the bounty was escrowed"
        );
    }

    function test_OpenSlippageCleanup_DoesNotFurtherCreditTrader() public {
        bytes32 traderAccountId = bytes32(uint256(uint160(ALICE)));

        _fundTrader(ALICE, 20_000e6);
        _open(traderAccountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 warpedTime = block.timestamp + 30 days;
        vm.warp(warpedTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(warpedTime));

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1.5e8, false);

        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(traderAccountId);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        assertEq(
            clearinghouse.balanceUsdc(traderAccountId),
            traderSettlementBefore,
            "Open-order slippage cleanup should not change trader settlement after escrow"
        );
    }

    function test_CreditKeeperExecutionBounty_UsesCachedMarkWhenCurrentMarkIsStale() public {
        bytes32 traderAccountId = bytes32(uint256(uint160(ALICE)));

        _fundTrader(ALICE, 20_000e6);
        _open(traderAccountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(traderAccountId);
        uint64 carryTimestampBefore = engine.getPositionLastCarryTimestamp(traderAccountId);
        vm.prank(address(router));
        engine.creditKeeperExecutionBounty(ALICE, 1e6, 110_000_000, uint64(block.timestamp));

        assertEq(
            engine.getPositionLastCarryTimestamp(traderAccountId),
            uint64(block.timestamp),
            "Stale cached mark should still checkpoint carry before crediting settlement"
        );
        assertEq(engine.lastMarkPrice(), 110_000_000, "Refund cleanup should refresh the cached engine mark");
        assertLt(
            carryTimestampBefore, engine.getPositionLastCarryTimestamp(traderAccountId), "Carry clock should advance"
        );
        assertGt(
            clearinghouse.balanceUsdc(traderAccountId),
            traderSettlementBefore,
            "Validated stale helper credit should still reach settlement"
        );
    }

    function test_SlippageCloseForfeitsBountyToProtocol() public {
        bytes32 accountId = bytes32(uint256(uint160(ALICE)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(KEEPER)));
        usdc.mint(ALICE, 400_500_000);
        vm.startPrank(ALICE);
        usdc.approve(address(clearinghouse), 400_500_000);
        clearinghouse.deposit(accountId, 400_500_000);
        vm.stopPrank();

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8, false);
        bytes[] memory openPrice = new bytes[](1);
        openPrice[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        router.executeOrder(1, openPrice);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 0.8e8, true);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(2, closePrice);

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId) - keeperSettlementBefore,
            200_000,
            "Close slippage miss should still credit the clearer through the carry-aware keeper settlement path"
        );
        assertGe(
            engine.accumulatedFeesUsdc() - feesBefore,
            0,
            "Close slippage miss should not reduce accumulated protocol fees"
        );
    }

    function test_CreditKeeperExecutionBounty_RealizesCarryBeforeCreditingSettlement() public {
        bytes32 keeperAccountId = bytes32(uint256(uint160(KEEPER)));

        _fundTrader(KEEPER, 20_000e6);
        _open(keeperAccountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 warpedTime = block.timestamp + 30 days;
        vm.warp(warpedTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(warpedTime));

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, keeperSettlementBefore),
            _riskParams().baseCarryBps,
            30 days
        );

        usdc.mint(address(clearinghouse), 1e6);
        vm.prank(address(router));
        engine.creditKeeperExecutionBounty(KEEPER, 1e6, 1e8, uint64(warpedTime));

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId),
            keeperSettlementBefore + 1e6 - expectedCarry,
            "Keeper execution bounty credit should realize carry before crediting settlement"
        );
    }

    function test_UntypedCloseRevertPaysClearerEvenWhenKeeperMarkIsStale() public {
        bytes32 accountId = bytes32(uint256(uint160(ALICE)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(KEEPER)));

        _fundTrader(KEEPER, 20_000e6);
        _open(keeperAccountId, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);

        _fundTrader(ALICE, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, true);

        bytes32 positionMarginSlot = keccak256(abi.encode(accountId, uint256(1)));
        vm.store(address(clearinghouse), positionMarginSlot, bytes32(uint256(0)));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        uint64 carryTimestampBefore = engine.getPositionLastCarryTimestamp(keeperAccountId);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        assertGt(
            clearinghouse.balanceUsdc(keeperAccountId),
            keeperSettlementBefore,
            "Failed-order clearer payout should still credit settlement when the cached mark is stale"
        );
        assertGe(
            engine.getPositionLastCarryTimestamp(keeperAccountId),
            uint64(block.timestamp),
            "Stale-mark clearer payout should checkpoint carry before mutating the basis"
        );
        assertLt(
            carryTimestampBefore, engine.getPositionLastCarryTimestamp(keeperAccountId), "Carry clock should advance"
        );
    }

    function test_ProtocolInvalidationRefundsTrader() public {
        _fundTrader(ALICE, 10_000e6);
        bytes32 traderAccountId = bytes32(uint256(uint160(ALICE)));

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);

        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        assertEq(usdc.balanceOf(KEEPER) - keeperWalletBefore, 0, "Protocol invalidation should not pay the clearer");
        assertEq(
            clearinghouse.balanceUsdc(traderAccountId),
            10_000e6,
            "Protocol invalidation should restore the trader bounty inside clearinghouse custody"
        );
    }

    function test_UserInvalidPaysClearer() public {
        address eve = address(0xE223);
        bytes32 eveAccount = bytes32(uint256(uint160(eve)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(KEEPER)));

        vm.startPrank(eve);
        usdc.mint(eve, 1e6);
        usdc.approve(address(clearinghouse), 1e6);
        clearinghouse.deposit(eveAccount, 1e6);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 1e8, false);
        vm.stopPrank();

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId) - keeperSettlementBefore,
            200_000,
            "User-invalid open should pay the clearer into clearinghouse custody"
        );
        assertEq(
            uint256(_orderRecord(1).status),
            uint256(IOrderRouterAccounting.OrderStatus.Failed),
            "User-invalid order should fail terminally"
        );
    }

    function test_MarginDrainedByFeesTypedRevertMapsToClearerFull() public {
        OrderRouterFailurePolicyHarness harness =
            new OrderRouterFailurePolicyHarness(address(engine), address(engineLens), address(pool));
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: bytes32(uint256(uint160(ALICE))),
            sizeDelta: 10_000e18,
            marginDelta: 100e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        bytes memory revertData = abi.encodeWithSelector(
            ICfdEngineCore.CfdEngine__TypedOrderFailure.selector,
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
            uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
            false
        );

        assertEq(
            harness.failedOutcomeFromEngineRevert(order, revertData),
            0,
            "MARGIN_DRAINED_BY_FEES must stay on the clearer-paid path even if failure-category wiring drifts"
        );
    }

    function test_UntypedCloseRevertPaysClearer() public {
        bytes32 accountId = bytes32(uint256(uint160(ALICE)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(KEEPER)));
        _fundTrader(ALICE, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, true);

        bytes32 positionMarginSlot = keccak256(abi.encode(accountId, uint256(1)));
        vm.store(address(clearinghouse), positionMarginSlot, bytes32(uint256(0)));

        uint256 traderWalletBefore = usdc.balanceOf(ALICE);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId) - keeperSettlementBefore,
            200_000,
            "Untyped close revert should keep the clearer-paid fallback"
        );
        assertEq(
            usdc.balanceOf(ALICE) - traderWalletBefore, 0, "Untyped close revert should not refund the trader wallet"
        );
    }

    function test_NonSlippageCloseTerminalFailureStillPaysClearer() public {
        bytes32 accountId = bytes32(uint256(uint160(ALICE)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(KEEPER)));
        _fundTrader(ALICE, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, true);

        bytes32 positionMarginSlot = keccak256(abi.encode(accountId, uint256(1)));
        vm.store(address(clearinghouse), positionMarginSlot, bytes32(uint256(0)));

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId) - keeperSettlementBefore,
            200_000,
            "Non-slippage close terminal failures should stay on the clearer-paid path"
        );
    }

}
