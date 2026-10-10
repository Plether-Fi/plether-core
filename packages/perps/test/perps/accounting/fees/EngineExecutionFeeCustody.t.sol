// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

contract PhantomExecFeeTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: phantom exec fee
    function test_PhantomExecFee_DoesNotOverCreditTreasuryMargin() public {
        uint256 lpDeposit = 1_000_000e6;
        _fundJunior(bob, lpDeposit);

        uint256 margin = 1002e6;
        usdc.mint(alice, margin);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), margin);
        address account = alice;
        clearinghouse.deposit(account, margin);

        uint256 size = 50_000e18;
        router.commitOrder(CfdTypes.Side.LONG, size, 1000e6, 1e8, false);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        bytes[] memory priceData = _mockPythUpdateData(1e8);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        uint256 openFee = clearinghouse.balanceUsdc(engine.protocolTreasury());

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, size, 0, 0, true);

        assertEq(router.nextCommitId(), 3, "Close intents should reserve a flat keeper bounty from free settlement");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            openFee,
            "Committing the close should not accrue additional protocol fees"
        );
    }

}
