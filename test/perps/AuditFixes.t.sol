// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract AuditFixesTest is BasePerpTest {

    using stdStorage for StdStorage;

    function test_CloseClearsUnsettledCarryAfterSettlement() public {
        address trader = address(0xA1101);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 100_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 50_000e6, 1e8);

        stdstore.target(address(engine)).sig("unsettledCarryUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(10e6));

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 1e8);

        assertEq(engine.unsettledCarryUsdc(accountId), 0, "Close should clear cached unsettled carry");
    }

    function test_LiquidationClearsUnsettledCarryAfterSettlement() public {
        address trader = address(0xA1102);
        address keeper = address(0xA1103);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 8000e6);

        stdstore.target(address(engine)).sig("unsettledCarryUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(1e6));

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        vm.prank(keeper);
        router.executeLiquidation(accountId, priceData);

        assertEq(engine.unsettledCarryUsdc(accountId), 0, "Liquidation should clear cached unsettled carry");
    }

}
