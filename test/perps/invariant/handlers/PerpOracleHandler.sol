// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../../src/perps/OrderRouter.sol";
import {MockUSDC} from "../../../mocks/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract PerpOracleHandler is Test {

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    OrderRouter public immutable router;
    address public immutable owner;

    address[2] internal actors;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        MarginClearinghouse _clearinghouse,
        OrderRouter _router
    ) {
        usdc = _usdc;
        engine = _engine;
        clearinghouse = _clearinghouse;
        router = _router;
        owner = msg.sender;

        actors[0] = address(0x7101);
        actors[1] = address(0x7102);
    }

    function seedPositions() external {
        for (uint256 i = 0; i < actors.length; i++) {
            _ensureOpenPosition(actors[i]);
        }
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
    }

    function actorAt(
        uint256 index
    ) external view returns (address) {
        return actors[index];
    }

    function actorCount() external pure returns (uint256) {
        return 2;
    }

    function warpToOracleBoundary(
        uint256 modeFuzz
    ) external {
        uint256 mode = modeFuzz % 7;
        uint256 target;
        if (mode == 0) {
            target = 1_709_607_599; // Fri 20:59:59 UTC
        } else if (mode == 1) {
            target = 1_709_611_199; // Fri 21:59:59 UTC
        } else if (mode == 2) {
            target = 1_709_611_200; // Fri 22:00:00 UTC
        } else if (mode == 3) {
            target = 1_709_697_599; // Sat 21:59:59 UTC
        } else if (mode == 4) {
            target = 1_709_694_000; // Sun 21:00:00 UTC
        } else if (mode == 5) {
            target = 1_709_697_599; // Sun 21:59:59 UTC
        } else {
            target = 1_709_701_200; // Sun 23:00:00 UTC
        }
        vm.warp(target);
    }

    function warpForward(
        uint256 secondsFuzz
    ) external {
        vm.warp(block.timestamp + bound(secondsFuzz, 1, 10 days));
    }

    function syncMarkNow(
        uint256 priceFuzz
    ) external {
        uint256 price = bound(priceFuzz, 0.5e8, 1.5e8);
        vm.prank(address(router));
        engine.updateMarkPrice(price, uint64(block.timestamp));
    }

    function configureFadDayTomorrow(
        uint256 runwayFuzz
    ) external {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = ((block.timestamp / 86_400) + 1) * 86_400;

        vm.startPrank(owner);
        engine.proposeAddFadDays(timestamps);
        vm.warp(block.timestamp + 7 days);
        engine.finalizeAddFadDays();
        engine.proposeFadRunway(bound(runwayFuzz, 0, 24 hours));
        vm.warp(block.timestamp + 7 days);
        engine.finalizeFadRunway();
        vm.stopPrank();
    }

    function configureFadMaxStaleness(
        uint256 secondsFuzz
    ) external {
        uint256 seconds_ = bound(secondsFuzz, 1 hours, 7 days);
        vm.startPrank(owner);
        engine.proposeFadMaxStaleness(seconds_);
        vm.warp(block.timestamp + 7 days);
        engine.finalizeFadMaxStaleness();
        vm.stopPrank();
    }

    function ensureActorPosition(
        uint256 actorIndex
    ) external {
        _ensureOpenPosition(actors[actorIndex % actors.length]);
    }

    function _ensureOpenPosition(
        address actor
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(actor)));
        (uint256 size,,,,,,) = engine.positions(accountId);
        if (size > 0) {
            return;
        }

        usdc.mint(actor, 25_000e6);
        uint64 orderId = router.nextCommitId();
        vm.startPrank(actor);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(accountId, 25_000e6);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0, false);
        vm.stopPrank();

        bytes[] memory empty;
        router.executeOrder(orderId, empty);
    }

}
