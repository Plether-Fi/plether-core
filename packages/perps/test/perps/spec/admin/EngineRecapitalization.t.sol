// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract EngineRecapitalizationTest is BasePerpTest {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 100_000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 100_000e6;
    }

    function _fundRecapitalization(
        uint256 amount
    ) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(engine), amount);
    }

    function test_RecapitalizePool_RestoresSeniorWithoutMintingShares() public {
        usdc.burn(address(pool), 140_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 60_000e6);
        assertEq(pool.juniorPrincipal(), 0);
        uint256 seniorSupply = seniorVault.totalSupply();
        uint256 juniorSupply = juniorVault.totalSupply();
        uint256 accountedBefore = pool.accountedAssets();

        _fundRecapitalization(50_000e6);
        vm.expectEmit(true, false, false, true, address(engine));
        emit ICfdEngineTypes.PoolRecapitalized(address(this), 50_000e6);
        engine.recapitalizePool(50_000e6);

        assertEq(usdc.balanceOf(address(pool)), 110_000e6);
        assertEq(usdc.balanceOf(address(this)), 0);
        assertEq(pool.accountedAssets(), accountedBefore + 50_000e6);
        assertEq(pool.pendingRecapitalizationUsdc(), 50_000e6);
        assertEq(pool.pendingTradingRevenueUsdc(), 0);
        assertEq(seniorVault.totalSupply(), seniorSupply);
        assertEq(juniorVault.totalSupply(), juniorSupply);

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 100_000e6);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 10_000e6);
        assertEq(pool.pendingRecapitalizationUsdc(), 0);
        assertEq(seniorVault.totalSupply(), seniorSupply);
        assertEq(juniorVault.totalSupply(), juniorSupply);
    }

    function test_RecapitalizePool_OnlyOwner() public {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        engine.recapitalizePool(1e6);
        vm.prank(address(engineAdmin));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(engineAdmin)));
        engine.recapitalizePool(1e6);
    }

    function test_RecapitalizePool_RejectsZeroAmount() public {
        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAmount.selector);
        engine.recapitalizePool(0);
    }

    function test_RecapitalizePool_RejectsUnsetPool() public {
        CfdEngine unwired = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), 50);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidPool.selector);
        unwired.recapitalizePool(1e6);
    }

    function test_RecapitalizePool_FailedTransferDoesNotCreditPool() public {
        _fundRecapitalization(1e6);
        usdc.approve(address(engine), 0);
        uint256 accountedBefore = pool.accountedAssets();
        uint256 cashBefore = usdc.balanceOf(address(pool));
        vm.expectRevert();
        engine.recapitalizePool(1e6);
        assertEq(pool.accountedAssets(), accountedBefore);
        assertEq(pool.pendingRecapitalizationUsdc(), 0);
        assertEq(usdc.balanceOf(address(pool)), cashBefore);
        assertEq(usdc.balanceOf(address(this)), 1e6);
    }

    function test_RecapitalizePool_RejectsMissingReceiptDespiteExistingExcess() public {
        uint256 amount = 1e6;
        _fundRecapitalization(amount);
        usdc.mint(address(pool), amount);
        uint256 accountedBefore = pool.accountedAssets();
        vm.mockCall(
            address(usdc), abi.encodeCall(IERC20.transferFrom, (address(this), address(pool), amount)), abi.encode(true)
        );
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__UnexpectedTransferAmount.selector, amount, 0));
        engine.recapitalizePool(amount);
        assertEq(pool.accountedAssets(), accountedBefore);
        assertEq(pool.pendingRecapitalizationUsdc(), 0);
        assertEq(pool.excessAssets(), amount);
    }

    function test_RecapitalizePool_AccountingFailureRollsBackTransferAndCarry() public {
        uint256 amount = 1e6;
        _fundRecapitalization(amount);
        uint256 cashBefore = usdc.balanceOf(address(pool));
        uint256 accountedBefore = pool.accountedAssets();
        uint256 carryTimestamp = engine.sideCarryTimestamp(0);
        vm.warp(block.timestamp + 1 hours);
        vm.mockCallRevert(
            address(pool),
            abi.encodeCall(
                IHousePool.recordClaimantInflow,
                (amount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived)
            ),
            bytes("accounting failed")
        );
        vm.expectRevert(bytes("accounting failed"));
        engine.recapitalizePool(amount);
        assertEq(usdc.balanceOf(address(pool)), cashBefore);
        assertEq(usdc.balanceOf(address(this)), amount);
        assertEq(usdc.allowance(address(this), address(engine)), amount);
        assertEq(pool.accountedAssets(), accountedBefore);
        assertEq(pool.pendingRecapitalizationUsdc(), 0);
        assertEq(engine.sideCarryTimestamp(0), carryTimestamp);
    }

    function test_RecapitalizePool_CheckpointsCarryBeforeFundingWithStaleMark() public {
        address trader = address(0xA11CE);
        _fundTrader(trader, 10_000e6);
        _open(trader, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8);
        // With raw cash below accounted assets, even the token transfer changes effective carry depth.
        usdc.burn(address(pool), 50_000e6);
        vm.warp(block.timestamp + 1 hours);
        uint256 snapshot = vm.snapshotState();
        engine.checkpointCarryIndexes();
        uint256 expectedLongIndex = engine.sideCarryIndex(0);
        uint256 expectedShortIndex = engine.sideCarryIndex(1);
        assertTrue(vm.revertToState(snapshot));
        vm.deleteStateSnapshot(snapshot);

        _fundRecapitalization(100_000e6);
        engine.recapitalizePool(100_000e6);
        assertEq(engine.sideCarryIndex(0), expectedLongIndex);
        assertEq(engine.sideCarryIndex(1), expectedShortIndex);
        assertEq(engine.sideCarryTimestamp(0), block.timestamp);
        assertEq(pool.pendingRecapitalizationUsdc(), 100_000e6);
    }

    function test_RecapitalizePool_RemainsAvailableDuringFrozenSettlementHold() public {
        pool.pause();
        pool.pauseLpEpochSettlement();
        vm.warp(1_710_021_600);
        assertTrue(engine.isOracleFrozen());
        _fundRecapitalization(1e6);
        engine.recapitalizePool(1e6);
        assertEq(pool.pendingRecapitalizationUsdc(), 1e6);
        assertTrue(pool.paused());
        assertTrue(pool.lpEpochSettlementPaused());
    }

}
