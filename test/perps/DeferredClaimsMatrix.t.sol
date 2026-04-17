// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract DeferredClaimsMatrixTest is BasePerpTest {

    using stdStorage for StdStorage;

    function test_TraderDeferredClaim_PartialAheadOfFeesUnderShortfall() public {
        address trader = address(0xDC00);
        address otherKeeper = address(0xDC04);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 40e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId).checked_write(
            uint256(30e6)
        );
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(30e6));

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(otherKeeper, 20e6);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + 20e6,
            "Trader claim should consume shortfall cash ahead of protocol fees once other deferred claims are reserved"
        );
        assertEq(engine.deferredTraderCreditUsdc(accountId), 10e6, "Only the unpaid trader remainder should stay queued");
        assertEq(engine.deferredKeeperCreditUsdc(otherKeeper), 20e6, "Other deferred claims should remain preserved");
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

    function test_TraderDeferredClaim_PartialWhenVaultIlliquid() public {
        address trader = address(0xDC01);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 20e6);

        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId).checked_write(
            uint256(50e6)
        );
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(50e6));

        uint256 deferredBefore = engine.deferredTraderCreditUsdc(accountId);
        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);

        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + 20e6,
            "Claim should service only currently liquid amount"
        );
        assertEq(
            engine.deferredTraderCreditUsdc(accountId),
            deferredBefore - 20e6,
            "Remaining deferred balance should stay queued"
        );
    }

    function test_TraderDeferredClaim_PartialAfterPreservingKeeperQueue() public {
        address trader = address(0xDC02);
        address otherKeeper = address(0xDC05);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 45e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId).checked_write(
            uint256(30e6)
        );
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(30e6));

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(otherKeeper, 20e6);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);

        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + 25e6,
            "Trader claim should use all residual cash after preserving keeper deferred claims"
        );
        assertEq(engine.deferredTraderCreditUsdc(accountId), 5e6, "Trader residual deferred balance should stay queued");
        assertEq(engine.deferredKeeperCreditUsdc(otherKeeper), 20e6, "Keeper deferred queue should remain preserved");
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

    function test_ClearerDeferredClaim_PartialWhenVaultIlliquid() public {
        address keeper = address(0xDC03);
        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 5000e6);
        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 2000e6);

        bytes32 keeperAccountId = bytes32(uint256(uint160(keeper)));
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId),
            keeperSettlementBefore + 2000e6,
            "Clearer claim should service only liquid amount"
        );
        assertEq(engine.deferredKeeperCreditUsdc(keeper), 3000e6, "Remaining deferred keeper credit should stay queued");
    }

    function test_ClearerDeferredClaim_PartialAfterPreservingTraderQueue() public {
        address keeper = address(0xDC06);
        address trader = address(0xDC07);
        bytes32 traderAccountId = bytes32(uint256(uint160(trader)));
        bytes32 keeperAccountId = bytes32(uint256(uint160(keeper)));

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 45e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(traderAccountId).checked_write(
            uint256(20e6)
        );
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(20e6));

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 30e6);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccountId);

        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId),
            keeperSettlementBefore + 25e6,
            "Keeper claim should use all residual cash after preserving trader deferred claims"
        );
        assertEq(engine.deferredKeeperCreditUsdc(keeper), 5e6, "Keeper residual deferred balance should stay queued");
        assertEq(engine.deferredTraderCreditUsdc(traderAccountId), 20e6, "Trader deferred queue should remain preserved");
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

}
