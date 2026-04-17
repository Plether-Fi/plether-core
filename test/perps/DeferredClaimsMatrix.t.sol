// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract DeferredClaimsMatrixTest is BasePerpTest {

    using stdStorage for StdStorage;

    function test_TraderDeferredClaim_RevertsWhileAggregateDeferredClaimsExceedVaultCash() public {
        address trader = address(0xDC00);
        address otherKeeper = address(0xDC04);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 40e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(30e6));
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(30e6));

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(otherKeeper, 20e6);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(
            engine.deferredTraderCreditUsdc(accountId),
            30e6,
            "Trader deferred claim should remain fully queued during freeze"
        );
        assertEq(engine.deferredKeeperCreditUsdc(otherKeeper), 20e6, "Other deferred claims should remain preserved");
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

    function test_TraderDeferredClaim_RevertsWhenSingleClaimExceedsAvailableVaultCash() public {
        address trader = address(0xDC01);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 20e6);

        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(50e6));
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(50e6));

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(
            engine.deferredTraderCreditUsdc(accountId),
            50e6,
            "Claim should remain fully queued until the shortfall is cured"
        );
    }

    function test_TraderDeferredClaim_RevertsUntilKeeperQueueAndOwnClaimAreFullyCovered() public {
        address trader = address(0xDC02);
        address otherKeeper = address(0xDC05);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 45e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(30e6));
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(30e6));

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(otherKeeper, 20e6);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(engine.deferredTraderCreditUsdc(accountId), 30e6, "Trader deferred balance should stay fully queued");
        assertEq(engine.deferredKeeperCreditUsdc(otherKeeper), 20e6, "Keeper deferred queue should remain preserved");
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

    function test_ClearerDeferredClaim_RevertsWhenVaultCashFallsBelowKeeperLiability() public {
        address keeper = address(0xDC03);
        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 5000e6);
        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 2000e6);

        bytes32 keeperAccountId = bytes32(uint256(uint160(keeper)));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(clearinghouse.balanceUsdc(keeperAccountId), 0, "Frozen keeper credit should not settle any amount");
        assertEq(
            engine.deferredKeeperCreditUsdc(keeper), 5000e6, "Keeper credit should stay fully queued during freeze"
        );
    }

    function test_ClearerDeferredClaim_RevertsUntilTraderQueueAndKeeperCreditAreFullyCovered() public {
        address keeper = address(0xDC06);
        address trader = address(0xDC07);
        bytes32 traderAccountId = bytes32(uint256(uint160(trader)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(keeper)));

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 45e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(traderAccountId)
            .checked_write(uint256(20e6));
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(20e6));

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 30e6);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(clearinghouse.balanceUsdc(keeperAccountId), 0, "Frozen keeper credit should not settle any amount");
        assertEq(
            engine.deferredKeeperCreditUsdc(keeper), 30e6, "Keeper residual deferred balance should stay fully queued"
        );
        assertEq(
            engine.deferredTraderCreditUsdc(traderAccountId), 20e6, "Trader deferred queue should remain preserved"
        );
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

}
