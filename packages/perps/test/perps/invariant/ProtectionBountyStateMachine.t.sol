// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes as Protection} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

/// @notice Bounded stateful fuzzing of the real protection, Router, and clearinghouse integration.
/// @dev Expected amounts come only from fixed configuration and successful action inputs. Protocol return values
///      supply identities, never expected balances. Each step checks the entire model, including historical ids.
///      Every fuzz case exercises each terminal path and repeated retries before mixing 32 further actions across
///      three accounts. An unexpected action revert fails the case instead of silently discarding the transition.
contract ProtectionBountyStateMachineTest is BasePerpTest {

    uint256 internal constant OPEN_BOUNTY = 250_000;
    uint256 internal constant TRIGGER_BOUNTY = 350_000;
    uint256 internal constant CLOSE_BOUNTY = 650_000;
    uint256 internal constant SIZE = 10_000e18;
    uint256 internal constant MARGIN = 2000e6;
    uint256 internal constant ENTRY_PRICE = 1e8;
    uint256 internal constant STOP_PRICE = 110_000_000;
    address internal constant TRIGGER_KEEPER = address(0x71166E);
    address internal constant EXECUTION_KEEPER = address(0xE0EC);
    address internal constant LIQUIDATOR = address(0x119);
    address[3] internal actors = [address(0xA11CE), address(0xB0B), address(0xCA201)];

    struct ModelProtection {
        address account;
        uint64 parent;
        uint64 attempt;
        Protection.PositionProtectionStatus status;
        uint256 trigger;
        uint256 execution;
    }

    struct ModelOrder {
        address account;
        uint64 protectionId;
        uint64 commitTime;
        uint64 deadline;
        bool close;
        bool pending;
        uint256 bounty;
    }

    struct ModelAccount {
        bool position;
        uint64 protectionId;
        uint64 orderId;
        uint256 funded;
        uint256 paid;
        uint256 refunded;
        uint256 forfeited;
    }

    mapping(uint64 => ModelProtection) internal protections;
    mapping(uint64 => ModelOrder) internal orders;
    mapping(address => ModelAccount) internal accounts;
    uint64[] internal protectionIds;
    uint64[] internal orderIds;
    uint256 internal triggerPaid;
    uint256 internal executionPaid;
    IPositionProtectionActions internal actions;
    IPositionProtectionViews internal views;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        // Isolate bounty conservation from carry and VPI; the package invariants cover those economics separately.
        params.baseCarryBps = 0;
        params.vpiFactor = 0;
    }

    function setUp() public override {
        super.setUp();
        actions = IPositionProtectionActions(address(router.positionProtectionBook()));
        views = IPositionProtectionViews(address(router.positionProtectionBook()));
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.positionProtectionCommitsEnabled = true;
        config.positionProtectionTriggerBountyUsdc = TRIGGER_BOUNTY;
        config.closeOrderExecutionBountyUsdc = CLOSE_BOUNTY;
        config.minOpenOrderExecutionBountyUsdc = OPEN_BOUNTY;
        config.maxOpenOrderExecutionBountyUsdc = OPEN_BOUNTY;
        config.orderSettlementWindow = config.maxOrderAge;
        _setRouterConfig(config);
    }

    function testFuzz_ProtectionBountiesFollowIndependentLedger(
        uint256 seed
    ) public {
        uint256 actorOffset = seed % actors.length;
        address alice = actors[actorOffset];
        address bob = actors[(actorOffset + 1) % actors.length];
        address carol = actors[(actorOffset + 2) % actors.length];

        // Different accounts deliberately share numeric id 1 in the protection and order namespaces.
        _createExisting(alice);
        _attach(bob);
        assertEq(protectionIds[0], orderIds[0], "fixture must collide across namespaces");
        _cancel(bob); // Parent stays pending after its protection is cancelled.
        _riskOff();
        _cancel(alice);

        _createExisting(alice);
        _failedTrigger(alice); // Failure after the first classification take must roll everything back.
        _trigger(alice);
        for (uint256 i; i < 2 + seed % 3; ++i) {
            _expireHead();
            _retry(alice);
        }
        _liquidate(alice); // Live retried child.

        _attach(bob);
        _executeHead(); // Successful parent arms attached protection.
        _trigger(bob);
        _executeHead(); // Successful protection execution pays the close keeper once.
        _attach(carol);
        _riskOff(); // Attached parent and both protection bounties refund together.
        _attach(carol);
        _expireHead(); // Expiry pays the ordinary order bounty but refunds the staged protection.
        _createExisting(carol);
        _liquidate(carol); // Dormant trigger plus execution reserve.
        _createExisting(carol);
        _trigger(carol);
        _expireHead();
        _liquidate(carol); // Latched execution reserve.

        for (uint256 step; step < 32; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _step(actors[seed % actors.length], seed >> 8);
        }

        _riskOff();
        for (uint256 i; i < actors.length; ++i) {
            if (accounts[actors[i]].protectionId != 0) {
                _liquidate(actors[i]);
            }
            assertEq(clearinghouse.totalBountyReservationsUsdc(actors[i]), 0, "drain leaves no reservation");
        }
        _assertModel();
    }

    function _step(
        address account,
        uint256 choice
    ) internal {
        ModelAccount storage a = accounts[account];
        ModelProtection storage p = protections[a.protectionId];
        if (a.orderId != 0 && !orders[a.orderId].close) {
            if (choice % 4 == 0 && a.protectionId != 0) {
                _cancel(account);
            } else if (choice % 4 == 1) {
                _expireHead();
            } else if (choice % 4 == 2) {
                _executeHead();
            } else {
                _riskOff();
            }
        } else if (p.status == Protection.PositionProtectionStatus.Armed) {
            if (choice % 5 == 0) {
                _cancel(account);
            } else if (choice % 5 == 1) {
                _liquidate(account);
            } else if (choice % 5 == 2) {
                _failedTrigger(account);
            } else {
                _trigger(account);
            }
        } else if (p.status == Protection.PositionProtectionStatus.Triggered) {
            if (choice % 3 == 0) {
                _expireHead();
            } else if (choice % 3 == 1) {
                _executeHead();
            } else {
                _liquidate(account);
            }
        } else if (p.status == Protection.PositionProtectionStatus.Latched) {
            if (choice % 3 == 0) {
                _liquidate(account);
            } else {
                _retry(account);
            }
        } else if (a.position || choice % 2 == 0) {
            _createExisting(account);
        } else {
            _attach(account);
        }
    }

    function _createExisting(
        address account
    ) internal {
        _fundTrader(account, 10_000e6);
        router.updateMarkPrice(_freshData(ENTRY_PRICE, 0));
        if (!accounts[account].position) {
            _open(account, CfdTypes.Side.LONG, SIZE, MARGIN, ENTRY_PRICE);
            accounts[account].position = true;
        }
        uint256 balanceBefore = clearinghouse.balanceUsdc(account);
        vm.prank(account);
        uint64 id = actions.createPositionProtection(_params());
        _newProtection(account, id, 0, Protection.PositionProtectionStatus.Armed);
        assertEq(clearinghouse.balanceUsdc(account), balanceBefore, "create only locks funds");
        _assertModel();
    }

    function _attach(
        address account
    ) internal {
        _fundTrader(account, 10_000e6);
        router.updateMarkPrice(_freshData(ENTRY_PRICE, 0));
        OrderV2Types.OrderRequest memory request = _request();
        uint256 balanceBefore = clearinghouse.balanceUsdc(account);
        vm.prank(account);
        (uint64 orderId, uint64 protectionId) = actions.commitOpenOrderWithProtection(request, _params());
        _newProtection(account, protectionId, orderId, Protection.PositionProtectionStatus.PendingOpen);
        _newOrder(account, orderId, protectionId, false);
        accounts[account].funded += OPEN_BOUNTY;
        assertEq(clearinghouse.balanceUsdc(account), balanceBefore, "attach only locks funds");
        _assertModel();
    }

    function _cancel(
        address account
    ) internal {
        ModelProtection storage p = protections[accounts[account].protectionId];
        uint256 balanceBefore = clearinghouse.balanceUsdc(account);
        vm.prank(account);
        actions.cancelPositionProtection(accounts[account].protectionId);
        accounts[account].refunded += p.trigger + p.execution;
        p.trigger = 0;
        p.execution = 0;
        p.status = Protection.PositionProtectionStatus.Cancelled;
        accounts[account].protectionId = 0;
        assertEq(clearinghouse.balanceUsdc(account), balanceBefore, "refund cannot mint or transfer settlement");
        _assertModel();
    }

    function _trigger(
        address account
    ) internal {
        uint64 id = accounts[account].protectionId;
        bytes[] memory data = _freshData(STOP_PRICE, 0);
        vm.prank(TRIGGER_KEEPER);
        uint64 orderId = actions.triggerPositionProtection(id, data);
        ModelProtection storage p = protections[id];
        accounts[account].paid += TRIGGER_BOUNTY;
        triggerPaid += TRIGGER_BOUNTY;
        p.trigger = 0;
        p.execution = 0;
        p.attempt = orderId;
        p.status = Protection.PositionProtectionStatus.Triggered;
        _newOrder(account, orderId, id, true);
        _assertModel();
    }

    function _failedTrigger(
        address account
    ) internal {
        bytes[] memory data = _freshData(STOP_PRICE, 0);
        vm.mockCallRevert(
            address(clearinghouse),
            abi.encodeWithSelector(IMarginClearinghouse.moveBountyReservation.selector),
            "forced transfer failure"
        );
        vm.expectRevert(bytes("forced transfer failure"));
        vm.prank(TRIGGER_KEEPER);
        actions.triggerPositionProtection(accounts[account].protectionId, data);
        vm.clearMockedCalls();
        _assertModel();
    }

    function _retry(
        address account
    ) internal {
        uint64 id = accounts[account].protectionId;
        uint256 balanceBefore = clearinghouse.balanceUsdc(account);
        vm.prank(EXECUTION_KEEPER);
        uint64 orderId = actions.retryPositionProtectionClose(id);
        protections[id].execution = 0;
        protections[id].attempt = orderId;
        protections[id].status = Protection.PositionProtectionStatus.Triggered;
        _newOrder(account, orderId, id, true);
        assertEq(clearinghouse.balanceUsdc(account), balanceBefore, "retry needs no new funding");
        _assertModel();
    }

    function _expireHead() internal {
        uint64 id = _head();
        ModelOrder storage o = orders[id];
        if (block.timestamp <= o.deadline) {
            vm.warp(uint256(o.deadline) + 1);
        }
        uint256 balanceBefore = clearinghouse.balanceUsdc(o.account);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(id, new bytes[](0));
        ModelProtection storage p = protections[o.protectionId];
        if (o.close) {
            p.execution = CLOSE_BOUNTY;
            p.status = Protection.PositionProtectionStatus.Latched;
            assertEq(clearinghouse.balanceUsdc(o.account), balanceBefore, "expiry must retain the retry bounty");
        } else {
            _payOrder(o);
            if (p.status == Protection.PositionProtectionStatus.PendingOpen) {
                _refundProtection(p);
            }
            assertEq(
                clearinghouse.balanceUsdc(o.account),
                balanceBefore - OPEN_BOUNTY,
                "only the ordinary expiry bounty is paid"
            );
        }
        _finishOrder(o);
        _assertModel();
    }

    function _executeHead() internal {
        uint64 id = _head();
        ModelOrder storage o = orders[id];
        if (block.timestamp + 1 > o.deadline) {
            _expireHead();
            return;
        }
        bytes[] memory data = _freshData(o.close ? STOP_PRICE : ENTRY_PRICE, o.commitTime);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(id, data);
        _payOrder(o);
        ModelProtection storage p = protections[o.protectionId];
        accounts[o.account].position = !o.close;
        if (o.close) {
            p.status = Protection.PositionProtectionStatus.Executed;
            accounts[o.account].protectionId = 0;
        } else if (p.status == Protection.PositionProtectionStatus.PendingOpen) {
            p.status = Protection.PositionProtectionStatus.Armed;
        }
        _finishOrder(o);
        _assertModel();
    }

    function _riskOff() internal {
        routerAdmin.pause();
        for (uint256 i; i < orderIds.length; ++i) {
            ModelOrder storage o = orders[orderIds[i]];
            if (!o.pending || o.close) {
                continue;
            }
            uint256 balanceBefore = clearinghouse.balanceUsdc(o.account);
            vm.prank(EXECUTION_KEEPER);
            router.clearRiskOffOrder(orderIds[i]);
            accounts[o.account].refunded += OPEN_BOUNTY;
            ModelProtection storage p = protections[o.protectionId];
            if (p.status == Protection.PositionProtectionStatus.PendingOpen) {
                _refundProtection(p);
            }
            _finishOrder(o);
            assertEq(clearinghouse.balanceUsdc(o.account), balanceBefore, "risk-off only releases classifications");
            _assertModel();
        }
        routerAdmin.unpause();
        _assertModel();
    }

    function _liquidate(
        address account
    ) internal {
        router.updateMarkPrice(_freshData(ENTRY_PRICE, 0));
        uint256 free = _freeSettlementUsdc(account);
        vm.prank(account);
        clearinghouse.withdraw(account, free);
        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint64 protectionId = accounts[account].protectionId;
        ModelProtection storage p = protections[protectionId];
        uint64 orderId = accounts[account].orderId;
        uint256 expectedForfeiture = p.trigger + p.execution + orders[orderId].bounty;
        bytes[] memory data = _freshData(150_000_000, 0);
        vm.prank(LIQUIDATOR);
        router.executeLiquidation(account, data);
        accounts[account].forfeited += expectedForfeiture;
        accounts[account].position = false;
        accounts[account].protectionId = 0;
        p.trigger = 0;
        p.execution = 0;
        p.status = Protection.PositionProtectionStatus.Liquidated;
        if (orderId != 0) {
            _finishOrder(orders[orderId]);
        }
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - treasuryBefore,
            expectedForfeiture,
            "liquidation forfeits each unpaid bounty once"
        );
        _assertModel();
    }

    function _newProtection(
        address account,
        uint64 id,
        uint64 parent,
        Protection.PositionProtectionStatus status
    ) internal {
        assertEq(protections[id].account, address(0), "protection id reuse");
        protections[id] = ModelProtection(account, parent, 0, status, TRIGGER_BOUNTY, CLOSE_BOUNTY);
        protectionIds.push(id);
        accounts[account].protectionId = id;
        accounts[account].funded += TRIGGER_BOUNTY + CLOSE_BOUNTY;
    }

    function _newOrder(
        address account,
        uint64 id,
        uint64 protectionId,
        bool close
    ) internal {
        assertEq(orders[id].account, address(0), "attempt/order id reuse");
        orders[id] = ModelOrder(
            account,
            protectionId,
            uint64(block.timestamp),
            uint64(block.timestamp + router.maxOrderAge()),
            close,
            true,
            close ? CLOSE_BOUNTY : OPEN_BOUNTY
        );
        orderIds.push(id);
        accounts[account].orderId = id;
    }

    function _payOrder(
        ModelOrder storage o
    ) internal {
        accounts[o.account].paid += o.bounty;
        executionPaid += o.bounty;
    }

    function _finishOrder(
        ModelOrder storage o
    ) internal {
        o.bounty = 0;
        o.pending = false;
        accounts[o.account].orderId = 0;
    }

    function _refundProtection(
        ModelProtection storage p
    ) internal {
        accounts[p.account].refunded += p.trigger + p.execution;
        accounts[p.account].protectionId = 0;
        p.trigger = 0;
        p.execution = 0;
        p.status = Protection.PositionProtectionStatus.Failed;
    }

    function _head() internal view returns (uint64) {
        for (uint256 i; i < orderIds.length; ++i) {
            if (orders[orderIds[i]].pending) {
                return orderIds[i];
            }
        }
        revert("model requires a pending order");
    }

    function _assertModel() internal view {
        uint256[3] memory unpaid;
        for (uint256 i; i < protectionIds.length; ++i) {
            uint64 id = protectionIds[i];
            ModelProtection storage p = protections[id];
            _assertReservation(IMarginClearinghouse.BountyKind.ProtectionTrigger, id, p.account, p.trigger);
            _assertReservation(IMarginClearinghouse.BountyKind.ProtectionExecution, id, p.account, p.execution);
            Protection.PositionProtectionView memory actual = views.getPositionProtection(id);
            assertEq(uint8(actual.status), uint8(p.status), "protection lifecycle");
            assertEq(actual.parentOrderId, p.parent, "parent linkage");
            assertEq(actual.linkedOrderId, p.attempt, "latest attempt linkage");
            assertEq(actual.triggerBountyUsdc, p.trigger, "public trigger balance");
            assertEq(actual.executionBountyUsdc, p.execution, "public execution balance");
            unpaid[_actorIndex(p.account)] += p.trigger + p.execution;
        }
        for (uint256 i; i < orderIds.length; ++i) {
            uint64 id = orderIds[i];
            ModelOrder storage o = orders[id];
            _assertReservation(IMarginClearinghouse.BountyKind.Order, id, o.account, o.bounty);
            unpaid[_actorIndex(o.account)] += o.bounty;
            (uint256 publicBounty, uint256 margin) = _pendingAmounts(id);
            assertEq(publicBounty, o.bounty, "public order bounty");
            assertEq(margin, o.pending && !o.close ? MARGIN : 0, "parent margin classification");
        }
        for (uint256 i; i < actors.length; ++i) {
            address account = actors[i];
            ModelAccount storage a = accounts[account];
            assertEq(a.funded, unpaid[i] + a.paid + a.refunded + a.forfeited, "independent bounty conservation");
            assertEq(clearinghouse.totalBountyReservationsUsdc(account), unpaid[i], "canonical total");
            assertEq(clearinghouse.actionReserveUsdc(account), unpaid[i], "reserve backing with zero VPI");
            assertEq(router.getAccountReservations(account).executionBountyUsdc, unpaid[i], "Router aggregate");
            assertEq(views.activePositionProtectionId(account), a.protectionId, "active protection");
            assertEq(router.pendingOrderCounts(account), a.orderId == 0 ? 0 : 1, "live attempt/parent count");
            (uint256 size,,,,,,) = engine.positions(account);
            assertEq(size, a.position ? SIZE : 0, "position lifecycle");
        }
        assertEq(clearinghouse.balanceUsdc(TRIGGER_KEEPER), triggerPaid, "trigger paid once");
        assertEq(clearinghouse.balanceUsdc(EXECUTION_KEEPER), executionPaid, "execution paid once");
    }

    function _assertReservation(
        IMarginClearinghouse.BountyKind kind,
        uint64 id,
        address account,
        uint256 amount
    ) internal view {
        IMarginClearinghouse.BountyReservation memory actual = clearinghouse.getBountyReservation(kind, id);
        assertEq(actual.account, account, "namespace account attribution");
        assertEq(actual.amountUsdc, amount, "namespace amount including terminal records");
    }

    function _pendingAmounts(
        uint64 id
    ) internal view returns (uint256 bounty, uint256 margin) {
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(id);
        return (pending.executionBountyUsdc, pending.committedMarginUsdc);
    }

    function _actorIndex(
        address account
    ) internal view returns (uint256) {
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i] == account) {
                return i;
            }
        }
        revert("unknown model account");
    }

    function _freshData(
        uint256 price,
        uint64 previousPublishTime
    ) internal returns (bytes[] memory data) {
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), int64(uint64(price)), 0, -8, uint64(block.timestamp), previousPublishTime
        );
        data = new bytes[](1);
        data[0] = abi.encode(price);
    }

    function _params() internal pure returns (Protection.PositionProtectionParams memory) {
        return Protection.PositionProtectionParams(0, STOP_PRICE);
    }

    function _request() internal view returns (OrderV2Types.OrderRequest memory request) {
        request.clientOrderId = bytes32(uint256(orderIds.length + 1));
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = SIZE;
        request.marginDelta = MARGIN;
        request.targetPrice = 1;
        request.bounds.validUntil = uint64(block.timestamp + router.maxOrderAge());
        request.bounds.allowedExecutionModes = 7;
        request.bounds.expectedConfigHash = router.lifecycleBook().currentExecutionConfigHash();
        request.bounds.maxExecutionBountyUsdc = type(uint256).max;
        request.bounds.maxExecutionNotionalUsdc = type(uint256).max;
        request.bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        request.bounds.maxActionChargeUsdc = type(uint256).max;
        request.bounds.maxExplicitFeesUsdc = type(uint256).max;
        request.bounds.maxPostPositionSize = type(uint256).max;
        request.bounds.maxPostLeverageBps = type(uint32).max;
    }

}
