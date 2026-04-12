// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract OrderRouterPolicyMatrixTest is BasePerpTest {

    using stdStorage for StdStorage;

    address internal constant ALICE = address(0x111);
    address internal constant BOB = address(0x222);
    address internal constant KEEPER = address(0x999);

    function test_ExpiredOpenRefundsTrader() public {
        _fundTrader(ALICE, 10_000e6);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        uint256 traderWalletBefore = usdc.balanceOf(ALICE);
        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);

        vm.warp(block.timestamp + router.maxOrderAge() + 1);
        bytes[] memory empty;
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(usdc.balanceOf(KEEPER) - keeperWalletBefore, 0, "Expired open should not pay the clearer");
        assertEq(usdc.balanceOf(ALICE) - traderWalletBefore, 1e6, "Expired open should refund the trader bounty");
    }

    function test_ExpiredClosePaysClearer() public {
        bytes32 accountId = bytes32(uint256(uint160(ALICE)));
        _fundTrader(ALICE, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, true);

        uint256 traderWalletBefore = usdc.balanceOf(ALICE);
        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);

        vm.warp(block.timestamp + router.maxOrderAge() + 1);
        bytes[] memory empty;
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(usdc.balanceOf(KEEPER) - keeperWalletBefore, 1e6, "Expired close should pay the clearer");
        assertEq(usdc.balanceOf(ALICE) - traderWalletBefore, 0, "Expired close should not refund the trader wallet");
    }

    function test_SlippageOpenRefundsTrader() public {
        _fundJunior(BOB, 1_000_000e6);
        _fundTrader(ALICE, 50_000e6);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1.5e8, false);

        uint256 traderEthBefore = ALICE.balance;
        uint256 keeperEthBefore = KEEPER.balance;

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.deal(ALICE, 1 ether);
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        assertEq(KEEPER.balance - keeperEthBefore, 0, "Open slippage miss should not pay the clearer");
        assertEq(ALICE.balance, traderEthBefore + 1 ether, "Open slippage miss should refund the trader ETH bounty");
    }

    function test_SlippageClosePaysClearer() public {
        bytes32 accountId = bytes32(uint256(uint160(ALICE)));
        usdc.mint(ALICE, 251_500_000);
        vm.startPrank(ALICE);
        usdc.approve(address(clearinghouse), 251_500_000);
        clearinghouse.deposit(accountId, 251_500_000);
        vm.stopPrank();

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8, false);
        bytes[] memory openPrice = new bytes[](1);
        openPrice[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        router.executeOrder(1, openPrice);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 0.8e8, true);

        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        vm.prank(KEEPER);
        vm.roll(block.number + 1);
        router.executeOrder(2, closePrice);

        assertEq(usdc.balanceOf(KEEPER) - keeperWalletBefore, 1e6, "Close slippage miss should pay the clearer");
    }

    function test_ProtocolInvalidationRefundsTrader() public {
        _fundTrader(ALICE, 10_000e6);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);

        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        assertEq(usdc.balanceOf(KEEPER) - keeperWalletBefore, 0, "Protocol invalidation should not pay the clearer");
        assertEq(usdc.balanceOf(ALICE), 1e6, "Protocol invalidation should refund the trader bounty");
    }

    function test_UserInvalidPaysClearer() public {
        address eve = address(0xE223);
        bytes32 eveAccount = bytes32(uint256(uint160(eve)));

        vm.startPrank(eve);
        usdc.mint(eve, 1e6);
        usdc.approve(address(clearinghouse), 1e6);
        clearinghouse.deposit(eveAccount, 1e6);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 1e8, false);
        vm.stopPrank();

        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        assertEq(usdc.balanceOf(KEEPER) - keeperWalletBefore, 1e6, "User-invalid open should pay the clearer");
        assertEq(
            uint256(router.getOrderRecord(1).status),
            uint256(IOrderRouterAccounting.OrderStatus.Failed),
            "User-invalid order should fail terminally"
        );
    }

    function test_UntypedEngineRevertRefundsTrader() public {
        bytes32 accountId = bytes32(uint256(uint160(ALICE)));
        _fundTrader(ALICE, 10_000e6);

        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(0));

        uint256 traderWalletBefore = usdc.balanceOf(ALICE);
        uint256 keeperWalletBefore = usdc.balanceOf(KEEPER);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        assertEq(usdc.balanceOf(KEEPER) - keeperWalletBefore, 0, "Untyped engine revert should not pay the clearer");
        assertEq(usdc.balanceOf(ALICE) - traderWalletBefore, 1e6, "Untyped engine revert should refund the trader");
    }

}
