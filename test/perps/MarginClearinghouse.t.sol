// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test, console} from "forge-std/Test.sol";

contract MockToken is ERC20 {

    uint8 _decimals;

    constructor(
        string memory name,
        string memory sym,
        uint8 dec
    ) ERC20(name, sym) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MarginClearinghouseTest is Test {

    MarginClearinghouse clearinghouse;
    MockToken usdc;

    address alice = address(0x111);
    address engine = address(0x999);
    bytes32 aliceId;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);

        clearinghouse = new MarginClearinghouse(address(usdc));
        aliceId = bytes32(uint256(uint160(alice)));

        // Authorize our mock Engine to lock/seize funds
        clearinghouse.proposeOperator(engine, true);
        vm.warp(48 hours + 2);
        clearinghouse.finalizeOperator();

        // Fund Alice
        usdc.mint(alice, 5000 * 1e6); // $5k USDC

        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        vm.stopPrank();
    }

    function test_WithdrawalFirewall_LockedMargin() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 5000 * 1e6); // $5k USDC

        // 1. Engine locks $4,000 of Buying Power for a CFD trade
        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 4000 * 1e6);

        // 2. Check Free Buying Power
        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceId);
        assertEq(freeBp, 1000 * 1e6, "Free BP should be exactly $1,000");

        // 3. Alice tries to withdraw $2,000. MUST REVERT because it breaches locked margin.
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(aliceId, 2000 * 1e6);

        // 4. Alice withdraws exactly $1,000. MUST SUCCEED.
        vm.prank(alice);
        clearinghouse.withdraw(aliceId, 1000 * 1e6);

        assertEq(usdc.balanceOf(alice), 1000 * 1e6, "Alice should receive $1k");
        assertEq(
            clearinghouse.getAccountEquityUsdc(aliceId),
            4000 * 1e6,
            "Remaining equity should exactly match locked margin"
        );
    }

    function test_BuyingPower_BlockedByActivePositions() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 4500 * 1e6);

        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceId);
        assertEq(freeBp, 500 * 1e6, "Free BP should be $500");

        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(aliceId, 1000 * 1e6);
    }

    function test_GetAccountUsdcBuckets_SplitsActiveAndQueuedMarginBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 600 * 1e6);

        assertEq(buckets.settlementBalanceUsdc, 2000 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 900 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 600 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1100 * 1e6);
    }

    function test_GetAccountUsdcBuckets_ClampsActiveMarginToTotalLocked() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 200 * 1e6);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 500 * 1e6);

        assertEq(buckets.activePositionMarginUsdc, 200 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 0);
        assertEq(buckets.freeSettlementUsdc, 800 * 1e6);
    }

    function test_Withdraw_WrongOwner_Reverts() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        address bob = address(0x222);
        vm.prank(bob);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotAccountOwner.selector);
        clearinghouse.withdraw(aliceId, 500 * 1e6);
    }

    function test_UnlockMargin_DefensiveUnderflow() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 1000 * 1e6);

        // Unlock more than locked — should defensively set to 0
        vm.prank(engine);
        clearinghouse.unlockMargin(aliceId, 2000 * 1e6);

        assertEq(clearinghouse.lockedMarginUsdc(aliceId), 0, "Locked margin should be zero after defensive unlock");
    }

    function test_SeizeAsset_RecipientMustEqualOperator() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidSeizeRecipient.selector);
        clearinghouse.seizeUsdc(aliceId, 100 * 1e6, address(0xBEEF));
    }

    function test_C01_WithdrawUsdcBelowLockedMargin_ShouldRevert() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 1000 * 1e6);

        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(aliceId, 1000 * 1e6);
    }

    function test_ConsumeFundingLoss_PreservesOtherLockedBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeFundingLoss(aliceId, 600 * 1e6, 1200 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(freeConsumed, 1100 * 1e6);
        assertEq(marginConsumed, 100 * 1e6);
        assertEq(uncovered, 0);
        assertEq(buckets.settlementBalanceUsdc, 800 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 800 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 800 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeFundingLoss_ReturnsUncoveredWhenFreeAndActiveMarginInsufficient() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeFundingLoss(aliceId, 600 * 1e6, 2000 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(freeConsumed, 1100 * 1e6);
        assertEq(marginConsumed, 600 * 1e6);
        assertEq(uncovered, 300 * 1e6, "Funding loss planner should report residual uncovered loss");
        assertEq(buckets.settlementBalanceUsdc, 300 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeLiquidationResidual_ConsumesQueuedCommittedMarginBeforeBadDebt() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc) =
            clearinghouse.consumeLiquidationResidual(aliceId, 600 * 1e6, int256(200 * 1e6), engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(seizedUsdc, 1800 * 1e6);
        assertEq(payoutUsdc, 0);
        assertEq(badDebtUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 200 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeCloseLoss_ConsumesQueuedCommittedMarginBeforeShortfall() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        (uint256 seizedUsdc, uint256 shortfallUsdc) = clearinghouse.consumeCloseLoss(aliceId, 1800 * 1e6, 0, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(seizedUsdc, 1800 * 1e6);
        assertEq(shortfallUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 200 * 1e6);
        assertEq(
            buckets.totalLockedMarginUsdc,
            200 * 1e6,
            "Close loss helper should keep only unconsumed queued margin locked"
        );
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeCloseLoss_MustConsumeCommittedMarginBeforeShortfall() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        (uint256 seizedUsdc, uint256 shortfallUsdc) = clearinghouse.consumeCloseLoss(aliceId, 1800 * 1e6, 0, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(
            seizedUsdc, 1800 * 1e6, "Close loss should consume same-account committed margin before socializing loss"
        );
        assertEq(shortfallUsdc, 0, "Queued committed margin should prevent avoidable close shortfall");
        assertEq(buckets.settlementBalanceUsdc, 200 * 1e6, "Only true remainder should survive");
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6, "Only unconsumed committed margin should remain locked");
        assertEq(buckets.freeSettlementUsdc, 0, "No free settlement should remain after terminal loss collection");
    }

    function test_ConsumeCloseLoss_ReturnsShortfallWhenTerminalBucketsInsufficient() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        (uint256 seizedUsdc, uint256 shortfallUsdc) = clearinghouse.consumeCloseLoss(aliceId, 1500 * 1e6, 0, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(seizedUsdc, 1000 * 1e6);
        assertEq(shortfallUsdc, 500 * 1e6, "Terminal close planner should report uncovered shortfall");
        assertEq(buckets.settlementBalanceUsdc, 0);
        assertEq(buckets.totalLockedMarginUsdc, 0);
    }

    function test_ConsumeLiquidationResidual_MustConsumeCommittedMarginBeforeBadDebt() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc) =
            clearinghouse.consumeLiquidationResidual(aliceId, 600 * 1e6, int256(200 * 1e6), engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(
            seizedUsdc,
            1800 * 1e6,
            "Liquidation should seize queued committed margin after exhausting free settlement and live margin"
        );
        assertEq(payoutUsdc, 0);
        assertEq(badDebtUsdc, 0, "Queued committed margin should prevent avoidable liquidation bad debt");
        assertEq(buckets.settlementBalanceUsdc, 200 * 1e6, "Only target residual should remain after liquidation");
        assertEq(
            buckets.totalLockedMarginUsdc, 200 * 1e6, "Only unconsumed queued committed margin should remain locked"
        );
        assertEq(
            buckets.freeSettlementUsdc,
            0,
            "Residual should not leave extra free settlement after liquidation consumes queued margin"
        );
    }

    function test_CreditSettlementAndLockMargin_CreditsAndLocksSameBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.creditSettlementAndLockMargin(aliceId, 200 * 1e6);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 200 * 1e6);
        assertEq(buckets.settlementBalanceUsdc, 1200 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1000 * 1e6);
    }

    function test_ApplyOpenCost_DebitsSettlementAndLeavesRemainingFreeBalance() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, 2000 * 1e6);

        vm.prank(engine);
        int256 netMarginChangeUsdc = clearinghouse.applyOpenCost(aliceId, 300 * 1e6, int256(200 * 1e6), engine);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 100 * 1e6);
        assertEq(netMarginChangeUsdc, 100 * 1e6);
        assertEq(buckets.settlementBalanceUsdc, 1800 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 100 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1700 * 1e6);
    }

    function test_Deposit_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAmount.selector);
        clearinghouse.deposit(aliceId, 0);
    }

}

contract MarginClearinghouseAuditTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: Finding-7 — fee-on-transfer accounting mismatch
    // H-02 FIX: free equity withdrawable with open position
    function test_WithdrawFreeEquityWithOpenPosition() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        uint256 freeBalance = clearinghouse.balanceUsdc(accountId) - clearinghouse.lockedMarginUsdc(accountId);
        assertGt(freeBalance, 0, "Alice should have free balance");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, freeBalance);
        assertEq(usdc.balanceOf(alice), balBefore + freeBalance, "Free equity withdrawn");
    }

    // Regression: Finding-8 — withdraw allowed after position close
    function test_WithdrawAllowedAfterClose() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be closed");

        uint256 balance = clearinghouse.balanceUsdc(accountId);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, balance);
        assertEq(usdc.balanceOf(alice), balance, "Alice should receive her USDC");
    }

}

contract NonUsdcCollateralTest is Test {

    MockToken usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    uint256 constant DEPTH = 5_000_000 * 1e6;

    function setUp() public {
        usdc = new MockToken("Mock USDC", "USDC", 6);

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.proposeWithdrawGuard(address(engine));
        vm.warp(48 hours + 2);
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        vm.warp(96 hours + 3);
        clearinghouse.finalizeOperator();

        vm.warp(1_709_532_000);

        usdc.mint(address(this), 10_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(5_000_000 * 1e6, address(this));
    }

    function _deposit(
        bytes32 accountId,
        uint256 amount
    ) internal {
        address user = address(uint160(uint256(accountId)));
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();
    }

    function _open(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    function externalOpen(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) external {
        _open(accountId, side, size, margin, price, depth);
    }

    // Regression: H-02 — non-USDC collateral blocks overleveraged position
    // Regression: H-02 — lockMargin accepts non-USDC equity


}
