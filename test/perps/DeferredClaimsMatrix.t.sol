// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract DeferredClaimsMatrixTest is BasePerpTest {

    using stdStorage for StdStorage;

    function test_TraderDeferredClaim_RevertsWhenSingleClaimExceedsAvailablePoolCash() public {
        address trader = address(0xDC01);
        address account = trader;
        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 20e6);

        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(address)").with_key(account)
            .checked_write(uint256(50e6));
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(50e6));

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientPoolLiquidity.selector);
        vm.prank(trader);
        engine.claimDeferredTraderCredit(account);

        assertEq(
            engine.deferredTraderCreditUsdc(account),
            50e6,
            "Trader claim should remain queued until the shortfall is cured"
        );
    }

}
