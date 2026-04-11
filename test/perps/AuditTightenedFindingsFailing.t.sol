// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditTightenedFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xBEEF);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function test_H1_WithdrawScenarioNowBlocksOnOpenPosition() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 10_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 5000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_800_000, uint64(block.timestamp));

        vm.prank(alice);
        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(accountId, 5000 * 1e6);
    }

    function test_H2_LowGasKeeperCallMustNotConsumeValidOrder() public {
        _fundTrader(alice, 50_000 * 1e6);
        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        vm.prank(keeper);
        address(router).call{gas: 520_000}(abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData));

        assertEq(router.nextExecuteId(), 1, "Low-gas keeper call must not consume a valid order");
    }

    function test_M1_FullCloseMustZeroFundedSideMargin() public {
        address bullTrader = address(0x1111);
        address bearTrader = address(0x2222);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTrader, 100_000 * 1e6);
        _fundTrader(bearTrader, 600_000 * 1e6);

        _open(bearId, CfdTypes.Side.BEAR, 1_000_000 * 1e18, 100_000 * 1e6, 1e8);
        _open(bullId, CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        vm.warp(block.timestamp + 365 days);
        _close(bullId, CfdTypes.Side.BULL, 100_000 * 1e18, 1e8);

        assertEq(
            _sideTotalMargin(CfdTypes.Side.BULL), 0, "Full close should remove all bull margin, including legacy-spread gains in the obsolete model"
        );
    }

    function test_M2_NewDepositResetsCooldownTimestamp() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.warp(block.timestamp + 2 hours);
        uint256 redepositTime = block.timestamp;

        _fundJunior(alice, 100_000 * 1e6);

        assertEq(juniorVault.lastDepositTime(alice), redepositTime, "New deposit should reset cooldown timestamp");
    }

    function test_L1_StaleIntervalsMustNotAccrueSeniorYield() public {
        _fundSenior(alice, 200_000 * 1e6);
        _fundJunior(bob, 200_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(address(0x3333))));
        _fundTrader(address(0x3333), 50_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        uint256 seniorBefore = pool.seniorPrincipal();

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), seniorBefore, "Stale-mark downtime should not later mint senior yield");
    }

}
