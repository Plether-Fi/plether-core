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

contract MockOracle {

    uint256 public price;

    constructor(
        uint256 _price
    ) {
        price = _price;
    }

    function getPriceUnsafe() external view returns (uint256) {
        return price;
    }

    function setPrice(
        uint256 _price
    ) external {
        price = _price;
    }

}

contract MarginClearinghouseTest is Test {

    MarginClearinghouse clearinghouse;
    MockToken usdc;
    MockToken splDxy;
    MockOracle splDxyOracle;

    address alice = address(0x111);
    address engine = address(0x999);
    bytes32 aliceId;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        splDxy = new MockToken("Staked DXY", "splDXY", 18);

        clearinghouse = new MarginClearinghouse(address(usdc));
        aliceId = bytes32(uint256(uint160(alice)));

        // Oracle returns $1.00 in 8 decimals
        splDxyOracle = new MockOracle(1e8);

        // Whitelist USDC (100% LTV, 6 dec, No Oracle)
        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        vm.warp(48 hours + 2);
        clearinghouse.finalizeAssetConfig();

        // Whitelist splDXY (95% LTV Haircut, 18 dec, Mock Oracle)
        clearinghouse.proposeAssetConfig(address(splDxy), 18, 9500, address(splDxyOracle));
        vm.warp(96 hours + 3);
        clearinghouse.finalizeAssetConfig();

        // Authorize our mock Engine to lock/seize funds
        clearinghouse.proposeOperator(engine, true);
        vm.warp(144 hours + 4);
        clearinghouse.finalizeOperator();

        // Fund Alice
        usdc.mint(alice, 5000 * 1e6); // $5k USDC
        splDxy.mint(alice, 10_000 * 1e18); // 10k splDXY

        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        splDxy.approve(address(clearinghouse), type(uint256).max);
        vm.stopPrank();
    }

    function test_CrossMarginValuation() public {
        vm.startPrank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6); // Deposit $1,000 USDC
        clearinghouse.deposit(aliceId, address(splDxy), 10_000 * 1e18); // Deposit 10k splDXY ($10,000 spot value)
        vm.stopPrank();

        // 1. Check Portfolio Value
        // $1,000 USDC * 100% = $1,000
        // $10,000 splDXY * 95% LTV Haircut = $9,500
        // Total Expected Equity = $10,500 USDC (6 decimals)

        uint256 equity = clearinghouse.getAccountEquityUsdc(aliceId);
        assertEq(equity, 10_500 * 1e6, "Equity valuation incorrect");

        // 2. Oracle Price Crash! splDXY drops from $1.00 to $0.50
        splDxyOracle.setPrice(0.5e8);

        // New Value: $1,000 + ($5,000 * 95%) = $5,750
        uint256 crashedEquity = clearinghouse.getAccountEquityUsdc(aliceId);
        assertEq(crashedEquity, 5750 * 1e6, "Oracle price crash did not update equity");
    }

    function test_WithdrawalFirewall_LockedMargin() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 5000 * 1e6); // $5k USDC

        // 1. Engine locks $4,000 of Buying Power for a CFD trade
        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 4000 * 1e6);

        // 2. Check Free Buying Power
        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceId);
        assertEq(freeBp, 1000 * 1e6, "Free BP should be exactly $1,000");

        // 3. Alice tries to withdraw $2,000. MUST REVERT because it breaches locked margin.
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(aliceId, address(usdc), 2000 * 1e6);

        // 4. Alice withdraws exactly $1,000. MUST SUCCEED.
        vm.prank(alice);
        clearinghouse.withdraw(aliceId, address(usdc), 1000 * 1e6);

        assertEq(usdc.balanceOf(alice), 1000 * 1e6, "Alice should receive $1k");
        assertEq(
            clearinghouse.getAccountEquityUsdc(aliceId),
            4000 * 1e6,
            "Remaining equity should exactly match locked margin"
        );
    }

    function test_LtvHaircut_80Percent() public {
        MockToken weth = new MockToken("Wrapped ETH", "WETH", 18);
        MockOracle wethOracle = new MockOracle(2000e8);
        clearinghouse.proposeAssetConfig(address(weth), 18, 8000, address(wethOracle));
        vm.warp(block.timestamp + 48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(aliceId, address(weth), 1e18);
        vm.stopPrank();

        // 1e18 * 2000e8 / 10^20 = 2000e6 spot value → 80% haircut = 1600e6
        uint256 equity = clearinghouse.getAccountEquityUsdc(aliceId);
        assertEq(equity, 1600 * 1e6, "80% LTV should haircut to $1600");
    }

    function test_BuyingPower_BlockedByActivePositions() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 4500 * 1e6);

        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceId);
        assertEq(freeBp, 500 * 1e6, "Free BP should be $500");

        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(aliceId, address(usdc), 1000 * 1e6);
    }

    function test_FreeSettlementBalance_TracksLockedUsdcOnly() public {
        vm.startPrank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6);
        clearinghouse.deposit(aliceId, address(splDxy), 10_000 * 1e18);
        vm.stopPrank();

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 600 * 1e6);

        assertEq(
            clearinghouse.getFreeBuyingPowerUsdc(aliceId),
            9900 * 1e6,
            "Buying power should include discounted non-USDC collateral"
        );
        assertEq(
            clearinghouse.getFreeSettlementBalanceUsdc(aliceId),
            400 * 1e6,
            "Free settlement balance should only count unencumbered USDC"
        );
    }

    function test_GetAccountUsdcBuckets_SplitsActiveAndReservedBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 600 * 1e6);

        assertEq(buckets.settlementBalanceUsdc, 2000 * 1e6);
        assertEq(buckets.reservedSettlementUsdc, 50 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 900 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 600 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1050 * 1e6);
    }

    function test_GetAccountUsdcBuckets_ClampsActiveMarginToTotalLocked() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 200 * 1e6);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 500 * 1e6);

        assertEq(buckets.activePositionMarginUsdc, 200 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 0);
        assertEq(buckets.freeSettlementUsdc, 800 * 1e6);
    }

    function test_Deposit_UnsupportedAsset_Reverts() public {
        MockToken randomToken = new MockToken("Random", "RND", 18);
        randomToken.mint(alice, 1000e18);

        vm.startPrank(alice);
        randomToken.approve(address(clearinghouse), type(uint256).max);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__AssetNotSupported.selector);
        clearinghouse.deposit(aliceId, address(randomToken), 1000e18);
        vm.stopPrank();
    }

    function test_Withdraw_WrongOwner_Reverts() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6);

        address bob = address(0x222);
        vm.prank(bob);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotAccountOwner.selector);
        clearinghouse.withdraw(aliceId, address(usdc), 500 * 1e6);
    }

    function test_UnlockMargin_DefensiveUnderflow() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 1000 * 1e6);

        // Unlock more than locked — should defensively set to 0
        vm.prank(engine);
        clearinghouse.unlockMargin(aliceId, 2000 * 1e6);

        assertEq(clearinghouse.lockedMarginUsdc(aliceId), 0, "Locked margin should be zero after defensive unlock");
    }

    function test_SeizeAsset_RecipientMustEqualOperator() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6);

        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidSeizeRecipient.selector);
        clearinghouse.seizeAsset(aliceId, address(usdc), 100 * 1e6, address(0xBEEF));
    }

    function test_SettleUsdc_RejectsNonSettlementAsset() public {
        vm.prank(engine);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__AssetNotSupported.selector);
        clearinghouse.settleUsdc(aliceId, address(splDxy), 1e6);
    }

    function test_C01_WithdrawUsdcBelowLockedMargin_ShouldRevert() public {
        vm.startPrank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6);
        clearinghouse.deposit(aliceId, address(splDxy), 10_000 * 1e18);
        vm.stopPrank();

        // splDXY equity = 10_000 * $1.00 * 95% = $9,500
        // Total equity = $1,000 + $9,500 = $10,500

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 1000 * 1e6);
        // lockMargin passes: USDC balance (1000) >= locked (1000) ✓

        // Withdraw all USDC. Remaining equity ($9,500 from splDXY) > locked ($1,000),
        // so the generic equity check passes — but the settlement asset is now $0.
        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceId, address(usdc), 1000 * 1e6);
    }

    function test_ConsumeFundingLoss_PreservesOtherLockedAndReservedBuckets() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeFundingLoss(aliceId, 600 * 1e6, 1200 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(freeConsumed, 1050 * 1e6);
        assertEq(marginConsumed, 150 * 1e6);
        assertEq(uncovered, 0);
        assertEq(buckets.settlementBalanceUsdc, 800 * 1e6);
        assertEq(buckets.reservedSettlementUsdc, 50 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 750 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 750 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeFundingLoss_ReturnsUncoveredWhenFreeAndActiveMarginInsufficient() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        (uint256 marginConsumed, uint256 freeConsumed, uint256 uncovered) =
            clearinghouse.consumeFundingLoss(aliceId, 600 * 1e6, 2_000 * 1e6, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(freeConsumed, 1_050 * 1e6);
        assertEq(marginConsumed, 600 * 1e6);
        assertEq(uncovered, 350 * 1e6, "Funding loss planner should report residual uncovered loss");
        assertEq(buckets.settlementBalanceUsdc, 350 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 300 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 300 * 1e6);
    }

    function test_ConsumeLiquidationResidual_ConsumesQueuedCommittedMarginBeforeBadDebt() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc) =
            clearinghouse.consumeLiquidationResidual(aliceId, 600 * 1e6, int256(200 * 1e6), engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(seizedUsdc, 1750 * 1e6);
        assertEq(payoutUsdc, 0);
        assertEq(badDebtUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 250 * 1e6);
        assertEq(buckets.reservedSettlementUsdc, 50 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.otherLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeCloseLoss_ConsumesQueuedCommittedMarginBeforeShortfall() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        (uint256 seizedUsdc, uint256 shortfallUsdc) = clearinghouse.consumeCloseLoss(aliceId, 1800 * 1e6, 0, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(seizedUsdc, 1800 * 1e6);
        assertEq(shortfallUsdc, 0);
        assertEq(buckets.settlementBalanceUsdc, 200 * 1e6);
        assertEq(buckets.reservedSettlementUsdc, 50 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 150 * 1e6, "Close loss helper should keep only unconsumed queued margin locked");
        assertEq(buckets.freeSettlementUsdc, 0);
    }

    function test_ConsumeCloseLoss_MustConsumeCommittedMarginBeforeShortfall() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        (uint256 seizedUsdc, uint256 shortfallUsdc) = clearinghouse.consumeCloseLoss(aliceId, 1800 * 1e6, 0, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(seizedUsdc, 1800 * 1e6, "Close loss should consume same-account committed margin before socializing loss");
        assertEq(shortfallUsdc, 0, "Queued committed margin should prevent avoidable close shortfall");
        assertEq(buckets.settlementBalanceUsdc, 200 * 1e6, "Only reserved escrow and any true remainder should survive");
        assertEq(buckets.reservedSettlementUsdc, 50 * 1e6, "Keeper reserve must remain protected");
        assertEq(buckets.totalLockedMarginUsdc, 150 * 1e6, "Only unconsumed committed margin should remain locked");
        assertEq(buckets.freeSettlementUsdc, 0, "No free settlement should remain after terminal loss collection");
    }

    function test_ConsumeCloseLoss_ReturnsShortfallWhenTerminalBucketsInsufficient() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        (uint256 seizedUsdc, uint256 shortfallUsdc) = clearinghouse.consumeCloseLoss(aliceId, 1_500 * 1e6, 0, engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(seizedUsdc, 950 * 1e6);
        assertEq(shortfallUsdc, 550 * 1e6, "Terminal close planner should report uncovered shortfall");
        assertEq(buckets.settlementBalanceUsdc, 50 * 1e6);
        assertEq(buckets.reservedSettlementUsdc, 50 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 0);
    }

    function test_ConsumeLiquidationResidual_MustConsumeCommittedMarginBeforeBadDebt() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.lockMargin(aliceId, 900 * 1e6);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc) =
            clearinghouse.consumeLiquidationResidual(aliceId, 600 * 1e6, int256(200 * 1e6), engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 0);
        assertEq(seizedUsdc, 1750 * 1e6, "Liquidation should seize queued committed margin after exhausting free settlement and live margin");
        assertEq(payoutUsdc, 0);
        assertEq(badDebtUsdc, 0, "Queued committed margin should prevent avoidable liquidation bad debt");
        assertEq(buckets.settlementBalanceUsdc, 250 * 1e6, "Only reserved escrow and target residual should remain after liquidation");
        assertEq(buckets.reservedSettlementUsdc, 50 * 1e6, "Keeper reserve must remain protected");
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6, "Only unconsumed queued committed margin should remain locked");
        assertEq(buckets.freeSettlementUsdc, 0, "Residual should not leave extra free settlement after liquidation consumes queued margin");
    }

    function test_CreditSettlementAndLockMargin_CreditsAndLocksSameBucket() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6);

        vm.prank(engine);
        clearinghouse.creditSettlementAndLockMargin(aliceId, 200 * 1e6);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 200 * 1e6);
        assertEq(buckets.settlementBalanceUsdc, 1200 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 200 * 1e6);
        assertEq(buckets.activePositionMarginUsdc, 200 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1000 * 1e6);
    }

    function test_ApplyOpenCost_PreservesReservedSettlementOnDebit() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 2000 * 1e6);

        vm.startPrank(engine);
        clearinghouse.reserveSettlementUsdc(aliceId, 50 * 1e6);
        int256 netMarginChangeUsdc = clearinghouse.applyOpenCost(aliceId, 300 * 1e6, int256(200 * 1e6), engine);
        vm.stopPrank();

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(aliceId, 100 * 1e6);
        assertEq(netMarginChangeUsdc, 100 * 1e6);
        assertEq(buckets.settlementBalanceUsdc, 1800 * 1e6);
        assertEq(buckets.reservedSettlementUsdc, 50 * 1e6);
        assertEq(buckets.totalLockedMarginUsdc, 100 * 1e6);
        assertEq(buckets.freeSettlementUsdc, 1650 * 1e6);
    }

    function test_LockMargin_RequiresPhysicalUsdcBackingAfterReservingSettlementEscrow() public {
        MockToken wbtc = new MockToken("Wrapped BTC", "WBTC", 8);
        MockOracle wbtcOracle = new MockOracle(60_000 * 1e8);
        clearinghouse.proposeAssetConfig(address(wbtc), 8, 8000, address(wbtcOracle));
        vm.warp(block.timestamp + 48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 100 * 1e6);

        wbtc.mint(alice, 1 * 1e8);
        vm.startPrank(alice);
        wbtc.approve(address(clearinghouse), 1 * 1e8);
        clearinghouse.deposit(aliceId, address(wbtc), 1 * 1e8);
        vm.stopPrank();

        vm.startPrank(engine);
        clearinghouse.reserveSettlementUsdc(aliceId, 1 * 1e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientUsdcForSettlement.selector);
        clearinghouse.lockMargin(aliceId, 100 * 1e6);
        vm.stopPrank();

        assertEq(clearinghouse.lockedMarginUsdc(aliceId), 0, "Margin lock should fail when reserved escrow already consumes part of physical USDC");
        assertEq(clearinghouse.reservedSettlementUsdc(aliceId), 1 * 1e6, "Reserved keeper escrow should remain tracked after failed margin lock");
    }

    function test_SupportAsset_InvalidLTV_Reverts() public {
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidLTV.selector);
        clearinghouse.proposeAssetConfig(address(0xBEEF), 18, 10_001, address(0));
    }

    function test_Deposit_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAmount.selector);
        clearinghouse.deposit(aliceId, address(usdc), 0);
    }

}

contract MockFeeOnTransferToken is ERC20 {

    using SafeERC20 for IERC20;

    uint256 public feeBps;

    constructor(
        uint256 _feeBps
    ) ERC20("Fee Token", "FOT") {
        feeBps = _feeBps;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (amount * feeBps) / 10_000;
            super._update(from, to, amount - fee);
            if (fee > 0) {
                super._update(from, address(0), fee);
            }
        } else {
            super._update(from, to, amount);
        }
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
    function test_FeeOnTransferAccounting() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken(100); // 1% fee
        clearinghouse.proposeAssetConfig(address(fot), 18, 10_000, address(0));
        _warpForward(48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        uint256 depositAmount = 1000 * 1e18;
        fot.mint(alice, depositAmount);

        vm.startPrank(alice);
        fot.approve(address(clearinghouse), depositAmount);
        clearinghouse.deposit(accountId, address(fot), depositAmount);
        vm.stopPrank();

        uint256 recordedBalance = clearinghouse.balances(accountId, address(fot));
        uint256 actualBalance = fot.balanceOf(address(clearinghouse));

        assertEq(recordedBalance, actualBalance, "Recorded balance should match actual tokens received");
    }

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

        uint256 freeBalance =
            clearinghouse.balances(accountId, address(usdc)) - clearinghouse.lockedMarginUsdc(accountId);
        assertGt(freeBalance, 0, "Alice should have free balance");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, address(usdc), freeBalance);
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

        uint256 balance = clearinghouse.balances(accountId, address(usdc));
        vm.prank(alice);
        clearinghouse.withdraw(accountId, address(usdc), balance);
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

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        vm.warp(48 hours + 2);
        clearinghouse.finalizeAssetConfig();
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
        clearinghouse.deposit(accountId, address(usdc), amount);
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
    function test_NonUsdcCollateral_LockMarginBlocksOverleveragedPosition() public {
        MockToken wbtc = new MockToken("Wrapped BTC", "WBTC", 8);
        MockOracle wbtcOracle = new MockOracle(60_000 * 1e8);

        clearinghouse.proposeAssetConfig(address(wbtc), 8, 8000, address(wbtcOracle));
        vm.warp(block.timestamp + 48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        address attacker = address(0xBAD);
        bytes32 attackerId = bytes32(uint256(uint160(attacker)));

        uint256 wbtcAmount = 2 * 1e8;
        wbtc.mint(attacker, wbtcAmount);
        vm.startPrank(attacker);
        wbtc.approve(address(clearinghouse), wbtcAmount);
        clearinghouse.deposit(attackerId, address(wbtc), wbtcAmount);
        vm.stopPrank();

        uint256 smallUsdc = 5000 * 1e6;
        _deposit(attackerId, smallUsdc);

        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(attackerId);
        assertGt(freeBp, 50_000 * 1e6, "WBTC inflates buying power far beyond USDC");

        bool opened;
        try this.externalOpen(attackerId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH) {
            opened = true;
        } catch {
            opened = false;
        }

        assertFalse(opened, "H-02: lockMargin must block positions where USDC is insufficient to back locked margin");
    }

    // Regression: H-02 — lockMargin accepts non-USDC equity
    function test_LockMargin_AcceptsNonUsdcEquity() public {
        MockToken wbtc = new MockToken("Wrapped BTC", "WBTC", 8);
        MockOracle wbtcOracle = new MockOracle(60_000 * 1e8);

        clearinghouse.proposeAssetConfig(address(wbtc), 8, 8000, address(wbtcOracle));
        vm.warp(block.timestamp + 48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        address attacker = address(0xBAD2);
        bytes32 attackerId = bytes32(uint256(uint160(attacker)));

        wbtc.mint(attacker, 2 * 1e8);
        vm.startPrank(attacker);
        wbtc.approve(address(clearinghouse), 2 * 1e8);
        clearinghouse.deposit(attackerId, address(wbtc), 2 * 1e8);
        vm.stopPrank();

        uint256 equity = clearinghouse.getAccountEquityUsdc(attackerId);
        assertGt(equity, 0, "WBTC creates buying power");
        assertEq(clearinghouse.balances(attackerId, address(usdc)), 0, "Zero USDC");

        uint256 minUsdc = 1000 * 1e6;
        _deposit(attackerId, minUsdc);

        bool opened;
        try this.externalOpen(attackerId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH) {
            opened = true;
        } catch {
            opened = false;
        }

        assertFalse(
            opened, "H-02: lockMargin must require sufficient USDC, not just aggregate equity including non-USDC"
        );
    }

}
