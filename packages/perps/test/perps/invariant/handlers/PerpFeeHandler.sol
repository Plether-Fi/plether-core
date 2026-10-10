// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Independent execution-fee ledger for funded live-market opens and full closes.
/// @dev Scope: zero VPI/carry, no frozen spread, ample pool liquidity, and losses smaller than posted margin.
///      Consequently all assessed fees are cash-eligible. Gains withhold fees from the payout; flat/loss closes
///      collect them from cash. This is not a model of fee waivers, claim priority, or liquidation charges.
///      Expected fees use only submitted size/price and the configured rate, never a production preview or delta.
contract PerpFeeHandler is Test {

    uint256 public constant POSITION_SIZE = 50_000e18;
    uint256 public constant ENTRY_PRICE = 1e8;

    MockUSDC public immutable usdc;
    MockPyth public immutable mockPyth;
    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    LegacyOrderRouterHarness public immutable router;
    uint256 public immutable feeBps;
    uint256 public immutable initialTreasuryWalletUsdc;

    address[2] internal actors;
    mapping(address => bool) public ghostHasPosition;

    uint256 public ghostTrackedFeesUsdc;
    uint256 public ghostAccruedFeesUsdc;
    uint256 public ghostWithdrawnFeesUsdc;
    uint256 public attempts;
    uint256 public skippedActions;
    uint256 public successfulOpens;
    uint256 public successfulCloses;
    uint256 public successfulWithdrawals;
    uint256 public expectedRejections;
    uint256 public unexpectedFailures;
    bytes4 public lastUnexpectedSelector;
    OrderV3Types.PendingReason public lastPendingReason;
    OrderV3Types.TerminalReason public lastTerminalReason;

    constructor(
        MockUSDC _usdc,
        MockPyth _mockPyth,
        CfdEngine _engine,
        MarginClearinghouse _clearinghouse,
        LegacyOrderRouterHarness _router
    ) {
        usdc = _usdc;
        mockPyth = _mockPyth;
        engine = _engine;
        clearinghouse = _clearinghouse;
        router = _router;
        feeBps = _engine.executionFeeBps();
        initialTreasuryWalletUsdc = _usdc.balanceOf(_engine.protocolTreasury());
        actors[0] = address(0x8101);
        actors[1] = address(0x8102);
    }

    function actorAt(
        uint256 index
    ) external view returns (address) {
        return actors[index];
    }

    function actorCount() external pure returns (uint256) {
        return 2;
    }

    function seedActors() external {
        for (uint256 i; i < actors.length; ++i) {
            require(_fundActor(actors[i]), "Fee model actor seed failed");
        }
    }

    function openPosition(
        uint256 actorIndex,
        uint256 marginFuzz
    ) external {
        ++attempts;
        address actor = actors[actorIndex % actors.length];
        if (ghostHasPosition[actor]) {
            ++skippedActions;
            return;
        }

        // A fixed deposit per new position keeps fee collection funded over arbitrarily long campaigns.
        if (!_fundActor(actor)) {
            return;
        }
        uint256 margin = bound(marginFuzz, 2000e6, 10_000e6);
        vm.prank(actor);
        try router.commitOrder(CfdTypes.Side.LONG, POSITION_SIZE, margin, 0, false) returns (uint64 orderId) {
            if (_execute(orderId, ENTRY_PRICE)) {
                ghostHasPosition[actor] = true;
                _accrueExpectedFee(ENTRY_PRICE);
                ++successfulOpens;
            }
        } catch (bytes memory reason) {
            _recordUnexpectedFailure(reason);
        }
    }

    function closePosition(
        uint256 actorIndex,
        uint256 priceFuzz
    ) external {
        ++attempts;
        address actor = actors[actorIndex % actors.length];
        if (!ghostHasPosition[actor]) {
            ++skippedActions;
            return;
        }

        // At most $1000 price loss, below the minimum $2000 margin less opening fee and liquidation reserve.
        uint256 price = bound(priceFuzz, 0.98e8, 1.02e8);
        vm.prank(actor);
        try router.commitOrder(CfdTypes.Side.LONG, POSITION_SIZE, 0, 0, true) returns (uint64 orderId) {
            if (_execute(orderId, price)) {
                ghostHasPosition[actor] = false;
                _accrueExpectedFee(price);
                ++successfulCloses;
            }
        } catch (bytes memory reason) {
            _recordUnexpectedFailure(reason);
        }
    }

    function withdrawTreasuryFees() external {
        ++attempts;
        uint256 amount = ghostTrackedFeesUsdc;
        if (amount == 0) {
            ++skippedActions;
            return;
        }
        address treasury = engine.protocolTreasury();
        vm.prank(treasury);
        try clearinghouse.withdraw(treasury, amount) {
            ghostTrackedFeesUsdc = 0;
            ghostWithdrawnFeesUsdc += amount;
            ++successfulWithdrawals;
        } catch (bytes memory reason) {
            _recordUnexpectedFailure(reason);
        }
    }

    function rejectZeroSizeOrder(
        uint256 actorIndex
    ) external {
        ++attempts;
        vm.prank(actors[actorIndex % actors.length]);
        try router.commitOrder(CfdTypes.Side.LONG, 0, 2000e6, 0, false) returns (uint64) {
            ++unexpectedFailures;
        } catch (bytes memory reason) {
            if (reason.length == 4 && bytes4(reason) == IOrderRouterErrors.OrderRouter__ZeroSize.selector) {
                ++expectedRejections;
            } else {
                _recordUnexpectedFailure(reason);
            }
        }
    }

    /// @dev Size is 18 decimals, price 8, settlement 6; the second division floors the fee in USDC atoms.
    function expectedExecutionFee(
        uint256 size,
        uint256 price,
        uint256 rateBps
    ) public pure returns (uint256) {
        uint256 notionalUsdc = size * price / 1e20;
        return notionalUsdc * rateBps / 10_000;
    }

    function _accrueExpectedFee(
        uint256 price
    ) internal {
        uint256 expectedFee = expectedExecutionFee(POSITION_SIZE, price, feeBps);
        ghostTrackedFeesUsdc += expectedFee;
        ghostAccruedFeesUsdc += expectedFee;
    }

    function _execute(
        uint64 orderId,
        uint256 price
    ) internal returns (bool) {
        // The production Router requires a later block and a unique historical update after commit.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        mockPyth.setUniquePrice(bytes32(uint256(1)), int64(uint64(price)), 0, -8, block.timestamp, block.timestamp - 1);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(price);
        try router.executeOrder(orderId, data) returns (OrderV3Types.ExecutionResult memory result) {
            if (result.status == OrderV3Types.LifecycleStatus.Executed) {
                return true;
            }
            ++unexpectedFailures;
            lastPendingReason = result.pendingReason;
            lastTerminalReason = result.terminalReason;
        } catch (bytes memory reason) {
            _recordUnexpectedFailure(reason);
        }
        return false;
    }

    function _fundActor(
        address actor
    ) internal returns (bool funded) {
        usdc.mint(actor, 25_000e6);
        vm.startPrank(actor);
        usdc.approve(address(clearinghouse), type(uint256).max);
        try clearinghouse.deposit(actor, 25_000e6) {
            funded = true;
        } catch (bytes memory reason) {
            _recordUnexpectedFailure(reason);
        }
        vm.stopPrank();
    }

    function _recordUnexpectedFailure(
        bytes memory reason
    ) internal {
        ++unexpectedFailures;
        if (reason.length >= 4) {
            lastUnexpectedSelector = bytes4(reason);
        }
    }

}
