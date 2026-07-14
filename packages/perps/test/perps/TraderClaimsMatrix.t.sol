// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract TraderClaimsMatrixTest is BasePerpTest {

    using stdStorage for StdStorage;

    function test_TraderClaim_RevertsWhenSingleClaimExceedsAvailablePoolCash() public {
        address trader = address(0xDC01);
        address account = trader;
        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 20e6);

        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account)
            .checked_write(uint256(50e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(50e6));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(
            engine.traderClaimBalanceUsdc(account),
            50e6,
            "Trader claim should remain queued until the shortfall is cured"
        );
    }

}
