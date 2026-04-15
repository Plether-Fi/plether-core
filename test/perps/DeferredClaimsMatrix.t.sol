// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract DeferredClaimsMatrixTest is BasePerpTest {

    function test_TraderDeferredClaim_PartialWhenVaultIlliquid() public {
        address trader = address(0xDC01);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        usdc.burn(address(pool), pool.totalAssets() - 20e6);
        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

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

}
