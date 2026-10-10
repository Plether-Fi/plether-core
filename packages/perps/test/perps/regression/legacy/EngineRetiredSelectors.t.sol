// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineRetiredSelectorsTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_RetiredDebtLedgerSelectorIsAbsent() public {
        (bool success,) = address(engine).call(abi.encodeWithSignature("clearBadDebt(uint256)", 1));
        assertFalse(success, "V2 must not expose a mutable protocol bad-debt ledger selector");
    }

    function test_DirectEngineDonationIsOutsideCanonicalPoolAndCannotBeSweptThroughRetiredSelector() public {
        uint256 poolAssetsBefore = pool.totalAssets();
        ICfdEngineTypes.TerminalNavSnapshot memory terminalBefore = engine.terminalNavSnapshot();
        usdc.mint(address(engine), 123e6);
        uint256 ownerBefore = usdc.balanceOf(address(this));

        (bool success,) = address(engine)
            .call(abi.encodeWithSignature("sweepToken(address,address,uint256)", address(usdc), address(this), 123e6));

        assertFalse(success, "V2 engine must not expose a discretionary token-sweep selector");
        assertEq(usdc.balanceOf(address(engine)), 123e6, "A direct donation must remain outside canonical custody");
        assertEq(usdc.balanceOf(address(this)), ownerBefore, "The retired selector must not transfer donated tokens");
        assertEq(pool.totalAssets(), poolAssetsBefore, "Direct engine donations must not alter canonical pool assets");
        ICfdEngineTypes.TerminalNavSnapshot memory terminalAfter = engine.terminalNavSnapshot();
        assertEq(
            terminalAfter.terminalLpPriceDeltaUsdc,
            terminalBefore.terminalLpPriceDeltaUsdc,
            "Direct engine donations must not alter exact terminal NAV"
        );
        assertEq(terminalAfter.bookVersion, terminalBefore.bookVersion, "Direct donations must not mutate the NAV book");
    }

}

