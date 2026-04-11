// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../../src/perps/OrderRouter.sol";
import {MockUSDC} from "../../../mocks/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract PerpFeeHandler is Test {

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    OrderRouter public immutable router;
    address public immutable owner;

    address[2] internal actors;

    uint256 public ghostTrackedFeesUsdc;
    uint256 public ghostAccruedFeesUsdc;
    uint256 public ghostWithdrawnFeesUsdc;

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
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 50_000e6);
            vm.startPrank(actors[i]);
            usdc.approve(address(clearinghouse), type(uint256).max);
            clearinghouse.deposit(_accountId(actors[i]), 50_000e6);
            vm.stopPrank();
        }
    }

    function openPosition(
        uint256 actorIndex,
        uint256 marginFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        bytes32 accountId = _accountId(actor);
        (uint256 size,,,,,,) = engine.positions(accountId);
        if (size > 0) {
            return;
        }

        uint256 beforeFees = engine.accumulatedFeesUsdc();
        uint256 margin = bound(marginFuzz, 2000e6, 10_000e6);
        vm.prank(actor);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, margin, 0, false);
        bytes[] memory empty;
        router.executeOrderBatch(1, empty);
        _syncFeeDelta(beforeFees, engine.accumulatedFeesUsdc());
    }

    function closePosition(
        uint256 actorIndex,
        uint256 priceFuzz
    ) external {
        address actor = actors[actorIndex % actors.length];
        bytes32 accountId = _accountId(actor);
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        uint256 beforeFees = engine.accumulatedFeesUsdc();
        uint256 price = bound(priceFuzz, 0.6e8, 1.2e8);
        vm.prank(actor);
        router.commitOrder(side, size, 0, price, true);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(price);
        router.executeOrderBatch(1, priceData);
        _syncFeeDelta(beforeFees, engine.accumulatedFeesUsdc());
    }

    function withdrawFees() external {
        uint256 beforeFees = engine.accumulatedFeesUsdc();
        if (beforeFees == 0) {
            return;
        }
        uint256 beforeBalance = usdc.balanceOf(address(this));
        vm.prank(owner);
        engine.withdrawFees(address(this));
        ghostTrackedFeesUsdc -= beforeFees;
        ghostWithdrawnFeesUsdc += beforeFees;
        assertEq(
            usdc.balanceOf(address(this)) - beforeBalance, beforeFees, "Fee withdrawal must transfer full tracked fees"
        );
    }

    function _syncFeeDelta(
        uint256 beforeFees,
        uint256 afterFees
    ) internal {
        if (afterFees > beforeFees) {
            uint256 delta = afterFees - beforeFees;
            ghostTrackedFeesUsdc += delta;
            ghostAccruedFeesUsdc += delta;
        } else if (beforeFees > afterFees) {
            ghostTrackedFeesUsdc -= beforeFees - afterFees;
        }
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

}
