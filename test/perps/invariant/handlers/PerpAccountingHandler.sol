// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../../src/perps/OrderRouter.sol";
import {IMarginClearinghouse} from "../../../../src/perps/interfaces/IMarginClearinghouse.sol";
import {MockUSDC} from "../../../mocks/MockUSDC.sol";
import {PerpGhostLedger} from "../ghost/PerpGhostLedger.sol";
import {MockInvariantVault} from "../mocks/MockInvariantVault.sol";
import {Test} from "forge-std/Test.sol";

contract PerpAccountingHandler is Test {

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    OrderRouter public immutable router;
    MockInvariantVault public immutable vault;
    PerpGhostLedger public immutable ghost;

    address[4] internal actors;

    uint256 public ghostTotalTraderMinted;
    uint256 public ghostTotalVaultMinted;
    uint256 public ghostSuccessfulLiquidations;

    mapping(uint64 => bytes32) internal ghostOrderOwner;
    mapping(uint64 => uint256) internal ghostOrderCommittedMargin;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        MarginClearinghouse _clearinghouse,
        OrderRouter _router,
        MockInvariantVault _vault
    ) {
        usdc = _usdc;
        engine = _engine;
        clearinghouse = _clearinghouse;
        router = _router;
        vault = _vault;

        actors[0] = address(0x5101);
        actors[1] = address(0x5102);
        actors[2] = address(0x5103);
        actors[3] = address(0x5104);

        ghost = new PerpGhostLedger(address(this));
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }

    function seedActors(
        uint256 traderDepositUsdc,
        uint256 vaultSeedUsdc
    ) external {
        for (uint256 i = 0; i < actors.length; i++) {
            _mintAndDepositTrader(actors[i], traderDepositUsdc);
        }

        vault.seedAssets(vaultSeedUsdc);
        ghostTotalVaultMinted += vaultSeedUsdc;
    }

    function depositCollateral(
        uint256 actorIndex,
        uint256 amountFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        uint256 amount = bound(amountFuzz, 1e6, 250_000e6);
        _mintAndDepositTrader(actor, amount);
    }

    function withdrawCollateral(
        uint256 actorIndex,
        uint256 amountFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        bytes32 accountId = _accountId(actor);
        uint256 freeSettlement = _freeSettlementUsdc(accountId);
        if (freeSettlement == 0) {
            return;
        }

        uint256 amount = bound(amountFuzz, 1e6, freeSettlement);
        vm.prank(actor);
        clearinghouse.withdraw(accountId, amount);
    }

    function commitOpenOrder(
        uint256 actorIndex,
        uint8 sideRaw,
        uint256 sizeFuzz,
        uint256 marginDeltaFuzz,
        uint256 targetPriceFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        uint256 targetPrice = bound(targetPriceFuzz, 0.5e8, 1.5e8);
        uint256 sizeDelta = bound(sizeFuzz, 1_000e18, 100_000e18);
        uint256 marginDelta = bound(marginDeltaFuzz, 0, 50_000e6);
        uint256 neededUsdc = marginDelta + 2e6;
        _ensureFreeSettlement(actor, neededUsdc);

        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;
        uint64 orderId = router.nextCommitId();

        vm.prank(actor);
        try router.commitOrder(side, sizeDelta, marginDelta, targetPrice, false) {
            _registerCommittedOrder(orderId, _accountId(actor), marginDelta);
        } catch {}
    }

    function commitCloseOrder(
        uint256 actorIndex,
        uint256 targetPriceFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        bytes32 accountId = _accountId(actor);
        (uint256 size,,,,, CfdTypes.Side side,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        uint256 targetPrice = bound(targetPriceFuzz, 0.5e8, 1.5e8);

        vm.prank(actor);
        try router.commitOrder(side, size, 0, targetPrice, true) {} catch {}
    }

    function cancelCloseOrder(
        uint256 actorIndex
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        uint64 orderId = _firstPendingCloseOrderId(_accountId(actor));
        if (orderId == 0) {
            return;
        }

        vm.prank(actor);
        try router.cancelOrder(orderId) {
            _forgetOrder(orderId);
        } catch {}
    }

    function executeNextOrderBatch(
        uint256 batchSizeFuzz
    ) external {
        uint64 nextExecuteId = router.nextExecuteId();
        if (nextExecuteId >= router.nextCommitId()) {
            return;
        }

        uint64 batchSize = uint64(bound(batchSizeFuzz, 1, 4));
        bytes[] memory empty;
        uint64 startExecuteId = nextExecuteId;
        try router.executeOrderBatch(batchSize, empty) {
            _clearProcessedOrders(startExecuteId, router.nextExecuteId());
        } catch {}
    }

    function liquidate(
        uint256 actorIndex,
        uint256 priceFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        bytes32 accountId = _accountId(actor);
        (uint256 size,,,,,,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        uint256 price = bound(priceFuzz, 0.3e8, 1.8e8);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(price);
        uint256 keeperBountyUsdc = engine.previewLiquidation(accountId, price, vaultAssetDepth()).keeperBountyUsdc;
        bool shouldDefer = vault.failRouterPayouts() && keeperBountyUsdc > 0;

        try router.executeLiquidation(accountId, priceData) {
            ghost.recordLiquidation(accountId, usdc.balanceOf(actor), engine.accumulatedBadDebtUsdc());
            ghostSuccessfulLiquidations++;
            _forgetAllOrdersForAccount(accountId);
            if (shouldDefer) {
                ghost.increaseDeferredClearerBounty(address(this), keeperBountyUsdc);
            }
        } catch {}
    }

    function claimDeferredClearerBounty() external {
        uint256 ghostDeferredBounty = ghost.deferredClearerBountySnapshot(address(this));
        try engine.claimDeferredClearerBounty() {
            if (ghostDeferredBounty > 0) {
                ghost.decreaseDeferredClearerBounty(address(this), ghostDeferredBounty);
            }
        } catch {}
    }

    function createDeferredTraderPayout(
        uint256 actorIndex
    ) external {
        address actor = actors[actorIndex % actors.length];
        if (_isLiquidated(actor)) {
            return;
        }

        bytes32 accountId = _accountId(actor);
        if (router.pendingOrderCounts(accountId) != 0) {
            return;
        }

        (uint256 size,,,,, CfdTypes.Side side,,) = engine.positions(accountId);
        if (size == 0) {
            _ensureFreeSettlement(actor, 25_000e6);
            uint64 openOrderId = router.nextCommitId();
            vm.prank(actor);
            try router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 20_000e6, 0, false) {
                _registerCommittedOrder(openOrderId, accountId, 20_000e6);
            } catch {
                return;
            }

            bytes[] memory openPriceData = new bytes[](1);
            openPriceData[0] = abi.encode(uint256(1e8));
            uint64 startExecuteId = router.nextExecuteId();
            try router.executeOrderBatch(openOrderId, openPriceData) {
                _clearProcessedOrders(startExecuteId, router.nextExecuteId());
            } catch {
                return;
            }

            (size,,,,, side,,) = engine.positions(accountId);
            if (size == 0) {
                return;
            }
        }

        vault.setAssets(0);

        uint64 closeOrderId = router.nextCommitId();
        vm.prank(actor);
        try router.commitOrder(side, size, 0, 0, true) {} catch {
            return;
        }

        bytes[] memory closePriceData = new bytes[](1);
        closePriceData[0] = abi.encode(side == CfdTypes.Side.BULL ? uint256(15e7) : uint256(5e7));
        uint64 closeStartExecuteId = router.nextExecuteId();
        try router.executeOrderBatch(closeOrderId, closePriceData) {
            _clearProcessedOrders(closeStartExecuteId, router.nextExecuteId());
        } catch {}
    }

    function claimDeferredPayout(
        uint256 actorIndex
    ) external {
        address actor = actors[actorIndex % actors.length];
        bytes32 accountId = _accountId(actor);

        vm.prank(actor);
        try engine.claimDeferredPayout(accountId) {} catch {}
    }

    function fundVault(
        uint256 amountFuzz
    ) external {
        uint256 amount = bound(amountFuzz, 1_000e6, 250_000e6);
        vault.seedAssets(amount);
        ghostTotalVaultMinted += amount;
    }

    function setRouterPayoutFailureMode(
        uint256 modeFuzz
    ) external {
        vault.setFailRouterPayouts(modeFuzz % 2 == 1);
    }

    function setVaultAssets(
        uint256 amountFuzz
    ) external {
        vault.setAssets(bound(amountFuzz, 0, 1_000_000_000e6));
    }

    function accountRouterEscrow(
        bytes32 accountId
    ) public view returns (uint256 totalEscrowUsdc) {
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 queuedAccountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (queuedAccountId != accountId || sizeDelta == 0) {
                continue;
            }
            totalEscrowUsdc += router.executionBountyReserves(orderId);
        }
    }

    function accountLiveReserveCount(
        bytes32 accountId
    ) external view returns (uint256 count) {
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 queuedAccountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (queuedAccountId != accountId || sizeDelta == 0) {
                continue;
            }
            if (router.executionBountyReserves(orderId) > 0 || router.committedMargins(orderId) > 0) {
                count++;
            }
        }
    }

    function liquidationSnapshot(
        bytes32 accountId
    ) external view returns (PerpGhostLedger.LiquidationSnapshot memory) {
        return ghost.liquidationSnapshot(accountId);
    }

    function committedMarginSnapshot(
        bytes32 accountId
    ) external view returns (uint256) {
        return ghost.committedMarginSnapshot(accountId);
    }

    function totalCommittedMarginSnapshot() external view returns (uint256) {
        return ghost.totalCommittedMarginSnapshot();
    }

    function deferredClearerBountySnapshot() external view returns (uint256) {
        return ghost.deferredClearerBountySnapshot(address(this));
    }

    function totalDeferredClearerBountySnapshot() external view returns (uint256) {
        return ghost.totalDeferredClearerBountySnapshot();
    }

    function _ensureFreeSettlement(
        address actor,
        uint256 minFreeSettlementUsdc
    ) internal {
        bytes32 accountId = _accountId(actor);
        uint256 freeSettlement = _freeSettlementUsdc(accountId);
        if (freeSettlement >= minFreeSettlementUsdc) {
            return;
        }

        _mintAndDepositTrader(actor, minFreeSettlementUsdc - freeSettlement);
    }

    function _mintAndDepositTrader(
        address actor,
        uint256 amount
    ) internal {
        bytes32 accountId = _accountId(actor);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();

        ghostTotalTraderMinted += amount;
    }

    function _registerCommittedOrder(
        uint64 orderId,
        bytes32 accountId,
        uint256 committedMarginUsdc
    ) internal {
        if (committedMarginUsdc == 0) {
            return;
        }

        ghostOrderOwner[orderId] = accountId;
        ghostOrderCommittedMargin[orderId] = committedMarginUsdc;
        ghost.increaseCommittedMargin(accountId, committedMarginUsdc);
    }

    function _clearProcessedOrders(
        uint64 startExecuteId,
        uint64 endExecuteId
    ) internal {
        if (endExecuteId <= startExecuteId) {
            return;
        }

        for (uint64 orderId = startExecuteId; orderId < endExecuteId; orderId++) {
            _forgetOrder(orderId);
        }
    }

    function _forgetAllOrdersForAccount(
        bytes32 accountId
    ) internal {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            if (ghostOrderOwner[orderId] != accountId) {
                continue;
            }
            _forgetOrder(orderId);
        }
    }

    function _forgetOrder(
        uint64 orderId
    ) internal {
        bytes32 accountId = ghostOrderOwner[orderId];
        uint256 committedMarginUsdc = ghostOrderCommittedMargin[orderId];
        if (accountId == bytes32(0) && committedMarginUsdc == 0) {
            return;
        }

        if (committedMarginUsdc > 0) {
            ghost.decreaseCommittedMargin(accountId, committedMarginUsdc);
        }

        delete ghostOrderOwner[orderId];
        delete ghostOrderCommittedMargin[orderId];
    }

    function vaultAssetDepth() public view returns (uint256) {
        return vault.totalAssets();
    }

    function _freeSettlementUsdc(
        bytes32 accountId
    ) internal view returns (uint256) {
        (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
        uint256 protectedMargin = size > 0 ? margin : 0;
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            clearinghouse.getAccountUsdcBuckets(accountId, protectedMargin);
        return buckets.freeSettlementUsdc;
    }

    function _firstPendingCloseOrderId(
        bytes32 accountId
    ) internal view returns (uint64 orderId) {
        for (orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 queuedAccountId, uint256 sizeDelta,,,,,,, bool isClose) = router.orders(orderId);
            if (queuedAccountId == accountId && sizeDelta > 0 && isClose) {
                return orderId;
            }
        }
        return 0;
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

    function _isLiquidated(
        address actor
    ) internal view returns (bool) {
        return ghost.liquidationSnapshot(_accountId(actor)).liquidated;
    }
}
