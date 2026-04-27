// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract ClaimsMatrixTest is BasePerpTest {

    using stdStorage for StdStorage;

    function test_ClearinghouseClaimLedger_TracksSourceTaggedClaims() public {
        address account = address(0xDC99);

        _recordTraderClaimForTest(account, 30e6);
        _recordKeeperClaimForTest(account, 20e6);

        IMarginClearinghouse.ClaimBalances memory claims = clearinghouse.getClaimBalances(account);
        assertEq(claims.traderClaimBalanceUsdc, 30e6, "Trader claim source bucket should be tracked");
        assertEq(claims.keeperClaimBalanceUsdc, 20e6, "Keeper claim source bucket should be tracked");
        assertEq(claims.totalClaimBalanceUsdc, 50e6, "Account claim balance should aggregate source buckets");
        assertEq(clearinghouse.totalClaimBalanceUsdc(), 50e6, "Global claim balance should aggregate all claims");
        assertEq(
            clearinghouse.totalTraderClaimBalanceUsdc(), 30e6, "Engine trader view should delegate to clearinghouse"
        );
        assertEq(
            clearinghouse.totalKeeperClaimBalanceUsdc(), 20e6, "Engine keeper view should delegate to clearinghouse"
        );
    }

    function test_TraderClaim_RevertsWhileAggregateClaimsExceedVaultCash() public {
        address trader = address(0xDC00);
        address otherKeeper = address(0xDC04);
        address account = trader;

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 40e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        _recordTraderClaimForTest(account, 30e6);
        _recordKeeperClaimForTest(otherKeeper, 20e6);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(trader);
        engine.claimBalance(IMarginClearinghouse.ClaimKind.Trader, account);

        assertEq(
            clearinghouse.traderClaimBalanceUsdc(account),
            30e6,
            "Trader claim balance should remain fully queued during freeze"
        );
        assertEq(
            clearinghouse.keeperClaimBalanceUsdc(otherKeeper), 20e6, "Other claim balances should remain preserved"
        );
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

    function test_TraderClaim_RevertsWhenSingleClaimExceedsAvailableVaultCash() public {
        address trader = address(0xDC01);
        address account = trader;
        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 20e6);

        _recordTraderClaimForTest(account, 50e6);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(trader);
        engine.claimBalance(IMarginClearinghouse.ClaimKind.Trader, account);

        assertEq(
            clearinghouse.traderClaimBalanceUsdc(account),
            50e6,
            "Claim should remain fully queued until the shortfall is cured"
        );
    }

    function test_TraderClaim_RevertsUntilKeeperQueueAndOwnClaimAreFullyCovered() public {
        address trader = address(0xDC02);
        address otherKeeper = address(0xDC05);
        address account = trader;

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 45e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        _recordTraderClaimForTest(account, 30e6);
        _recordKeeperClaimForTest(otherKeeper, 20e6);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(trader);
        engine.claimBalance(IMarginClearinghouse.ClaimKind.Trader, account);

        assertEq(clearinghouse.traderClaimBalanceUsdc(account), 30e6, "Trader claim balance should stay fully queued");
        assertEq(
            clearinghouse.keeperClaimBalanceUsdc(otherKeeper), 20e6, "Keeper claim balances should remain preserved"
        );
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

    function test_KeeperClaim_RevertsWhenVaultCashFallsBelowKeeperLiability() public {
        address keeper = address(0xDC03);
        _recordKeeperClaimForTest(keeper, 5000e6);
        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 2000e6);

        address keeperAccount = keeper;
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(keeper);
        engine.claimBalance(IMarginClearinghouse.ClaimKind.Keeper, keeper);

        assertEq(clearinghouse.balanceUsdc(keeperAccount), 0, "Frozen keeper credit should not settle any amount");
        assertEq(
            clearinghouse.keeperClaimBalanceUsdc(keeper), 5000e6, "Keeper credit should stay fully queued during freeze"
        );
    }

    function test_KeeperClaim_RevertsUntilTraderQueueAndKeeperCreditAreFullyCovered() public {
        address keeper = address(0xDC06);
        address trader = address(0xDC07);
        address traderAccount = trader;
        address keeperAccount = keeper;

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 45e6);

        stdstore.target(address(engine)).sig("accumulatedFeesUsdc()").checked_write(uint256(20e6));
        _recordTraderClaimForTest(traderAccount, 20e6);
        _recordKeeperClaimForTest(keeper, 30e6);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(keeper);
        engine.claimBalance(IMarginClearinghouse.ClaimKind.Keeper, keeper);

        assertEq(clearinghouse.balanceUsdc(keeperAccount), 0, "Frozen keeper credit should not settle any amount");
        assertEq(
            clearinghouse.keeperClaimBalanceUsdc(keeper), 30e6, "Keeper residual claim balance should stay fully queued"
        );
        assertEq(
            clearinghouse.traderClaimBalanceUsdc(traderAccount), 20e6, "Trader claim balances should remain preserved"
        );
        assertEq(engine.accumulatedFeesUsdc(), 20e6, "Protocol fees should remain preserved");
    }

}
