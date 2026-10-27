// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {Test} from "forge-std/Test.sol";

abstract contract ForkTrancheFunding is Test {

    /// @dev Seed local LP liquidity through the asynchronous request/settle/claim lifecycle,
    /// before opening positions. Only the local Engine's initial mark is installed directly.
    function _fundForkTranche(
        TrancheVault vault,
        CfdEngine engine,
        address lp,
        uint256 amount
    ) internal {
        IERC20 asset = IERC20(vault.asset());
        deal(address(asset), lp, amount);
        vm.startPrank(lp);
        asset.approve(address(vault), amount);
        uint256 requestId = vault.requestDeposit(amount, lp, lp);
        vm.stopPrank();
        vm.warp(vault.depositEpochStart(requestId));
        uint256 price = engine.lastMarkPrice();
        vm.prank(engine.orderRouter());
        engine.updateMarkPrice(price == 0 ? 1e8 : price, uint64(block.timestamp));
        assertFalse(engine.terminalNavSnapshot().hasOpenPositions, "fund fork liquidity before trading");
        HousePool(address(vault.POOL())).settleLpEpoch(0, 0);
        assertEq(vault.claimableDepositRequest(requestId, lp), amount);
        vm.prank(lp);
        assertGt(vault.claimDeposit(requestId, amount, lp, lp), 0);
    }

}
