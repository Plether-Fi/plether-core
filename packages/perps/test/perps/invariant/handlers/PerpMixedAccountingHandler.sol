// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {RecordedOrderReceipts} from "../../../utils/RecordedOrderReceipts.sol";
import {CarryReferenceLedger} from "../ghost/CarryReferenceLedger.sol";
import {CloseReferenceMath} from "../ghost/CloseReferenceMath.sol";
import {LiquidationReferenceMath} from "../ghost/LiquidationReferenceMath.sol";
import {MarketCalendarReference} from "../ghost/MarketCalendarReference.sol";
import {PendingOrderReferenceLedger} from "../ghost/PendingOrderReferenceLedger.sol";
import {WaterfallReferenceMath} from "../ghost/WaterfallReferenceMath.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Persistent public-Router campaign joining carry, exact basis, VPI, claims, and delayed Junior deposits.
/// @dev Four traders and two LPs are the complete actor domain. Expected state comes only from initialization and
/// submitted actions, never previews, receipts, production math, or balance deltas. Receipts authenticate outcomes.
/// Generated partial closes retain ample collateral; the deterministic shortage history separately proves deferred
/// claims and claim-backed partial closes. Senior owners and maintenance-free Junior seed shares stay fixed.
contract PerpMixedAccountingHandler is RecordedOrderReceipts {

    uint256 internal constant CAP = 2e8;
    uint256 internal constant INITIAL_CASH = 100_000e6;
    address public constant KEEPER = address(0xAA7700);

    struct HistoricalTick {
        uint256 componentPrice;
        uint256 publishTime;
        uint256 previousPublishTime;
        bool available;
    }

    HistoricalTick internal latestAuthoredTick;
    mapping(uint64 => HistoricalTick) internal historicalOrderTicks;
    uint256 public currentMarkTime;
    bool internal hasAcceptedMark;

    struct Trader {
        uint256 lots;
        uint256 basis;
        uint256 margin;
        uint256 cash;
        uint256 claim;
        uint256 liquidationReserve;
        uint256 wallet;
        int256 vpi;
    }

    struct Lp {
        uint256 epoch;
        uint256 pending;
        uint256 claimAssets;
        uint256 claimShares;
        uint256 shares;
        uint256 wallet;
        uint256 lastDepositTime;
        uint256 redeemEpoch;
        uint256 pendingRedeemShares;
        uint256 claimRedeemShares;
        uint256 claimRedeemAssets;
        uint256 redeemBasis;
        uint256 refundableRedeemShares;
        uint256 redeemedShares;
        uint256 redeemedAssets;
        uint256 refundedShares;
        uint256 lastClaimFundingRound;
        bool redeemQueued;
        bool redeemFundingClaimed;
        bool redeemRefundClaimed;
    }

    struct LpEpochDust {
        uint256 remainingControllers;
        uint256 dust;
        uint256 activationTime;
    }

    struct LpRedeemEpoch {
        uint256 shares;
        uint256 fundedShares;
        uint256 fundedAssets;
        uint256 fundingClaimsRemaining;
        uint256 refundClaimsRemaining;
        uint256 claimedShares;
        uint256 claimedAssets;
        uint256 refundedShares;
        uint256 fundingBasisClaimed;
        uint256 refundBasisClaimed;
        uint256 fundingRounds;
        uint256 assetDust;
        uint256 refundDust;
        bool refundable;
    }

    MockUSDC public immutable usdc;
    MockPyth public immutable pyth;
    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    HousePool public immutable pool;
    TrancheVault public immutable junior;
    TrancheVault public immutable senior;
    OrderRouter public immutable router;
    CarryReferenceLedger public immutable carry;
    PendingOrderReferenceLedger public immutable orders;
    uint256[4] public positionEpochs;
    uint256 public rejectedQueuedCloseSize;
    uint256 public rejectedEarlyExpiry;
    uint256 public pendingCloseOnlyResults;
    uint256 public pendingMevRejections;
    uint256 public slippageFailures;
    uint64 public riskOffCutoff;
    uint256 public orderCommits;
    uint256 public overlappingCommits;
    uint256 public maximumLiveOrders;
    uint256 public executedDelayedOrders;
    uint256 public expiredOrders;
    uint256 public riskOffOrders;
    uint256 public failedOrders;
    uint256 public replayedOrders;
    uint256 public conflictingReplays;
    uint256 public rejectedSixthOrders;
    uint256 public pendingSameBlockResults;
    uint256 public completedBatches;
    uint256 public stoppedBatches;
    uint256 public zeroFreeCloseOrders;
    uint256 public closesBehindPendingOrders;
    uint256 public unpaidFailedCloses;
    uint256 public unpaidFailureTransitions;
    uint256 public unpaidCloseLiquidations;
    uint256 public pendingCloseHealthyRejections;
    uint256 public closeOpenCloseHistories;
    uint256 public lpEpochsWithPendingCloses;
    uint256 public pendingMarginConsumed;
    mapping(uint64 => uint256) public committedCarry;
    mapping(uint64 => uint256) public expectedExecutionPrices;
    mapping(uint64 => uint256) public expectedExecutionTimes;
    uint256 public historicalPriceRejections;
    uint256 public rejectedCloseCommitments;
    uint256 public rejectedOpenCommitments;
    uint256 public rejectedCloseOnlyCommits;
    uint256 public rejectedMarginAdds;
    mapping(uint64 => uint256) internal forfeitedOrderBounties;
    address public immutable owner;
    address public immutable seedOwner;
    Trader[4] internal traders;
    Lp[2] internal lps;
    mapping(uint256 => LpEpochDust) internal depositEpochDust;
    mapping(uint256 => LpRedeemEpoch) internal redeemEpochs;
    uint256 public expectedDepositDustShares;
    uint256 public expectedRedeemDustAssets;
    uint256 public lpRedemptionRequests;
    uint256 public lpRedemptionSettlements;
    uint256 public lpRedemptionClaims;
    uint256 public lpRedemptionCancellations;
    uint256 public burnedDepositDustShares;
    uint256 public returnedRedemptionDustAssets;
    uint256 public expectedPendingRedeemEscrowShares;
    uint256 public expectedJuniorSeedShares = 500_000e9;
    uint256 public lpDepositRejections;
    uint256 public lpDeferredDeposits;
    uint256 public lpPartialRedemptions;
    uint256 public lpUnfundedRedemptions;
    uint256 public lpRedemptionRefunds;
    uint256 public lpNoProgressRejections;
    uint256 public lpNonterminalClaims;
    uint256 public lpClaimsAfterFurtherFunding;
    uint256 public lpShareClaims;
    uint256 public lpAssetClaims;
    uint256 public lpClaimRejections;
    uint256 public lpRefundsBeforeCash;
    uint256 public lpRefundsAfterCash;
    uint256 public lpZeroShareRefunds;
    uint256[] internal modeledRedeemEpochIds;
    uint256[2] public sideLots;
    uint256 public expectedPoolCash = 1_000_000e6;
    uint256 public expectedAccounted = 1_000_000e6;
    uint256 public expectedTreasury;
    uint256 public expectedKeeper;
    uint256 public expectedClaims;
    uint256 public expectedSenior = 500_000e6;
    uint256 public expectedJunior = 500_000e6;
    uint256 public expectedHwm = 500_000e6;
    uint256 public expectedJuniorSupply = 500_000e9;
    uint256 public expectedCouponTime;
    uint256 public currentPrice = 1e8;
    uint256 public explicitFunding = 1_400_000e6;
    uint256 public externalShockOut;
    uint256 public externalShockIn;
    uint256 public nonce;
    uint256 public successfulOpens;
    uint256 public successfulIncreases;
    uint256 public partialCloses;
    uint256 public fullCloses;
    uint256 public frozenCloses;
    uint256 public positiveVpiActions;
    uint256 public negativeVpiActions;
    uint256 public deferredClaims;
    uint256 public waivedActionCharges;
    uint256 public rejectedSmallOrders;
    uint256 public claimBackedPartialCloses;
    uint256 public settledClaims;
    uint256 public heldSettlements;
    uint256 public lpSettlements;
    uint256 public lpClaims;
    uint256 public lpCancellations;
    uint256 public carryCollected;
    uint256 public arrearsEpisodes;
    uint256 public liquidations;
    uint256[2] public liquidationsBySide;
    uint256 public claimBearingLiquidations;
    uint256 public unpaidCarryLiquidations;
    uint256 public positivePnlLiquidations;
    uint256 public immediateLiquidationPayouts;
    uint256 public deferredLiquidationPayouts;
    uint256 public liquidationCarryWaived;
    uint256 public liquidationPriceWrittenOff;
    uint256 public liquidationClaimsConsumed;
    uint256 public healthyLiquidationRejections;
    uint256 public refundedHealthyLiquidations;
    uint256[3] public liquidationPayoutBoundaries;
    uint256 public negativeVpiLiquidations;
    uint256 public liquidationPendingMarginConsumed;
    LiquidationReferenceMath.Values internal lastLiquidation;

    uint256 public rejectedWithdrawals;
    uint256[4] public generations;
    bool public frozen;

    constructor(
        MockUSDC usdc_,
        MockPyth pyth_,
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        HousePool pool_,
        TrancheVault junior_,
        TrancheVault senior_,
        OrderRouter router_,
        address owner_
    ) {
        usdc = usdc_;
        pyth = pyth_;
        engine = engine_;
        clearinghouse = clearinghouse_;
        pool = pool_;
        junior = junior_;
        senior = senior_;
        router = router_;
        owner = owner_;
        seedOwner = owner_;
        expectedCouponTime = vm.getBlockTimestamp();
        currentMarkTime = vm.getBlockTimestamp();
        latestAuthoredTick = HistoricalTick({
            componentPrice: 1e8, publishTime: vm.getBlockTimestamp(), previousPublishTime: 0, available: true
        });
        carry = new CarryReferenceLedger(expectedPoolCash, vm.getBlockTimestamp(), 500);
        orders = new PendingOrderReferenceLedger();
        vm.deal(address(this), 100_000 ether);
        vm.deal(KEEPER, 100_000 ether);
        for (uint256 i; i < 4; ++i) {
            address account = actorAt(i);
            vm.deal(account, 100_000 ether);
            usdc.mint(account, INITIAL_CASH);
            vm.startPrank(account);
            usdc.approve(address(clearinghouse), type(uint256).max);
            clearinghouse.deposit(account, INITIAL_CASH);
            vm.stopPrank();
            traders[i].cash = INITIAL_CASH;
            carry.initializeFlatAccount(account, INITIAL_CASH, 0, vm.getBlockTimestamp());
        }
    }

    function actorAt(
        uint256 i
    ) public pure returns (address) {
        return address(uint160(0xAA7710 + i));
    }

    function lpAt(
        uint256 i
    ) public pure returns (address) {
        return address(uint160(0xAA7720 + i));
    }

    function traderState(
        uint256 i
    ) external view returns (Trader memory) {
        return traders[i];
    }

    function lpState(
        uint256 i
    ) external view returns (Lp memory) {
        return lps[i];
    }

    function openOrIncrease(
        uint256 actorSeed,
        uint256 lotsSeed,
        uint256 priceSeed
    ) external {
        if (frozen) {
            return;
        }
        uint256 i = actorSeed % 4;
        if (traders[i].lots >= 500) {
            return;
        }
        uint256 lots = bound(lotsSeed, 17, 500);
        if (lots > 500 - traders[i].lots) {
            lots = 500 - traders[i].lots;
        }
        uint256 price = bound(priceSeed, 80_000_001, 120_000_003);
        // Margin comfortably covers the independently bounded mark domain while leaving LP-backed carry exposure.
        uint256 contribution = lots * 60e6;
        _ensurePledge(i, traders[i].lots * 60e6);
        if (_free(i) < contribution + 1e6) {
            _deposit(i, contribution + 1000e6);
        }
        _refresh(price);
        _trade(i, lots, contribution, false);
        assertModel();
    }

    function close(
        uint256 actorSeed,
        uint256 lotsSeed,
        bool full
    ) external {
        uint256 i = actorSeed % 4;
        uint256 existing = traders[i].lots;
        if (existing == 0) {
            return;
        }
        uint256 lots = full ? existing : bound(lotsSeed, 1, existing);
        if (!frozen) {
            // Healthy partial closes test basis proration without borrowing production risk admission as an oracle.
            uint256 price = traders[i].basis / existing;
            price = price > 100_000_000 ? price - 3_000_001 : price + 3_000_001;
            _refresh(price);
        }
        if (lots < existing) {
            // Intentional successful partials fund their selected price envelope using actual collateral actions.
            // The separate deferred-claim history directly exercises zero-pledge claim-backed partial admission.
            _ensurePledge(i, existing * (frozen ? CAP : 5e6));
        }
        if (_free(i) < 10e6) {
            _deposit(i, 100e6);
        }
        _trade(i, lots, 0, true);
        assertModel();
    }

    function advanceAndCheckpoint(
        uint256 secondsSeed
    ) external {
        // Advance real elapsed seconds. Skip the known Friday-noon through Sunday calendar band to Monday noon;
        // this deliberately selects a live action without asking production which classifications would succeed.
        vm.warp(_nextLiveTime(vm.getBlockTimestamp() + bound(secondsSeed, 1, 6 hours)));
        frozen = false;
        assertFalse(engine.isOracleFrozen(), "independently selected live calendar");
        engine.checkpointCarryIndexes();
        carry.advance(vm.getBlockTimestamp());
        for (uint256 i; i < 4; ++i) {
            if (traders[i].lots != 0) {
                _deposit(i, 1);
            }
        }
        _refresh(currentPrice);
        assertModel();
    }

    function addCollateral(
        uint256 actorSeed,
        uint256 amountSeed
    ) external {
        uint256 i = actorSeed % 4;
        uint256 amount = bound(amountSeed, 1, 100e6);
        _deposit(i, amount);
        if (traders[i].lots != 0) {
            if (amount > _free(i)) {
                bytes32 afterDeposit = _economicFingerprint(i);
                vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
                vm.prank(actorAt(i));
                engine.addMargin(actorAt(i), amount);
                assertEq(_economicFingerprint(i), afterDeposit, "rejected margin add preserves accepted deposit");
                ++rejectedMarginAdds;
                assertModel();
                return;
            }
            _collect(i);
            vm.prank(actorAt(i));
            engine.addMargin(actorAt(i), amount);
            traders[i].margin += amount;
            _apply(i);
        }
        assertModel();
    }

    function freezeOrThaw(
        bool enterFrozen
    ) external {
        uint256 today = vm.getBlockTimestamp() / 1 days;
        uint256 targetDay = today + ((enterFrozen ? 6 : 1) + 7 - ((today + 4) % 7)) % 7;
        uint256 target = targetDay * 1 days + 12 hours;
        if (target <= vm.getBlockTimestamp()) {
            target += 7 days;
        }
        if (enterFrozen) {
            // Cache a real Friday mark before the FX closure; never enlarge the production stale-mark allowance.
            if (target - 1 days < vm.getBlockTimestamp()) {
                target += 7 days;
            }
            vm.warp(target - 1 days);
            _refresh(currentPrice);
        }
        vm.warp(target);
        frozen = enterFrozen;
        engine.checkpointCarryIndexes();
        carry.advance(vm.getBlockTimestamp());
        for (uint256 i; i < 4; ++i) {
            if (traders[i].lots != 0) {
                _deposit(i, 1);
            }
        }
        if (!frozen) {
            _refresh(currentPrice);
        }
        assertEq(engine.isOracleFrozen(), frozen, "independent calendar selection");
        assertModel();
    }

    function requestJuniorDeposit(
        uint256 lpSeed,
        uint256 amountSeed
    ) external {
        uint256 i = lpSeed % 2;
        Lp storage lp = lps[i];
        // One deposit holding per controller bounds ownership bookkeeping without assuming exit liquidity.
        if (
            lp.pending != 0 || lp.claimAssets != 0 || lp.shares != 0 || lp.pendingRedeemShares != 0
                || lp.claimRedeemShares != 0 || lp.refundableRedeemShares != 0 || frozen
        ) {
            return;
        }
        if (lp.redeemQueued) {
            return;
        }
        uint256 amount = bound(amountSeed, 1000e6, 3000e6);
        uint256 epoch = _lpRequestEpoch();
        (uint256 projectedSenior, uint256 projectedJunior, uint256 projectedHwm) = _projectLpCapital();
        bool wiped = projectedJunior == 0;
        bool unavailable = projectedJunior == 0 || projectedSenior < projectedHwm;
        usdc.mint(lpAt(i), amount);
        explicitFunding += amount;
        lp.wallet += amount;
        vm.startPrank(lpAt(i));
        usdc.approve(address(junior), amount);
        if (wiped || unavailable) {
            vm.expectRevert(
                wiped
                    ? TrancheVault.TrancheVault__TerminallyWiped.selector
                    : TrancheVault.TrancheVault__DepositsUnavailable.selector
            );
            junior.requestDeposit(amount, lpAt(i), lpAt(i));
            vm.stopPrank();
            ++lpDepositRejections;
            assertModel();
            return;
        }
        uint256 observedEpoch = junior.requestDeposit(amount, lpAt(i), lpAt(i));
        vm.stopPrank();
        assertEq(observedEpoch, epoch, "independent request cutoff");
        lp.epoch = epoch;
        lp.pending = amount;
        lp.wallet -= amount;
        assertModel();
    }

    function cancelJuniorDeposit(
        uint256 lpSeed
    ) external {
        uint256 i = lpSeed % 2;
        Lp storage lp = lps[i];
        if (lp.pending == 0) {
            return;
        }
        if (vm.getBlockTimestamp() / 1 hours >= lp.epoch) {
            (uint256 projectedSenior, uint256 projectedJunior, uint256 projectedHwm) = _projectLpCapital();
            if (projectedJunior != 0 && projectedSenior >= projectedHwm) {
                return;
            }
        }
        uint256 amount = lp.pending;
        vm.prank(lpAt(i));
        assertEq(junior.cancelPendingDeposit(lp.epoch), amount);
        lp.pending = 0;
        lp.wallet += amount;
        ++lpCancellations;
        assertModel();
    }

    function settleJuniorEpoch(
        bool testHold
    ) external {
        if (frozen) {
            return;
        }
        uint256 epoch;
        for (uint256 i; i < 2; ++i) {
            if (lps[i].pending != 0 && lps[i].epoch > epoch) {
                epoch = lps[i].epoch;
            }
            if (lps[i].pendingRedeemShares != 0 && lps[i].redeemEpoch > epoch) {
                epoch = lps[i].redeemEpoch;
            }
        }
        if (epoch == 0) {
            return;
        }
        uint256 maturity = epoch * 1 hours > vm.getBlockTimestamp() ? epoch * 1 hours : vm.getBlockTimestamp();
        vm.warp(_nextLiveTime(maturity));
        assertFalse(engine.isOracleFrozen(), "independently selected live LP settlement time");
        bytes[] memory data = _prices(currentPrice);
        if (testHold) {
            vm.prank(owner);
            pool.pauseLpEpochSettlement();
            vm.expectRevert(IHousePool.HousePool__LpEpochSettlementPaused.selector);
            router.settleLpEpoch{value: 1}(data);
            ++heldSettlements;
            assertModel();
            vm.prank(owner);
            pool.unpauseLpEpochSettlement();
        }
        if (!_lpSettlementCanProgress()) {
            vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
            router.settleLpEpoch{value: 1}(data);
            ++lpNoProgressRejections;
            for (uint256 i; i < 2; ++i) {
                if (lps[i].pendingRedeemShares != 0) {
                    ++lpUnfundedRedemptions;
                    break;
                }
            }
            assertModel();
            return;
        }
        carry.advance(vm.getBlockTimestamp());
        _reconcile();
        _modelJuniorRedemptions();
        _modelJuniorDeposits();
        router.settleLpEpoch{value: 1}(data);
        currentMarkTime = vm.getBlockTimestamp();
        hasAcceptedMark = true;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        ++lpSettlements;
        assertModel();
    }

    function _modelJuniorDeposits() internal {
        if (expectedJunior == 0 || expectedSenior < expectedHwm) {
            for (uint256 i; i < 2; ++i) {
                if (lps[i].pending != 0) {
                    ++lpDeferredDeposits;
                }
            }
            return;
        }
        uint256 cumulativeAssets;
        uint256 cumulativeShares;
        // Deposit pricing follows redemptions. Each epoch owns the marginal cumulative quote, including escrow dust.
        for (uint256 k; k < 2; ++k) {
            uint256 selected = type(uint256).max;
            for (uint256 i; i < 2; ++i) {
                if (lps[i].pending != 0 && (selected == type(uint256).max || lps[i].epoch < lps[selected].epoch)) {
                    selected = i;
                }
            }
            if (selected == type(uint256).max) {
                break;
            }
            uint256 selectedEpoch = lps[selected].epoch;
            uint256 assets;
            for (uint256 i; i < 2; ++i) {
                if (lps[i].epoch == selectedEpoch) {
                    assets += lps[i].pending;
                }
            }
            cumulativeAssets += assets;
            uint256 totalShares = cumulativeAssets * (expectedJuniorSupply + 1000) / (expectedJunior + 1);
            uint256 shares = totalShares - cumulativeShares;
            cumulativeShares = totalShares;
            uint256 allocated;
            uint256 controllers;
            for (uint256 i; i < 2; ++i) {
                if (lps[i].epoch == selectedEpoch && lps[i].pending != 0) {
                    lps[i].claimAssets = lps[i].pending;
                    lps[i].claimShares = shares * lps[i].pending / assets;
                    allocated += lps[i].claimShares;
                    ++controllers;
                    lps[i].pending = 0;
                }
            }
            uint256 dust = shares - allocated;
            depositEpochDust[selectedEpoch] = LpEpochDust(controllers, dust, vm.getBlockTimestamp());
            expectedDepositDustShares += dust;
        }
        expectedPoolCash += cumulativeAssets;
        expectedAccounted += cumulativeAssets;
        expectedJunior += cumulativeAssets;
        expectedJuniorSupply += cumulativeShares;
    }

    function claimJuniorDeposit(
        uint256 lpSeed
    ) external {
        uint256 i = lpSeed % 2;
        Lp storage lp = lps[i];
        if (lp.claimAssets == 0) {
            return;
        }
        vm.prank(lpAt(i));
        uint256 shares = junior.claimDeposit(lp.epoch, lp.claimAssets, lpAt(i), lpAt(i));
        assertEq(shares, lp.claimShares, "independent epoch share entitlement");
        lp.shares += lp.claimShares;
        lp.claimAssets = 0;
        lp.claimShares = 0;
        ++lpClaims;
        LpEpochDust storage epoch = depositEpochDust[lp.epoch];
        lp.lastDepositTime = epoch.activationTime;
        if (--epoch.remainingControllers == 0) {
            expectedJuniorSupply -= epoch.dust;
            expectedDepositDustShares -= epoch.dust;
            burnedDepositDustShares += epoch.dust;
            epoch.dust = 0;
        }
        assertModel();
    }

    /// @notice Redeem the controller's complete bounded holding after its independently tracked activation cooldown.
    function requestJuniorRedeem(
        uint256 lpSeed
    ) external {
        uint256 i = lpSeed % 2;
        Lp storage lp = lps[i];
        if (
            lp.shares == 0 || lp.pending != 0 || lp.claimAssets != 0 || lp.pendingRedeemShares != 0
                || lp.claimRedeemShares != 0 || lp.refundableRedeemShares != 0 || lp.redeemQueued
                || vm.getBlockTimestamp() < lp.lastDepositTime + 1 hours
        ) {
            return;
        }
        uint256 epoch = _lpRequestEpoch();
        uint256 shares = lp.shares;
        vm.prank(lpAt(i));
        uint256 observedEpoch = junior.requestRedeem(shares, lpAt(i), lpAt(i));
        assertEq(observedEpoch, epoch, "independent redemption cutoff");
        lp.redeemEpoch = epoch;
        lp.pendingRedeemShares = shares;
        lp.shares = 0;
        lp.redeemBasis = shares;
        lp.redeemedShares = 0;
        lp.redeemedAssets = 0;
        lp.refundedShares = 0;
        lp.lastClaimFundingRound = 0;
        lp.redeemQueued = true;
        lp.redeemFundingClaimed = false;
        lp.redeemRefundClaimed = false;
        if (redeemEpochs[epoch].shares == 0) {
            modeledRedeemEpochIds.push(epoch);
        }
        redeemEpochs[epoch].shares += shares;
        ++redeemEpochs[epoch].fundingClaimsRemaining;
        expectedPendingRedeemEscrowShares += shares;
        ++lpRedemptionRequests;
        assertModel();
    }

    function cancelJuniorRedeem(
        uint256 lpSeed
    ) external {
        uint256 i = lpSeed % 2;
        Lp storage lp = lps[i];
        if (lp.pendingRedeemShares == 0 || vm.getBlockTimestamp() / 1 hours >= lp.redeemEpoch) {
            return;
        }
        uint256 shares = lp.pendingRedeemShares;
        vm.prank(lpAt(i));
        assertEq(junior.cancelRedeemRequest(lp.redeemEpoch, lpAt(i)), shares, "exact cancelled redemption shares");
        lp.shares += shares;
        lp.pendingRedeemShares = 0;
        lp.lastDepositTime = vm.getBlockTimestamp();
        redeemEpochs[lp.redeemEpoch].shares -= shares;
        --redeemEpochs[lp.redeemEpoch].fundingClaimsRemaining;
        expectedPendingRedeemEscrowShares -= shares;
        lp.redeemBasis = 0;
        lp.redeemQueued = false;
        ++lpRedemptionCancellations;
        assertModel();
    }

    function _modelJuniorRedemptions() internal {
        uint256 pricingAssets = expectedJunior;
        uint256 pricingSupply = expectedJuniorSupply;
        uint256 budget = _juniorRedemptionBudget(expectedSenior, expectedJunior, expectedHwm);
        uint256 fundedThisPhase;
        for (uint256 k; k < 2; ++k) {
            uint256 selected = type(uint256).max;
            for (uint256 i; i < 2; ++i) {
                if (
                    lps[i].pendingRedeemShares != 0
                        && (selected == type(uint256).max || lps[i].redeemEpoch < lps[selected].redeemEpoch)
                ) {
                    selected = i;
                }
            }
            if (selected == type(uint256).max) {
                break;
            }
            uint256 selectedEpoch = lps[selected].redeemEpoch;
            LpRedeemEpoch storage epoch = redeemEpochs[selectedEpoch];
            uint256 remaining = epoch.shares - epoch.fundedShares;
            uint256 fullAssets = remaining * (pricingAssets + 1) / (pricingSupply + 1000);
            if (fullAssets == 0) {
                // A prior burn can change the next head's value; classify it on the next independent snapshot.
                if (fundedThisPhase != 0) {
                    break;
                }
                epoch.refundable = true;
                epoch.refundClaimsRemaining = epoch.fundingClaimsRemaining;
                _refreshRedeemEntitlements(selectedEpoch);
                continue;
            }
            if (budget == 0) {
                ++lpUnfundedRedemptions;
                break;
            }
            uint256 shares = remaining;
            if (fullAssets > budget) {
                // Search the bounded share domain for the greatest exact floor-quoted amount within cash capacity.
                // This is deliberately independent of production's inverse closed-form redemption solver.
                uint256 low;
                uint256 high = remaining;
                while (low < high) {
                    uint256 middle = low + (high - low + 1) / 2;
                    if (middle * (pricingAssets + 1) / (pricingSupply + 1000) <= budget) {
                        low = middle;
                    } else {
                        high = middle - 1;
                    }
                }
                shares = low;
            }
            uint256 assets = shares * (pricingAssets + 1) / (pricingSupply + 1000);
            if (assets == 0) {
                ++lpUnfundedRedemptions;
                break;
            }
            epoch.fundedShares += shares;
            epoch.fundedAssets += assets;
            ++epoch.fundingRounds;
            expectedPendingRedeemEscrowShares -= shares;
            expectedPoolCash -= assets;
            expectedAccounted -= assets;
            expectedJunior -= assets;
            expectedJuniorSupply -= shares;
            budget -= assets;
            fundedThisPhase += shares;
            _refreshRedeemEntitlements(selectedEpoch);
            ++lpRedemptionSettlements;
            if (shares < remaining) {
                ++lpPartialRedemptions;
                break;
            }
        }
    }

    function _lpSettlementCanProgress() internal view returns (bool) {
        (uint256 projectedSenior, uint256 projectedJunior, uint256 projectedHwm) = _projectLpCapital();
        for (uint256 i; i < 2; ++i) {
            if (lps[i].pending != 0 && projectedJunior != 0 && projectedSenior >= projectedHwm) {
                return true;
            }
        }
        uint256 selected = type(uint256).max;
        for (uint256 i; i < 2; ++i) {
            if (
                lps[i].pendingRedeemShares != 0
                    && (selected == type(uint256).max || lps[i].redeemEpoch < lps[selected].redeemEpoch)
            ) {
                selected = i;
            }
        }
        if (selected == type(uint256).max) {
            return false;
        }
        LpRedeemEpoch storage epoch = redeemEpochs[lps[selected].redeemEpoch];
        uint256 assets = (epoch.shares - epoch.fundedShares) * (projectedJunior + 1) / (expectedJuniorSupply + 1000);
        if (assets == 0) {
            return true; // A zero-value head is processed as a refundable remainder.
        }
        return _juniorRedemptionBudget(projectedSenior, projectedJunior, projectedHwm) != 0;
    }

    function _juniorRedemptionBudget(
        uint256 seniorCapital,
        uint256 juniorCapital,
        uint256 hwm
    ) internal view returns (uint256) {
        uint256[2] memory liabilities;
        for (uint256 i; i < 4; ++i) {
            liabilities[i % 2] += i % 2 == 0 ? traders[i].basis : traders[i].lots * CAP - traders[i].basis;
        }
        uint256 liability = liabilities[0] > liabilities[1] ? liabilities[0] : liabilities[1];
        uint256 reserve = liability + expectedClaims + (liability * 25 + 9999) / 10_000;
        uint256 free = _depth() > reserve ? _depth() - reserve : 0;
        // Fixture governance protects the greater of principal/HWM at a 9999-bps Senior exposure ceiling.
        uint256 seniorExposure = seniorCapital > hwm ? seniorCapital : hwm;
        uint256 requiredJunior = (seniorExposure + 9998) / 9999;
        uint256 ratioBudget = juniorCapital > requiredJunior ? juniorCapital - requiredJunior : 0;
        return free < ratioBudget ? free : ratioBudget;
    }

    function _refreshRedeemEntitlements(
        uint256 epochId
    ) internal {
        LpRedeemEpoch storage epoch = redeemEpochs[epochId];
        uint256 allocatedAssets;
        uint256 allocatedRefunds;
        for (uint256 i; i < 2; ++i) {
            if (lps[i].redeemEpoch == epochId && lps[i].redeemBasis != 0) {
                Lp storage lp = lps[i];
                // Entitlements round once over cumulative funding; claims consume that entitlement without changing basis.
                uint256 entitledShares = lp.redeemBasis * epoch.fundedShares / epoch.shares;
                uint256 entitledAssets = entitledShares == 0 ? 0 : lp.redeemBasis * epoch.fundedAssets / epoch.shares;
                lp.claimRedeemShares = entitledShares - lp.redeemedShares;
                lp.claimRedeemAssets = entitledAssets - lp.redeemedAssets;
                lp.pendingRedeemShares = epoch.refundable ? 0 : lp.redeemBasis - entitledShares;
                allocatedAssets += entitledAssets;
                if (epoch.refundable) {
                    uint256 refund = lp.redeemBasis * (epoch.shares - epoch.fundedShares) / epoch.shares;
                    lp.refundableRedeemShares = lp.redeemRefundClaimed ? 0 : refund - lp.refundedShares;
                    allocatedRefunds += refund;
                }
            }
        }
        expectedRedeemDustAssets = expectedRedeemDustAssets - epoch.assetDust + epoch.fundedAssets - allocatedAssets;
        epoch.assetDust = epoch.fundedAssets - allocatedAssets;
        if (epoch.refundable) {
            epoch.refundDust = epoch.shares - epoch.fundedShares - allocatedRefunds;
        }
    }

    /// @notice Claim the currently funded entitlement, including while the epoch remains partly funded.
    function claimJuniorRedeem(
        uint256 lpSeed
    ) external {
        uint256 i = lpSeed % 2;
        Lp storage lp = lps[i];
        if (lp.claimRedeemShares != 0) {
            _claimJuniorRedeemShares(i, lp.claimRedeemShares);
        } else if (lp.claimRedeemAssets != 0) {
            _claimJuniorWithdraw(i, lp.claimRedeemAssets);
        }
        if (redeemEpochs[lp.redeemEpoch].refundable && !lp.redeemRefundClaimed) {
            _claimJuniorRedeemRefund(i);
        }
        assertModel();
    }

    function claimJuniorRedeemShares(
        uint256 lpSeed,
        uint256 amountSeed
    ) external {
        uint256 i = lpSeed % 2;
        _claimJuniorRedeemShares(i, _claimAmount(lps[i].claimRedeemShares, amountSeed));
        assertModel();
    }

    function claimJuniorWithdraw(
        uint256 lpSeed,
        uint256 amountSeed
    ) external {
        uint256 i = lpSeed % 2;
        _claimJuniorWithdraw(i, _claimAmount(lps[i].claimRedeemAssets, amountSeed));
        assertModel();
    }

    function claimJuniorRedeemRefund(
        uint256 lpSeed
    ) external {
        _claimJuniorRedeemRefund(lpSeed % 2);
        assertModel();
    }

    function _claimAmount(
        uint256 available,
        uint256 seed
    ) internal pure returns (uint256) {
        uint256 choice = seed % 5;
        if (choice == 0) {
            return 0;
        }
        if (choice == 1) {
            return 1;
        }
        if (choice == 2) {
            return available / 2;
        }
        if (choice == 3) {
            return available;
        }
        return available + 1;
    }

    function _claimJuniorRedeemShares(
        uint256 i,
        uint256 shares
    ) internal {
        Lp storage lp = lps[i];
        if (shares == 0 || shares > lp.claimRedeemShares) {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "ERC4626ExceededMaxRedeem(address,uint256,uint256)", lpAt(i), shares, lp.claimRedeemShares
                )
            );
            vm.prank(lpAt(i));
            junior.claimRedeem(lp.redeemEpoch, shares, lpAt(i), lpAt(i));
            ++lpClaimRejections;
            return;
        }
        uint256 assets = shares == lp.claimRedeemShares
            ? lp.claimRedeemAssets
            : shares * lp.claimRedeemAssets / lp.claimRedeemShares;
        vm.prank(lpAt(i));
        assertEq(
            junior.claimRedeem(lp.redeemEpoch, shares, lpAt(i), lpAt(i)), assets, "independent per-call share floor"
        );
        _consumeJuniorClaim(i, shares, assets);
        ++lpShareClaims;
    }

    function _claimJuniorWithdraw(
        uint256 i,
        uint256 assets
    ) internal {
        Lp storage lp = lps[i];
        uint256 shares;
        bool rejected = assets == 0 || assets > lp.claimRedeemAssets;
        if (!rejected) {
            shares = assets == lp.claimRedeemAssets
                ? lp.claimRedeemShares
                : (assets * lp.claimRedeemShares + lp.claimRedeemAssets - 1) / lp.claimRedeemAssets;
            rejected = assets != lp.claimRedeemAssets && shares >= lp.claimRedeemShares;
        }
        if (rejected) {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "ERC4626ExceededMaxWithdraw(address,uint256,uint256)", lpAt(i), assets, lp.claimRedeemAssets
                )
            );
            vm.prank(lpAt(i));
            junior.withdraw(assets, lpAt(i), lpAt(i));
            ++lpClaimRejections;
            return;
        }
        vm.prank(lpAt(i));
        assertEq(junior.withdraw(assets, lpAt(i), lpAt(i)), shares, "independent per-call asset ceiling");
        _consumeJuniorClaim(i, shares, assets);
        ++lpAssetClaims;
    }

    function _consumeJuniorClaim(
        uint256 i,
        uint256 shares,
        uint256 assets
    ) internal {
        Lp storage lp = lps[i];
        LpRedeemEpoch storage epoch = redeemEpochs[lp.redeemEpoch];
        if (!epoch.refundable && epoch.fundedShares < epoch.shares) {
            ++lpNonterminalClaims;
        }
        if (lp.lastClaimFundingRound != 0 && lp.lastClaimFundingRound < epoch.fundingRounds) {
            ++lpClaimsAfterFurtherFunding;
        }
        lp.lastClaimFundingRound = epoch.fundingRounds;
        lp.redeemedShares += shares;
        lp.redeemedAssets += assets;
        epoch.claimedShares += shares;
        epoch.claimedAssets += assets;
        lp.claimRedeemShares -= shares;
        lp.claimRedeemAssets -= assets;
        lp.wallet += assets;
        _finishRedeemFunding(lp, epoch);
        _closeRedeemPosition(lp, epoch);
        ++lpRedemptionClaims;
    }

    function _claimJuniorRedeemRefund(
        uint256 i
    ) internal {
        Lp storage lp = lps[i];
        LpRedeemEpoch storage epoch = redeemEpochs[lp.redeemEpoch];
        if (!epoch.refundable || lp.redeemRefundClaimed || lp.redeemBasis == 0) {
            vm.expectRevert(TrancheVault.TrancheVault__RedeemRefundUnavailable.selector);
            vm.prank(lpAt(i));
            junior.claimRedeemRefund(lp.redeemEpoch, lpAt(i), lpAt(i));
            ++lpClaimRejections;
            return;
        }
        uint256 shares = lp.refundableRedeemShares;
        vm.prank(lpAt(i));
        assertEq(
            junior.claimRedeemRefund(lp.redeemEpoch, lpAt(i), lpAt(i)), shares, "independent worthless remainder refund"
        );
        if (lp.claimRedeemShares != 0 || lp.claimRedeemAssets != 0) {
            ++lpRefundsBeforeCash;
        } else {
            ++lpRefundsAfterCash;
        }
        if (shares == 0) {
            ++lpZeroShareRefunds;
        }
        lp.shares += shares;
        lp.refundedShares += shares;
        epoch.refundedShares += shares;
        epoch.refundBasisClaimed += lp.redeemBasis;
        expectedPendingRedeemEscrowShares -= shares;
        lp.refundableRedeemShares = 0;
        lp.redeemRefundClaimed = true;
        if (shares != 0) {
            lp.lastDepositTime = vm.getBlockTimestamp();
        }
        _finishRedeemFunding(lp, epoch);
        if (--epoch.refundClaimsRemaining == 0) {
            expectedJuniorSeedShares += epoch.refundDust;
            epoch.refundedShares += epoch.refundDust;
            expectedPendingRedeemEscrowShares -= epoch.refundDust;
            epoch.refundDust = 0;
        }
        _closeRedeemPosition(lp, epoch);
        ++lpRedemptionRefunds;
    }

    function _closeRedeemPosition(
        Lp storage lp,
        LpRedeemEpoch storage epoch
    ) internal {
        if (
            (epoch.refundable || epoch.fundedShares == epoch.shares) && lp.redeemFundingClaimed
                && (!epoch.refundable || lp.redeemRefundClaimed)
        ) {
            lp.redeemQueued = false;
        }
    }

    function _finishRedeemFunding(
        Lp storage lp,
        LpRedeemEpoch storage epoch
    ) internal {
        if (
            lp.redeemFundingClaimed || (!epoch.refundable && epoch.fundedShares != epoch.shares)
                || lp.claimRedeemShares != 0 || lp.claimRedeemAssets != 0
        ) {
            return;
        }
        lp.redeemFundingClaimed = true;
        epoch.fundingBasisClaimed += lp.redeemBasis;
        if (--epoch.fundingClaimsRemaining == 0) {
            epoch.claimedShares = epoch.fundedShares;
            epoch.claimedAssets = epoch.fundedAssets;
            expectedPoolCash += epoch.assetDust;
            expectedRedeemDustAssets -= epoch.assetDust;
            returnedRedemptionDustAssets += epoch.assetDust;
            // Physical dust returns do not reconcile capital or checkpoint Engine carry indexes.
            carry.changeDepthWithoutCheckpoint(_depth());
            epoch.assetDust = 0;
        }
    }

    function _lpRequestEpoch() internal view returns (uint256 epoch) {
        epoch = vm.getBlockTimestamp() / 1 hours + 1;
        if (vm.getBlockTimestamp() >= epoch * 1 hours - 5 minutes) {
            ++epoch;
        }
    }

    function settleClaim(
        uint256 actorSeed
    ) external {
        uint256 i = actorSeed % 4;
        if (traders[i].claim == 0) {
            return;
        }
        _collect(i);
        uint256 amount = traders[i].claim;
        assertGe(expectedPoolCash, expectedClaims, "modeled aggregate claim liquidity");
        vm.prank(actorAt(i));
        engine.settleTraderClaim(actorAt(i));
        traders[i].cash += amount;
        if (traders[i].lots != 0) {
            traders[i].margin += amount;
        }
        traders[i].claim = 0;
        expectedClaims -= amount;
        expectedPoolCash -= amount;
        expectedAccounted -= amount;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        _apply(i);
        ++settledClaims;
        assertModel();
    }

    /// @dev Explicit external raw-cash shock. Accounting claims and canonical stored assets are never fabricated.
    function createDeferredClaimHistory() external {
        if (frozen || traders[0].lots == 0) {
            return;
        }
        _refresh(60_000_001);
        if (_free(0) < 1e6) {
            _deposit(0, 100e6);
        }
        uint256 removed = expectedPoolCash;
        engine.checkpointCarryIndexes();
        carry.advance(vm.getBlockTimestamp());
        usdc.burn(address(pool), removed);
        expectedPoolCash = 0;
        externalShockOut += removed;
        carry.changeDepth(0, vm.getBlockTimestamp());
        _trade(0, traders[0].lots, 0, true);
        // Positive low-depth VPI can absorb the whole gain; the cash allocation model authenticates that path too.
        // Restoration is another explicit environmental input; it does not reset any model expectation.
        usdc.mint(address(pool), removed);
        expectedPoolCash += removed;
        externalShockIn += removed;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        if (engine.degradedMode()) {
            vm.prank(owner);
            engine.clearDegradedMode();
        }
        if (traders[0].claim < 150e6) {
            assertModel();
            return;
        }
        _refresh(80_000_002);
        int256 action = _vpi(0, 100, false) + int256(100 * currentPrice * 4 / 10_000);
        uint256 contribution = (action > 0 ? uint256(action) : 0) + 100 * currentPrice / 1000;
        if (_free(0) < contribution + 1e6) {
            _deposit(0, contribution + 100e6);
        }
        _trade(0, 100, contribution, false);
        assertEq(traders[0].margin, 0, "claim alone backs the reopened position");
        assertEq(traders[0].basis, 100 * currentPrice);
        uint256 claimBefore = traders[0].claim;
        _trade(0, 50, 0, true);
        assertEq(traders[0].margin, 0, "claim alone backs the live partial remainder");
        assertEq(traders[0].basis, 50 * currentPrice);
        assertGt(claimBefore, 50 * currentPrice / 100, "claim-backed equity exceeds maintenance");
        assertEq(traders[0].claim, claimBefore, "claims are health collateral, never action-fee cash");
        ++claimBackedPartialCloses;
        assertModel();
    }

    /// @notice Same-account retained arrears, credit ordering, liquidation, withdrawal, and reusable lifecycle.
    /// @dev Called after the other traders close, while LP ownership and its pending requests remain intact.
    function exerciseArrearsAndReuse() external {
        assertFalse(frozen);
        for (uint256 i; i < 4; ++i) {
            assertEq(traders[i].lots, 0, "arrears prelude starts without old price curves");
        }
        _refresh(120_000_001);
        _trade(3, 100, 300e6, false);
        _withdraw(3, _free(3));
        uint256 removed = expectedPoolCash;
        engine.checkpointCarryIndexes();
        carry.advance(vm.getBlockTimestamp());
        usdc.burn(address(pool), removed);
        expectedPoolCash = 0;
        externalShockOut += removed;
        carry.changeDepth(0, vm.getBlockTimestamp());
        uint256 day = (vm.getBlockTimestamp() + 365 days) / 1 days;
        uint256 monday = day + (8 - ((day + 4) % 7)) % 7;
        vm.warp(monday * 1 days + 12 hours);
        _refresh(120_000_001);
        _deposit(3, 1);
        uint256 arrears = carry.accountState(actorAt(3)).arrears;
        assertGt(arrears, 0, "carry exceeds unprotected collateral");
        assertEq(traders[3].margin, 0, "carry consumes pledge first");
        ++arrearsEpisodes;
        usdc.mint(address(pool), removed);
        expectedPoolCash += removed;
        externalShockIn += removed;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        assertModel();
        vm.prank(actorAt(3));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(actorAt(3), 0);
        ++rejectedWithdrawals;
        assertModel();
        assertTrue(_liquidateAt(3, 60_000_001), "unpaid carry survives until terminal liquidation");
        _withdraw(3, traders[3].cash);
        _rejectExcessWithdrawal(3);
        _deposit(3, 1000e6);
        _refresh(120_000_001);
        _trade(3, 100, 300e6, false);
        assertTrue(_liquidateAt(3, 60_000_001));
        _withdraw(3, traders[3].cash);
        _rejectExcessWithdrawal(3);
        assertEq(generations[3], 2, "same address completes two liquidation generations");
        assertModel();
    }

    /// @notice Both-side liquidation attempts independently classify claims, carry, and exact price equity.
    function liquidateAndReuse(
        uint256 actorSeed
    ) external {
        if (frozen) {
            return;
        }
        uint256 i = actorSeed % 4;
        if (traders[i].lots == 0) {
            if (orders.liveCount() != 0) {
                return; // Preserve pending histories while waiting for the next live generation.
            }
            if (_free(i) < 1000e6) {
                _deposit(i, 1000e6);
            }
            _refresh(i % 2 == 0 ? 80_000_002 : 120_000_002);
            _trade(i, 100, 300e6, false);
        }
        if (_liquidateAt(i, i % 2 == 0 ? 140_000_002 : 60_000_002)) {
            _withdraw(i, traders[i].cash);
            _rejectExcessWithdrawal(i);
        }
        assertModel();
    }

    /// @notice Real claim creation followed by terminal carry, price, and cash-priority histories on either side.
    /// @dev Scenario 0: flat PnL/waiver; 1: price loss; 2: fresh immediate gain; 3: fresh deferred gain;
    /// 4: gain plus waiver; 5: a claim credit leaves stored arrears but restores projected health;
    /// 6: maintenance-only price loss leaves a surviving old claim and unused liquidation reserve;
    /// 7/8/9: free pool cash is respectively one atom below, equal to, or one atom above the fresh payout;
    /// 10: a small new gain replaces negative-VPI backing, which then pays otherwise uncovered carry;
    /// 11: terminal carry consumes protected pending-order margin before releasing its unused remainder.
    /// Environmental cash is restored only after the tested transition, except the explicitly funded immediate
    /// payout/claim-credit branches. No deposit pays the intended unpaid carry before liquidation.
    function exerciseLiquidationHistory(
        uint256 actorSeed,
        uint8 scenario
    ) external {
        uint256 i = actorSeed % 4;
        assertLt(scenario, 12);
        assertFalse(frozen);
        for (uint256 j; j < 4; ++j) {
            assertEq(traders[j].lots, 0, "fixed history starts between live generations");
        }
        uint256 entry = i % 2 == 0 ? 120_000_002 : 80_000_002;
        _refresh(entry);
        if (_free(i) < 6000e6) {
            _deposit(i, 6000e6);
        }
        _trade(i, 100, 5000e6, false);
        _refresh(100_000_002);
        uint256 restoredCash = expectedPoolCash;
        _setLiquidationPoolCash(0);
        _trade(i, 100, 0, true);
        assertGt(traders[i].claim, 1500e6, "public profitable close creates the old claim");
        _setLiquidationPoolCash(expectedPoolCash + restoredCash);
        if (engine.degradedMode()) {
            vm.prank(owner);
            engine.clearDegradedMode();
        }
        _refresh(entry);
        if (scenario == 10) {
            uint256 hedge = i ^ 1;
            if (_free(hedge) < 18_001e6) {
                _deposit(hedge, 18_001e6);
            }
            _trade(hedge, 300, 18_000e6, false);
        }
        if (scenario == 6) {
            int256 action = _vpi(i, 100, false) + int256(100 * currentPrice * 4 / 10_000);
            uint256 contribution = (action > 0 ? uint256(action) : 0) + 100 * currentPrice / 1000;
            _trade(i, 100, contribution, false);
            uint256 desiredLoss = traders[i].claim - 50e6;
            uint256 adverseMove = desiredLoss / 100;
            uint256 adversePrice = i % 2 == 0 ? currentPrice + adverseMove : currentPrice - adverseMove;
            assertGe(adversePrice, 60_000_000);
            assertLe(adversePrice, 140_000_003);
            assertTrue(_liquidateAt(i, adversePrice), "maintenance liquidation leaves a positive old claim");
            assertGt(lastLiquidation.claimConsumed, 0);
            assertGt(lastLiquidation.remainingClaim, 0);
            assertEq(lastLiquidation.carryWaived, 0);
            assertEq(lastLiquidation.writtenOff, 0);
            assertModel();
            return;
        }
        _trade(i, 100, 300e6, false);
        if (scenario == 10) {
            assertLt(traders[i].vpi, 0, "opposing open produces a backed lifetime rebate");
        }
        if (scenario == 11) {
            assertGt(_commitTrade(i, 17, 1020e6, false), 0, "live pending margin predates accrued carry");
            assertEq(orders.margin(i), 1020e6);
        }
        _withdraw(i, _free(i));
        restoredCash = expectedPoolCash;
        _setLiquidationPoolCash(0);
        vm.warp(_nextLiveTime(vm.getBlockTimestamp() + (scenario == 4 ? 10 * 365 days : 365 days)));
        _refresh(entry);
        _deposit(i, 1); // One real atom checkpoints carry; it cannot rescue the independently bounded arrears.
        assertGt(carry.accountState(actorAt(i)).arrears, 0, "real elapsed carry remains uncovered");
        ++arrearsEpisodes;
        uint256 claimBefore = traders[i].claim;
        if (scenario == 2 || scenario == 5) {
            _setLiquidationPoolCash(expectedPoolCash + restoredCash);
            restoredCash = 0;
        }
        if (scenario == 5) {
            this.settleClaim(i);
            assertGt(carry.accountState(actorAt(i)).arrears, 0, "credit preserves arrears until the next collection");
            assertFalse(_liquidateAt(i, entry), "projected claim-backed collection restores health");
        } else {
            uint256 price = scenario == 0 || scenario == 11
                ? entry
                : scenario == 1 ? (i % 2 == 0 ? 140_000_002 : 60_000_002) : 100_000_002;
            if (scenario == 10) {
                uint256 favorableMove = uint256(-traders[i].vpi) / 200;
                assertGt(favorableMove, 2, "VPI replacement gain survives oracle rounding");
                price = i % 2 == 0 ? entry - favorableMove : entry + favorableMove;
            }
            if (scenario >= 7 && scenario <= 9) {
                restoredCash = _fundLiquidationPayoutBoundary(i, scenario, price);
            }
            assertTrue(_liquidateAt(i, price), "intended terminal carry history must liquidate");
            if (scenario >= 7 && scenario <= 9) {
                ++liquidationPayoutBoundaries[scenario - 7];
                if (scenario == 7) {
                    assertEq(lastLiquidation.deferred, lastLiquidation.fresh);
                } else {
                    assertEq(lastLiquidation.immediate, lastLiquidation.fresh);
                }
            }
            if (scenario == 0 || scenario >= 2) {
                assertGe(traders[i].claim, claimBefore, "old claim cannot fund terminal carry");
            }
            if (scenario == 2) {
                assertGt(lastLiquidation.immediate, 0, "fresh immediate gain is reachable");
            }
            if (scenario == 3) {
                assertGt(lastLiquidation.deferred, 0, "fresh deferred gain is reachable");
            }
            if (scenario == 0 || scenario == 4) {
                assertGt(lastLiquidation.carryWaived, 0, "terminal waiver is reachable");
            }
            if (scenario == 10) {
                assertGt(lastLiquidation.vpiWithheld, 0, "gain replaces dedicated VPI backing");
                assertGt(lastLiquidation.vpiConsumed, 0, "unreplaced VPI is recovered from its own reserve");
                assertGt(lastLiquidation.carryCash, 0, "released VPI backing pays carry");
                assertGt(lastLiquidation.carryWaived, 0, "remaining carry is waived without consuming claims");
            }
            if (scenario == 11) {
                assertGt(lastLiquidation.committedConsumed, 0, "terminal carry consumes protected pending margin");
                assertLt(lastLiquidation.committedConsumed, 1020e6, "unused margin returns to free settlement");
                assertEq(orders.count(i), 0, "liquidation authenticates and clears the account queue");
            }
        }
        if (restoredCash != 0) {
            _setLiquidationPoolCash(expectedPoolCash + restoredCash);
        }
        if (engine.degradedMode()) {
            vm.prank(owner);
            engine.clearDegradedMode();
        }
        if (scenario == 10) {
            _trade(i ^ 1, 300, 0, true);
        }
        assertModel();
    }

    function _fundLiquidationPayoutBoundary(
        uint256 i,
        uint8 scenario,
        uint256 price
    ) internal returns (uint256) {
        _refresh(price);
        CarryReferenceLedger.Collection memory projected = carry.previewCheckpoint(actorAt(i), vm.getBlockTimestamp());
        LiquidationReferenceMath.Values memory boundary =
            LiquidationReferenceMath.calculate(_liquidationInput(i, projected));
        assertGt(boundary.fresh, 0, "configured cash boundary requires a positive fresh payout");
        uint256 arriving = projected.fromMargin + projected.fromFree + boundary.pledgeConsumed + boundary.lpFee
            + boundary.vpiConsumed + boundary.carryCash;
        uint256 equalityCash = expectedClaims - boundary.claimConsumed + boundary.fresh - arriving;
        uint256 requestedCash = scenario == 7 ? equalityCash - 1 : scenario == 8 ? equalityCash : equalityCash + 1;
        _setLiquidationPoolCash(requestedCash);
        assertLe(expectedPoolCash, expectedAccounted, "boundary cash does not invent canonical assets");
        return expectedAccounted - expectedPoolCash;
    }

    function lastLiquidationValues() external view returns (LiquidationReferenceMath.Values memory) {
        return lastLiquidation;
    }

    function _setLiquidationPoolCash(
        uint256 nextCash
    ) internal {
        engine.checkpointCarryIndexes();
        carry.advance(vm.getBlockTimestamp());
        if (nextCash < expectedPoolCash) {
            uint256 removed = expectedPoolCash - nextCash;
            usdc.burn(address(pool), removed);
            externalShockOut += removed;
        } else {
            uint256 added = nextCash - expectedPoolCash;
            usdc.mint(address(pool), added);
            externalShockIn += added;
        }
        expectedPoolCash = nextCash;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
    }

    function withdrawFreeCollateral(
        uint256 actorSeed,
        uint256 amountSeed
    ) external {
        uint256 i = actorSeed % 4;
        uint256 available = _free(i);
        if (traders[i].lots != 0 || available == 0) {
            return;
        }
        _withdraw(i, bound(amountSeed, 1, available));
        assertModel();
    }

    function refreshMark(
        uint256 priceSeed
    ) external {
        if (frozen) {
            return;
        }
        _refresh(bound(priceSeed, 60_000_001, 140_000_003));
        assertModel();
    }

    function _maintenanceBps() internal view returns (uint256) {
        (bool fad,) = MarketCalendarReference.status(vm.getBlockTimestamp());
        return fad ? 300 : 100;
    }

    function _liquidationInput(
        uint256 i,
        CarryReferenceLedger.Collection memory projected
    ) internal view returns (LiquidationReferenceMath.Input memory x) {
        Trader storage t = traders[i];
        x.isLong = i % 2 == 0;
        x.lots = t.lots;
        x.basis = t.basis;
        x.price = currentPrice;
        x.pledge = t.margin - projected.fromMargin;
        x.free = _free(i) - projected.fromFree;
        x.cash = t.cash - projected.fromMargin - projected.fromFree;
        x.claim = t.claim;
        x.allClaims = expectedClaims;
        x.poolCash = expectedPoolCash + projected.fromMargin + projected.fromFree;
        x.liquidationReserve = t.liquidationReserve;
        x.vpiClawback = t.vpi < 0 ? uint256(-t.vpi) : 0;
        x.committedMargin = orders.margin(i);
        x.unpaidCarry = projected.unpaid;
        x.maintenanceBps = _maintenanceBps();
    }

    function _liquidateAt(
        uint256 i,
        uint256 price
    ) internal returns (bool) {
        _refresh(price);
        // Reuse the component tick that established the mark; authoring its rounded basket again could advance time.
        bytes[] memory updateData = _tickPayload(latestAuthoredTick);
        uint64[] memory refundedOrders = _refundRiskOffPendingBeforeLiquidation(i);
        CarryReferenceLedger.Collection memory projected = carry.previewCheckpoint(actorAt(i), vm.getBlockTimestamp());
        LiquidationReferenceMath.Values memory values =
            LiquidationReferenceMath.calculate(_liquidationInput(i, projected));
        if (!values.eligible) {
            if (orders.pendingCloseLots(i) != 0) {
                ++pendingCloseHealthyRejections;
            }
            if (refundedOrders.length == 0) {
                vm.prank(KEEPER);
                vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
                router.executeLiquidation{value: 1}(actorAt(i), updateData);
                ++healthyLiquidationRejections;
            } else {
                _startRecordingLogs();
                vm.prank(KEEPER);
                router.executeLiquidation{value: 1}(actorAt(i), updateData);
                _takeRecordedLogs();
                _finishRiskOffLiquidationRefunds(refundedOrders);
                ++refundedHealthyLiquidations;
            }
            assertModel();
            return false;
        }
        _forfeitPendingBounties(i);
        _collect(i);
        // Forfeiture changes cash ownership, never carry eligibility. Rebuild terminal balances from ghost buckets.
        values = LiquidationReferenceMath.calculate(
            _liquidationInput(i, carry.previewCheckpoint(actorAt(i), vm.getBlockTimestamp()))
        );
        Trader storage t = traders[i];
        if (t.claim != 0) {
            ++claimBearingLiquidations;
        }
        if (carry.accountState(actorAt(i)).arrears != 0) {
            ++unpaidCarryLiquidations;
        }
        _startRecordingLogs();
        vm.prank(KEEPER);
        router.executeLiquidation{value: 1}(actorAt(i), updateData);
        _assertLiquidationEvents(i, values, _takeRecordedLogs());
        _finishRiskOffLiquidationRefunds(refundedOrders);
        _consumePendingMargin(i, values.committedConsumed);
        _clearLiquidatedPendingOrders(i);
        uint256 physicalRevenue = values.pledgeConsumed + values.lpFee + values.vpiConsumed + values.carryCash;
        expectedPoolCash = values.poolCashAfter;
        expectedAccounted = expectedAccounted + physicalRevenue - values.immediate;
        expectedKeeper += values.keeper;
        expectedClaims = values.allClaimsAfter;
        carry.settleActionArrears(actorAt(i), values.carryCash, values.carryWithheld, values.carryWaived);
        carryCollected += values.carryCash + values.carryWithheld;
        liquidationCarryWaived += values.carryWaived;
        liquidationPriceWrittenOff += values.writtenOff;
        liquidationClaimsConsumed += values.claimConsumed;
        liquidationPendingMarginConsumed += values.committedConsumed;
        if (values.vpiConsumed + values.vpiWithheld != 0) {
            ++negativeVpiLiquidations;
        }
        if (values.pnl > 0) {
            ++positivePnlLiquidations;
        }
        if (values.immediate != 0) {
            ++immediateLiquidationPayouts;
        }
        if (values.deferred != 0) {
            ++deferredLiquidationPayouts;
        }
        t.cash = values.retainedCash;
        t.claim = values.remainingClaim;
        sideLots[i % 2] -= t.lots;
        t.lots = 0;
        t.basis = 0;
        t.margin = 0;
        t.vpi = 0;
        t.liquidationReserve = 0;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        _apply(i);
        lastLiquidation = values;
        ++liquidations;
        ++liquidationsBySide[i % 2];
        ++generations[i];
        assertModel();
        return true;
    }

    function _assertLiquidationEvents(
        uint256 i,
        LiquidationReferenceMath.Values memory v,
        Vm.Log[] memory logs
    ) internal view {
        uint256 positions;
        uint256 actions;
        uint256 writeoffs;
        address account = actorAt(i);
        for (uint256 j; j < logs.length; ++j) {
            Vm.Log memory entry = logs[j];
            if (entry.topics.length < 2 || entry.topics[1] != bytes32(uint256(uint160(account)))) {
                continue;
            }
            if (
                entry.emitter == address(engine)
                    && entry.topics[0] == keccak256("PositionLiquidated(address,uint8,uint256,uint256,uint256)")
            ) {
                ++positions;
                (uint8 side, uint256 size, uint256 price, uint256 bounty) =
                    abi.decode(entry.data, (uint8, uint256, uint256, uint256));
                assertEq(side, i % 2);
                assertEq(size, traders[i].lots * 1e20);
                assertEq(price, currentPrice);
                assertEq(bounty, v.keeper);
            }
            if (entry.emitter != address(engine.settlementSidecar())) {
                continue;
            }
            if (entry.topics[0] == keccak256("ActionChargeSettled(address,uint256,uint256,uint256)")) {
                ++actions;
                (uint256 assessed, uint256 paid, uint256 waived) = abi.decode(entry.data, (uint256, uint256, uint256));
                uint256 modeled = v.vpiWithheld + v.vpiConsumed + v.carryWithheld + v.carryCash + v.carryWaived;
                assertEq(assessed, modeled, "independent terminal carry and VPI assessment");
                assertEq(paid, modeled - v.carryWaived, "terminal recovery cannot be lost or duplicated");
                assertEq(waived, v.carryWaived, "only independently unreachable carry is waived");
            }
            if (entry.topics[0] == keccak256("PriceLossWrittenOff(address,uint256)")) {
                ++writeoffs;
                assertEq(abi.decode(entry.data, (uint256)), v.writtenOff, "price tail remains diagnostic");
            }
        }
        assertEq(positions, 1, "authenticate exactly one Engine liquidation");
        assertEq(actions, v.vpiWithheld + v.vpiConsumed + v.carryWithheld + v.carryCash + v.carryWaived == 0 ? 0 : 1);
        assertEq(writeoffs, v.writtenOff == 0 ? 0 : 1);
    }

    function _withdraw(
        uint256 i,
        uint256 amount
    ) internal {
        _bookCarry(i, carry.withdraw(actorAt(i), amount, vm.getBlockTimestamp()));
        vm.prank(actorAt(i));
        clearinghouse.withdraw(actorAt(i), amount);
        traders[i].cash -= amount;
        traders[i].wallet += amount;
    }

    function _rejectExcessWithdrawal(
        uint256 i
    ) internal {
        vm.prank(actorAt(i));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        clearinghouse.withdraw(actorAt(i), traders[i].cash + 1);
        ++rejectedWithdrawals;
        assertModel();
    }

    function _ensurePledge(
        uint256 i,
        uint256 target
    ) internal {
        if (traders[i].lots == 0) {
            return;
        }
        // A real one-atom deposit assesses old carry before deciding the fresh collateral contribution.
        _deposit(i, 1);
        uint256 added = target > traders[i].margin ? target - traders[i].margin : 0;
        uint256 arrears = carry.accountState(actorAt(i)).arrears;
        if (_free(i) < added + 10e6 || arrears != 0) {
            _deposit(i, added + arrears + 100e6);
        }
        if (added != 0) {
            vm.prank(actorAt(i));
            engine.addMargin(actorAt(i), added);
            traders[i].margin += added;
            _apply(i);
        }
    }

    function _deposit(
        uint256 i,
        uint256 amount
    ) internal {
        usdc.mint(actorAt(i), amount);
        explicitFunding += amount;
        traders[i].cash += amount;
        // Deposit credits custody before collecting carry; update the independent free bucket before its checkpoint.
        CarryReferenceLedger.Collection memory collection = carry.deposit(actorAt(i), amount, vm.getBlockTimestamp());
        _bookCarry(i, collection);
        vm.prank(actorAt(i));
        clearinghouse.deposit(actorAt(i), amount);
    }

    function _collect(
        uint256 i
    ) internal {
        _bookCarry(i, carry.checkpoint(actorAt(i), vm.getBlockTimestamp()));
    }

    function _bookCarry(
        uint256 i,
        CarryReferenceLedger.Collection memory collection
    ) internal {
        uint256 paid = collection.fromMargin + collection.fromFree;
        traders[i].cash -= paid;
        traders[i].margin -= collection.fromMargin;
        expectedPoolCash += paid;
        expectedAccounted += paid;
        carryCollected += paid;
    }

    function _free(
        uint256 i
    ) internal view returns (uint256) {
        Trader storage t = traders[i];
        return t.cash - t.margin - t.liquidationReserve - (t.vpi < 0 ? uint256(-t.vpi) : 0) - orders.margin(i)
            - orders.bounty(i);
    }

    function _depth() internal view returns (uint256) {
        return expectedPoolCash < expectedAccounted ? expectedPoolCash : expectedAccounted;
    }

    function _apply(
        uint256 i
    ) internal {
        Trader storage t = traders[i];
        uint256 maxProfit = i % 2 == 0 ? t.basis : t.lots * CAP - t.basis;
        carry.applyPosition(
            actorAt(i),
            uint8(i % 2),
            maxProfit,
            t.margin,
            _free(i),
            t.liquidationReserve + (t.vpi < 0 ? uint256(-t.vpi) : 0) + orders.margin(i) + orders.bounty(i),
            t.lots != 0,
            vm.getBlockTimestamp()
        );
    }

    function _isFadReference(
        uint256 timestamp
    ) internal pure returns (bool) {
        (bool fad,) = MarketCalendarReference.status(timestamp);
        return fad;
    }

    function _nextLiveTime(
        uint256 target
    ) internal pure returns (uint256) {
        uint256 day = target / 1 days;
        uint256 weekday = (day + 4) % 7;
        if (weekday == 0 || weekday == 6 || (weekday == 5 && target % 1 days >= 12 hours)) {
            return (day + (8 - weekday) % 7) * 1 days + 12 hours;
        }
        return target;
    }

    function _prices(
        uint256 price
    ) internal returns (bytes[] memory data) {
        // One timestamp identifies one authored component tick. A new price at the same timestamp needs a
        // later publication; otherwise a mock could invent two contradictory "first after commitment" ticks.
        if (
            latestAuthoredTick.available && vm.getBlockTimestamp() == latestAuthoredTick.publishTime
                && 2 * (price / 2) != 2 * (latestAuthoredTick.componentPrice / 2)
        ) {
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        if (!latestAuthoredTick.available || vm.getBlockTimestamp() > latestAuthoredTick.publishTime) {
            latestAuthoredTick = HistoricalTick({
                componentPrice: price,
                publishTime: vm.getBlockTimestamp(),
                previousPublishTime: latestAuthoredTick.publishTime,
                available: true
            });
        }
        uint64[] memory ids = orders.liveIds();
        for (uint256 j; j < ids.length; ++j) {
            uint64 id = ids[j];
            if (historicalOrderTicks[id].available) {
                continue;
            }
            uint256 committedAt = orders.order(id).commitTime;
            if (
                latestAuthoredTick.publishTime > committedAt && latestAuthoredTick.publishTime <= committedAt + 15
                    && latestAuthoredTick.previousPublishTime <= committedAt
            ) {
                historicalOrderTicks[id] = latestAuthoredTick;
            }
        }
        return _tickPayload(latestAuthoredTick);
    }

    function _historicalOrderTick(
        uint64 id
    ) internal view returns (HistoricalTick memory) {
        return historicalOrderTicks[id];
    }

    function _executionPrice(
        uint64 id
    ) internal view returns (uint256 price, bool available) {
        HistoricalTick memory tick = historicalOrderTicks[id];
        // Both equal-weight components independently floor their contribution to the eight-decimal basket.
        return (2 * (tick.componentPrice / 2), tick.available);
    }

    function _orderPrices(
        uint64 id
    ) internal view returns (bytes[] memory) {
        HistoricalTick memory tick = historicalOrderTicks[id];
        // A missing historical tick submits the actually authored latest data. The real oracle then rejects
        // its publication interval; no past price or prior-publication proof is fabricated to make it execute.
        return _tickPayload(tick.available ? tick : latestAuthoredTick);
    }

    function _batchOrderPrices(
        uint64[] memory ids
    ) internal view returns (bytes[] memory data) {
        uint256 available;
        for (uint256 j; j < ids.length; ++j) {
            if (historicalOrderTicks[ids[j]].available) {
                ++available;
            }
        }
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](2 * (available + 1));
        uint256 cursor;
        for (uint256 j; j < ids.length; ++j) {
            HistoricalTick memory tick = historicalOrderTicks[ids[j]];
            if (!tick.available) {
                continue;
            }
            _writeTick(updates, cursor, tick);
            cursor += 2;
        }
        _writeTick(updates, cursor, latestAuthoredTick);
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

    function _tickPayload(
        HistoricalTick memory tick
    ) internal pure returns (bytes[] memory data) {
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](2);
        _writeTick(updates, 0, tick);
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

    function _writeTick(
        MockPyth.FeedUpdate[] memory updates,
        uint256 offset,
        HistoricalTick memory tick
    ) internal pure {
        for (uint256 component; component < 2; ++component) {
            updates[offset + component] = MockPyth.FeedUpdate({
                id: bytes32(component + 1),
                price: MockPyth.MockPrice({
                    price: int64(int256(tick.componentPrice)),
                    conf: 0,
                    expo: -8,
                    publishTime: tick.publishTime,
                    prevPublishTime: tick.previousPublishTime
                })
            });
        }
    }

    function _refresh(
        uint256 price
    ) internal {
        router.updateMarkPrice{value: 1}(_prices(price));
        carry.advance(vm.getBlockTimestamp());
        currentPrice = 2 * (price / 2);
        currentMarkTime = vm.getBlockTimestamp();
        hasAcceptedMark = true;
    }

    /// @notice Leave an independently funded open/increase pending across later campaign actions.
    function commitOpen(
        uint256 actorSeed,
        uint256 lotsSeed,
        uint256 priceSeed
    ) public {
        if (frozen) {
            return;
        }
        uint256 i = actorSeed % 4;
        if (orders.count(i) == 5) {
            return;
        }
        uint256 projected = orders.queuedLots(i, traders[i].lots, riskOffCutoff);
        if (projected >= 500) {
            return;
        }
        uint256 lots = bound(lotsSeed, 17, 500);
        if (lots > 500 - projected) {
            lots = 500 - projected;
        }
        uint256 contribution = lots * 60e6;
        _ensurePledge(i, traders[i].lots * 60e6);
        if (_free(i) < contribution + 1e6) {
            _deposit(i, contribution + 1000e6);
        }
        _refresh(bound(priceSeed, 80_000_001, 120_000_003));
        _commitTrade(i, lots, contribution, false);
        assertModel();
    }

    function commitClose(
        uint256 actorSeed,
        uint256 lotsSeed,
        bool full
    ) public {
        uint256 i = actorSeed % 4;
        if (orders.count(i) == 5 || traders[i].lots == 0) {
            return;
        }
        uint256 projected = orders.queuedLots(i, traders[i].lots, riskOffCutoff);
        if (projected == 0) {
            return;
        }
        uint256 lots = full ? projected : bound(lotsSeed, 1, projected);
        if (lots < traders[i].lots) {
            _ensurePledge(i, traders[i].lots * 60e6);
        }
        if (_free(i) < 1e6) {
            _deposit(i, 1e6);
        }
        _commitTrade(i, lots, 0, true);
        assertModel();
    }

    function commitZeroFreeClose(
        uint256 actorSeed,
        bool full
    ) public {
        uint256 i = actorSeed % 4;
        if (traders[i].lots == 0 || orders.count(i) != 0 || (!full && traders[i].lots < 2)) {
            return;
        }
        if (!frozen) {
            _refresh(currentPrice);
        }
        CarryReferenceLedger.Collection memory projected = carry.previewCheckpoint(actorAt(i), vm.getBlockTimestamp());
        uint256 available = _free(i) - projected.fromFree;
        if (available != 0) {
            if (_rejectPledgePreparationWithdrawal(i, available, projected)) {
                return;
            }
            _withdraw(i, available);
        }
        uint256 lots = full ? traders[i].lots : traders[i].lots / 2;
        _commitTrade(i, lots, 0, true);
        assertModel();
    }

    /// @dev A generated zero-free close commitment must first remove only withdrawable free collateral. An
    /// underwater position or unpaid carry rejects that preparation; classify and prove rollback explicitly.
    function _rejectPledgePreparationWithdrawal(
        uint256 i,
        uint256 amount,
        CarryReferenceLedger.Collection memory projected
    ) internal returns (bool) {
        Trader memory t = traders[i];
        int256 pnl = int256(t.basis) - int256(t.lots * currentPrice);
        if (i % 2 != 0) {
            pnl = -pnl;
        }
        uint256 requiredBps = _maintenanceBps();
        if (requiredBps < 150) {
            requiredBps = 150;
        }
        if (
            projected.unpaid == 0
                && int256(t.margin - projected.fromMargin + t.claim) + pnl
                    > int256(t.lots * currentPrice * requiredBps / 10_000)
        ) {
            return false;
        }
        bytes32 beforeState = _economicFingerprint(i);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(actorAt(i));
        clearinghouse.withdraw(actorAt(i), amount);
        assertEq(_economicFingerprint(i), beforeState, "unhealthy withdrawal preparation rolls back carry");
        ++rejectedWithdrawals;
        assertModel();
        return true;
    }

    function rejectReservedWithdrawal(
        uint256 actorSeed
    ) public {
        uint256 i = actorSeed % 4;
        if (traders[i].lots != 0 || orders.margin(i) + orders.bounty(i) == 0) {
            return;
        }
        uint256 amount = _free(i) + 1;
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        vm.prank(actorAt(i));
        clearinghouse.withdraw(actorAt(i), amount);
        ++rejectedWithdrawals;
        assertModel();
    }

    function _intentHash(
        uint256 i,
        OrderV3Types.OrderRequest memory request
    ) internal view returns (bytes32) {
        bytes32 tag = keccak256(
            "PletherOrderIntentV3(uint256 chainId,address router,address account,bytes32 clientOrderId,uint8 side,uint256 sizeDelta,uint256 marginDelta,uint256 targetPrice,bool isClose,uint64 submitBy,uint32 executionWindowSeconds,uint8 allowedExecutionModes,bytes32 expectedConfigHash,uint256 maxExecutionBountyUsdc,uint256 maxExecutionNotionalUsdc,uint256 maxGrossAccountDebitUsdc,uint256 maxActionChargeUsdc,uint256 maxExplicitFeesUsdc,uint256 maxPostPositionSize,uint256 minPostSettlementBalanceUsdc,uint256 minPostPositionEquityUsdc,uint32 maxPostLeverageBps)"
        );
        return keccak256(abi.encode(tag, block.chainid, address(router), actorAt(i), request));
    }

    function _orderRequest(
        uint256 i,
        uint256 lots,
        uint256 contribution,
        bool isClose
    ) internal returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = bytes32(++nonce);
        request.side = CfdTypes.Side(i % 2);
        request.sizeDelta = lots * 1e20;
        request.marginDelta = contribution;
        request.isClose = isClose;
        request.targetPrice = (isClose == (i % 2 == 0)) ? CAP : 1;
        request.bounds = OrderV3Types.ExecutionBounds(
            uint64(vm.getBlockTimestamp() + 60),
            60,
            7,
            router.lifecycleBook().currentExecutionConfigHash(),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            0,
            0,
            type(uint32).max
        );
    }

    function _commitTrade(
        uint256 i,
        uint256 lots,
        uint256 contribution,
        bool isClose
    ) internal returns (uint64 id) {
        OrderV3Types.OrderRequest memory request = _orderRequest(i, lots, contribution, isClose);
        if (lots == 0) {
            // Explicit zero-size probes reach base validation before minimum notional.
            _rejectCommit(i, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ZeroSize.selector));
            ++rejectedSmallOrders;
            return 0;
        }
        if (!isClose && _isFadReference(vm.getBlockTimestamp())) {
            _rejectCommit(i, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CloseOnlyWindow.selector));
            ++rejectedCloseOnlyCommits;
            return 0;
        }
        uint256 queuedLots = orders.queuedLots(i, traders[i].lots, riskOffCutoff);
        bool belowMinimum = isClose ? lots < queuedLots && lots * currentPrice < 1000e6 : lots * currentPrice < 100e6;
        if (belowMinimum) {
            vm.prank(actorAt(i));
            vm.expectRevert(
                abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CommitValidation.selector, uint8(11))
            );
            router.commitOrder(request);
            ++rejectedSmallOrders;
            return 0;
        }
        uint256 bounty = isClose ? 0 : lots * currentPrice / 10_000;
        if (bounty > 200_000) {
            bounty = 200_000;
        }
        if (!isClose && bounty < 10_000) {
            bounty = 10_000;
        }
        if (isClose) {
            bytes memory rejection = _closeCommitFailure(i, lots);
            if (rejection.length != 0) {
                _rejectCommit(i, request, rejection);
                ++rejectedCloseCommitments;
                if (lots > traders[i].lots) {
                    ++rejectedQueuedCloseSize;
                }
                return 0;
            }
        }
        if (!isClose && _rejectOpenCommitIfInvalid(i, request)) {
            return 0;
        }
        uint256 beforeCash = traders[i].cash;
        _collect(i);
        if (isClose && _free(i) == 0) {
            ++zeroFreeCloseOrders;
        }
        if (isClose && orders.count(i) != 0) {
            ++closesBehindPendingOrders;
        }
        assertLe(bounty, _free(i), "opening bounty is entirely free funded");
        uint256 freePart = bounty;
        uint256 pledgePart = 0;
        carry.reserveWithoutCheckpoint(actorAt(i), bounty);
        carry.reserveWithoutCheckpoint(actorAt(i), contribution);
        id = orders.commit(
            i, positionEpochs[i], request, freePart, pledgePart, vm.getBlockTimestamp(), vm.getBlockNumber()
        );
        committedCarry[id] = beforeCash - traders[i].cash;
        vm.prank(actorAt(i));
        assertEq(router.commitOrder(request), id, "independent monotonic order id");
        ++orderCommits;
        if (orders.liveCount() > 1) {
            ++overlappingCommits;
        }
        if (orders.liveCount() > maximumLiveOrders) {
            maximumLiveOrders = orders.liveCount();
        }
        _assertLiveOrder(id);
    }

    function _rejectOpenCommitIfInvalid(
        uint256 i,
        OrderV3Types.OrderRequest memory request
    ) internal returns (bool) {
        CarryReferenceLedger.Collection memory projected = carry.previewCheckpoint(actorAt(i), vm.getBlockTimestamp());
        uint8 code = _projectOpen(i, request.sizeDelta / 1e20, request.marginDelta, projected).revertCode;
        if (code == 0) {
            return false;
        }
        _rejectCommit(
            i, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector, code)
        );
        ++rejectedOpenCommitments;
        return true;
    }

    function _rejectCommit(
        uint256 i,
        OrderV3Types.OrderRequest memory request,
        bytes memory rejection
    ) internal {
        bytes32 beforeState = _economicFingerprint(i);
        vm.expectRevert(rejection);
        vm.prank(actorAt(i));
        router.commitOrder(request);
        assertEq(_economicFingerprint(i), beforeState, "classified commitment rollback");
        assertEq(router.lifecycleBook().clientIntent(actorAt(i), request.clientOrderId).orderId, 0);
    }

    function _closeCommitFailure(
        uint256 i,
        uint256 lots
    ) internal view returns (bytes memory) {
        Trader memory t = traders[i];
        if (t.lots == 0) {
            return abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__NoOpenPosition.selector);
        }
        if (lots > t.lots) {
            return abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__CloseSizeExceedsPosition.selector);
        }
        CarryReferenceLedger.Collection memory c = carry.previewCheckpoint(actorAt(i), vm.getBlockTimestamp());
        uint256 pledge = t.margin - c.fromMargin;
        if (lots == t.lots) {
            return new bytes(0);
        }
        if (c.unpaid != 0) {
            return abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__PartialCloseCarryUnfunded.selector, c.unpaid);
        }
        int256 pnl = int256(t.basis) - int256(t.lots * currentPrice);
        if (i % 2 != 0) {
            pnl = -pnl;
        }
        if (int256(pledge + t.claim) + pnl <= int256(t.lots * currentPrice * _maintenanceBps() / 10_000)) {
            return abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy.selector);
        }
        return new bytes(0);
    }

    /// @dev Existing scenario conveniences still use the exact split-action ledger and FIFO dispatcher.
    function _trade(
        uint256 i,
        uint256 lots,
        uint256 contribution,
        bool isClose
    ) internal {
        uint64 id = _commitTrade(i, lots, contribution, isClose);
        if (id == 0) {
            return;
        }
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        while (orders.liveCount() != 0 && orders.head() <= id) {
            uint64 beforeHead = orders.head();
            _executeHead(false);
            if (orders.liveCount() != 0 && orders.head() == beforeHead) {
                break;
            }
        }
    }

    function executeHead(
        bool selfExecute
    ) public {
        if (orders.liveCount() == 0) {
            return;
        }
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        _executeHead(selfExecute);
        assertModel();
    }

    function _executeHead(
        bool selfExecute
    ) internal {
        PendingOrderReferenceLedger.Order memory o = orders.order(orders.head());
        address executor = selfExecute ? actorAt(o.actorIndex) : KEEPER;
        OrderV3Types.TerminalReason reason = _preOracleReason(o);
        bytes[] memory data;
        if (reason == OrderV3Types.TerminalReason.None) {
            bytes[] memory liveData = _prices(currentPrice);
            data = frozen ? liveData : _orderPrices(o.id);
            if (!_prepareExpectedOrderOracle(o.id)) {
                _expectMissingHistoricalPrice(o, executor, data);
                return;
            }
            if (_isFadReference(vm.getBlockTimestamp()) && !o.request.isClose) {
                vm.prank(executor);
                OrderV3Types.ExecutionResult memory pending = router.executeOrder{value: 1}(o.id, data);
                assertEq(uint8(pending.status), uint8(OrderV3Types.LifecycleStatus.Pending));
                assertEq(uint8(pending.pendingReason), uint8(OrderV3Types.PendingReason.CloseOnly));
                ++pendingCloseOnlyResults;
                return;
            }
        } else {
            data = new bytes[](0);
        }
        uint256 acceptedMark = currentPrice;
        if (reason == OrderV3Types.TerminalReason.None) {
            currentPrice = expectedExecutionPrices[o.id];
            reason = _expectedOrderReason(o);
        }
        _releasePendingMargin(o.id);
        uint8 code;
        if (reason == OrderV3Types.TerminalReason.Executed) {
            code = _expectedOrderCode(o);
            if (code != 0) {
                reason = OrderV3Types.TerminalReason.PlannerRejected;
            } else {
                _modelExecutedOrder(o);
            }
        }
        _modelTerminalBounty(o.id, reason, executor);
        currentPrice = acceptedMark;
        _startRecordingLogs();
        vm.prank(executor);
        OrderV3Types.ExecutionResult memory result = router.executeOrder{value: data.length == 0 ? 0 : 1}(o.id, data);
        OrderV3Types.LifecycleStatus status = reason == OrderV3Types.TerminalReason.Executed
            ? OrderV3Types.LifecycleStatus.Executed
            : OrderV3Types.LifecycleStatus.Failed;
        assertEq(result.orderId, o.id);
        assertEq(uint8(result.status), uint8(status), "independently classified order status");
        assertEq(uint8(result.terminalReason), uint8(reason), "independently classified terminal reason");
        _finishPendingOrder(o, status, reason, executor, code);
    }

    function _preOracleReason(
        PendingOrderReferenceLedger.Order memory o
    ) internal view returns (OrderV3Types.TerminalReason) {
        if (!o.request.isClose && o.id <= riskOffCutoff) {
            return OrderV3Types.TerminalReason.RiskOff;
        }
        if (vm.getBlockTimestamp() > o.deadline) {
            return OrderV3Types.TerminalReason.Expired;
        }
        return OrderV3Types.TerminalReason.None;
    }

    function _prepareExpectedOrderOracle(
        uint64 id
    ) internal returns (bool) {
        if (frozen) {
            expectedExecutionPrices[id] = currentPrice;
            expectedExecutionTimes[id] = latestAuthoredTick.publishTime;
            currentMarkTime = vm.getBlockTimestamp();
            hasAcceptedMark = true;
            carry.advance(vm.getBlockTimestamp());
            return true;
        }
        (uint256 price, bool available) = _executionPrice(id);
        if (!available) {
            return false;
        }
        expectedExecutionPrices[id] = price;
        HistoricalTick memory tick = _historicalOrderTick(id);
        expectedExecutionTimes[id] = tick.publishTime;
        if (tick.publishTime >= currentMarkTime) {
            currentPrice = price;
            currentMarkTime = tick.publishTime;
            hasAcceptedMark = true;
            carry.advance(vm.getBlockTimestamp());
        }
        return true;
    }

    function _expectMissingHistoricalPrice(
        PendingOrderReferenceLedger.Order memory o,
        address executor,
        bytes[] memory data
    ) internal {
        uint256 lastValid = uint256(o.commitTime) + 15;
        if (lastValid > vm.getBlockTimestamp()) {
            lastValid = vm.getBlockTimestamp();
        }
        bytes32 beforeState = _economicFingerprint(o.actorIndex);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPletherOracle.PletherOracle__StalePrice.selector,
                IPletherOracle.PriceMode.OrderExecution,
                bytes32(0),
                lastValid,
                uint256(60),
                vm.getBlockTimestamp()
            )
        );
        vm.prank(executor);
        router.executeOrder{value: 1}(o.id, data);
        assertEq(_economicFingerprint(o.actorIndex), beforeState, "unavailable history preserves economic state");
        ++historicalPriceRejections;
    }

    function _modelTerminalBounty(
        uint64 id,
        OrderV3Types.TerminalReason reason,
        address executor
    ) internal {
        if (reason == OrderV3Types.TerminalReason.RiskOff) {
            PendingOrderReferenceLedger.Order memory o = orders.order(id);
            carry.releaseProtectedWithoutCheckpoint(actorAt(o.actorIndex), orders.takeBounty(id));
            ++riskOffOrders;
        } else {
            PendingOrderReferenceLedger.Order memory o = orders.order(id);
            if (o.request.isClose && reason != OrderV3Types.TerminalReason.Executed) {
                assertEq(o.bountyUsdc, 0);
                ++unpaidFailedCloses;
                ++unpaidFailureTransitions;
                _modelBountyPayment(id, executor, o.bountyFree);
            } else {
                _modelBountyPayment(id, executor, o.bountyUsdc);
            }
        }
    }

    function _expectedOrderReason(
        PendingOrderReferenceLedger.Order memory o
    ) internal view returns (OrderV3Types.TerminalReason) {
        bool upward = o.request.isClose != (o.actorIndex % 2 == 0);
        bool accepts = upward ? currentPrice >= o.request.targetPrice : currentPrice <= o.request.targetPrice;
        return accepts ? OrderV3Types.TerminalReason.Executed : OrderV3Types.TerminalReason.Slippage;
    }

    function _expectedOrderCode(
        PendingOrderReferenceLedger.Order memory o
    ) internal view returns (uint8) {
        uint256 i = o.actorIndex;
        uint256 lots = o.request.sizeDelta / 1e20;
        if (o.request.isClose && lots > traders[i].lots) {
            return 1;
        }
        CarryReferenceLedger.Collection memory c = carry.previewCheckpoint(actorAt(i), vm.getBlockTimestamp());
        if (o.request.isClose) {
            return _projectClose(i, lots, c).revertCode;
        }
        return _projectOpen(i, lots, o.request.marginDelta, c).revertCode;
    }

    function _modelExecutedOrder(
        PendingOrderReferenceLedger.Order memory o
    ) internal {
        uint256 i = o.actorIndex;
        if (o.request.isClose) {}
        _collect(i);
        uint256 lots = o.request.sizeDelta / 1e20;
        int256 vpi = _vpi(i, lots, o.request.isClose);
        if (o.request.isClose) {
            _bookClose(i, lots, vpi);
        } else {
            _bookOpen(i, lots, o.request.marginDelta, vpi);
        }
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        _apply(i);
        if (vm.getBlockTimestamp() > o.commitTime + 1) {
            ++executedDelayedOrders;
        }
    }

    function _releasePendingMargin(
        uint64 id
    ) internal {
        PendingOrderReferenceLedger.Order memory o = orders.order(id);
        uint256 released = orders.releaseMargin(id);
        if (released != 0) {
            carry.releaseProtectedWithoutCheckpoint(actorAt(o.actorIndex), released);
        }
    }

    function _modelBountyPayment(
        uint64 id,
        address executor,
        uint256 amount
    ) internal {
        PendingOrderReferenceLedger.Order memory o = orders.order(id);
        assertEq(orders.takeBounty(id), o.bountyUsdc);
        if (executor == actorAt(o.actorIndex)) {
            carry.releaseProtectedWithoutCheckpoint(executor, amount);
        } else {
            carry.consumeProtectedWithoutCheckpoint(actorAt(o.actorIndex), amount);
            traders[o.actorIndex].cash -= amount;
            assertEq(executor, KEEPER, "bounded external executor");
            expectedKeeper += amount;
        }
    }

    function _finishPendingOrder(
        PendingOrderReferenceLedger.Order memory o,
        OrderV3Types.LifecycleStatus status,
        OrderV3Types.TerminalReason reason,
        address executor,
        uint8 code
    ) internal {
        OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), o.id);
        assertEq(receipt.account, actorAt(o.actorIndex));
        assertEq(receipt.clientOrderId, o.request.clientOrderId);
        assertEq(receipt.intentHash, _intentHash(o.actorIndex, o.request));
        assertEq(receipt.expectedConfigHash, o.request.bounds.expectedConfigHash);
        assertEq(receipt.executor, executor);
        assertEq(uint8(receipt.status), uint8(status));
        assertEq(uint8(receipt.reason), uint8(reason));
        assertEq(receipt.bountyUsdc, o.bountyUsdc, "input-derived reserved bounty");
        _assertBountyOutcome(o, reason, executor);
        if (
            reason == OrderV3Types.TerminalReason.Executed || reason == OrderV3Types.TerminalReason.Slippage
                || reason == OrderV3Types.TerminalReason.PlannerRejected
        ) {
            assertEq(receipt.executionPrice, expectedExecutionPrices[o.id]);
            assertEq(receipt.oraclePublishTime, expectedExecutionTimes[o.id], "receipt uses authored publication");
            assertEq(uint8(receipt.priceSource), uint8(OrderV3Types.PriceSource.OracleExecution));
        }
        if (reason == OrderV3Types.TerminalReason.PlannerRejected) {
            uint8 category = !o.request.isClose && (code == 2 || code == 4 || code == 7) ? 2 : 1;
            bytes memory expected = abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, category, code, o.request.isClose
            );
            assertEq(receipt.failureSelector, ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector);
            assertEq(receipt.failureCategory, category);
            assertEq(receipt.failureCode, code);
            assertEq(receipt.revertDataHash, keccak256(expected));
        }
        orders.finalize(o.id, status, reason);
        orders.recordReceipt(o.id, receipt.receiptHash);
        if (reason == OrderV3Types.TerminalReason.Expired) {
            ++expiredOrders;
        }
        if (status == OrderV3Types.LifecycleStatus.Failed) {
            ++failedOrders;
        }
        _assertTerminalOrder(o.id);
    }

    function _assertBountyOutcome(
        PendingOrderReferenceLedger.Order memory o,
        OrderV3Types.TerminalReason reason,
        address executor
    ) internal {
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(router.lifecycleBook(), o.id);
        uint256 paid;
        uint256 refunded;
        uint256 forfeited;
        if (reason == OrderV3Types.TerminalReason.AccountLiquidated) {
            forfeited = o.bountyFree;
        } else if (reason == OrderV3Types.TerminalReason.RiskOff) {
            refunded = o.bountyUsdc;
        } else if (o.request.isClose && reason != OrderV3Types.TerminalReason.Executed) {
            paid = o.bountyFree;
        } else {
            paid = o.bountyUsdc;
        }
        OrderV3Types.BountyDisposition disposition;
        address recipient;
        if (paid != 0) {
            disposition = OrderV3Types.BountyDisposition.Paid;
            recipient = executor;
        } else if (forfeited != 0) {
            disposition = OrderV3Types.BountyDisposition.Forfeited;
            recipient = engine.protocolTreasury();
        } else if (refunded != 0) {
            disposition = OrderV3Types.BountyDisposition.RefundedToAccount;
            recipient = actorAt(o.actorIndex);
        }
        assertEq(uint8(receipt.bountyDisposition), uint8(disposition), "input-derived split disposition");
        assertEq(receipt.bountyRecipient, recipient);
        assertEq(receipt.bounty.bountyEntitlementUsdc, o.bountyUsdc);
        assertEq(receipt.bounty.bountyPaidUsdc, paid, "only earned bounty is paid");
        assertEq(receipt.bounty.bountyRefundedUsdc, refunded, "refund matches modeled terminal disposition");
        assertEq(receipt.bounty.bountyForfeitedUsdc, forfeited, "only free funding is forfeited");
        assertEq(paid + refunded + forfeited, o.bountyUsdc);
    }

    function executeBatch(
        uint256 countSeed
    ) public {
        uint64[] memory ids = orders.liveIds();
        if (ids.length == 0) {
            return;
        }
        uint256 count = bound(countSeed, 1, ids.length);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        bytes[] memory liveData = _prices(currentPrice);
        bytes[] memory data = frozen ? liveData : _batchOrderPrices(ids);
        OrderV3Types.TerminalReason[] memory reasons = new OrderV3Types.TerminalReason[](count);
        uint8[] memory codes = new uint8[](count);
        uint256 terminal;
        OrderV3Types.PendingReason stop;
        // Every item uses its first authored historical tick; newer marks cannot rewrite the execution price.
        for (uint256 j; j < count; ++j) {
            PendingOrderReferenceLedger.Order memory o = orders.order(ids[j]);
            reasons[j] = _preOracleReason(o);
            if (reasons[j] == OrderV3Types.TerminalReason.None) {
                if (!_prepareExpectedOrderOracle(o.id)) {
                    stop = OrderV3Types.PendingReason.HistoricalPriceUnavailable;
                    ++historicalPriceRejections;
                    break;
                }
                if (_isFadReference(vm.getBlockTimestamp()) && !o.request.isClose) {
                    stop = OrderV3Types.PendingReason.CloseOnly;
                    break;
                }
            }
            uint256 acceptedMark = currentPrice;
            if (reasons[j] == OrderV3Types.TerminalReason.None) {
                currentPrice = expectedExecutionPrices[o.id];
                reasons[j] = _expectedOrderReason(o);
            }
            _releasePendingMargin(o.id);
            if (reasons[j] == OrderV3Types.TerminalReason.Executed) {
                codes[j] = _expectedOrderCode(o);
                if (codes[j] != 0) {
                    reasons[j] = OrderV3Types.TerminalReason.PlannerRejected;
                } else {
                    _modelExecutedOrder(o);
                }
            }
            _modelTerminalBounty(o.id, reasons[j], KEEPER);
            currentPrice = acceptedMark;
            ++terminal;
        }
        _startRecordingLogs();
        vm.prank(KEEPER);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch{value: count}(ids[count - 1], data);
        assertEq(result.terminalCount, terminal, "independent batch terminal count");
        assertEq(uint8(result.stopReason), uint8(stop), "independent batch stop reason");
        for (uint256 j; j < terminal; ++j) {
            PendingOrderReferenceLedger.Order memory o = orders.order(ids[j]);
            OrderV3Types.LifecycleStatus status = reasons[j] == OrderV3Types.TerminalReason.Executed
                ? OrderV3Types.LifecycleStatus.Executed
                : OrderV3Types.LifecycleStatus.Failed;
            _finishPendingOrder(o, status, reasons[j], KEEPER, codes[j]);
        }
        assertEq(result.nextOrderId, orders.head());
        if (stop == OrderV3Types.PendingReason.None) {
            ++completedBatches;
        } else {
            ++stoppedBatches;
        }
        assertModel();
    }

    function expirePending(
        uint256 slotSeed
    ) public {
        uint64[] memory ids = orders.liveIds();
        if (ids.length == 0) {
            return;
        }
        PendingOrderReferenceLedger.Order memory o = orders.order(ids[slotSeed % ids.length]);
        if (vm.getBlockTimestamp() <= o.deadline) {
            vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotExpired.selector);
            router.expireOrder(o.id);
            ++rejectedEarlyExpiry;
        } else {
            _releasePendingMargin(o.id);
            _modelTerminalBounty(o.id, OrderV3Types.TerminalReason.Expired, KEEPER);
            _startRecordingLogs();
            vm.prank(KEEPER);
            router.expireOrder(o.id);
            _finishPendingOrder(o, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.Expired, KEEPER, 0);
        }
        assertModel();
    }

    function replayPending(
        uint256 slotSeed,
        bool conflict
    ) public {
        if (orders.nextId() == 1) {
            return;
        }
        uint64 id = uint64(1 + slotSeed % (orders.nextId() - 1));
        PendingOrderReferenceLedger.Order memory o = orders.order(id);
        bytes32 originalIntentHash = _intentHash(o.actorIndex, o.request);
        OrderV3Types.OrderRequest memory request = o.request;
        if (conflict) {
            request.targetPrice += 1;
            vm.expectRevert(
                abi.encodeWithSelector(
                    IOrderLifecycleBook.OrderLifecycleBook__ClientIdConflict.selector,
                    actorAt(o.actorIndex),
                    request.clientOrderId,
                    originalIntentHash,
                    _intentHash(o.actorIndex, request)
                )
            );
            vm.prank(actorAt(o.actorIndex));
            router.commitOrder(request);
            ++conflictingReplays;
        } else {
            vm.prank(actorAt(o.actorIndex));
            assertEq(router.commitOrder(request), id, "historical replay returns original identity");
            ++replayedOrders;
        }
        if (o.status != OrderV3Types.LifecycleStatus.Pending) {
            _assertTerminalOrder(id);
        }
        assertModel();
    }

    function rejectSixthOrder(
        uint256 actorSeed
    ) public {
        uint256 i = actorSeed % 4;
        if (frozen || orders.count(i) != 5) {
            return;
        }
        _ensurePledge(i, traders[i].lots * 60e6);
        if (_free(i) < 2000e6) {
            _deposit(i, 2000e6);
        }
        _refresh(80_000_002);
        OrderV3Types.OrderRequest memory request = _orderRequest(i, 17, 1020e6, false);
        bytes32 beforeState = _economicFingerprint(i);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__TooManyPendingOrders.selector);
        vm.prank(actorAt(i));
        router.commitOrder(request);
        assertEq(_economicFingerprint(i), beforeState, "sixth commitment rolls back even provisional carry and locks");
        assertEq(router.lifecycleBook().clientIntent(actorAt(i), request.clientOrderId).orderId, 0);
        ++rejectedSixthOrders;
        assertModel();
    }

    function pendingSameBlock() public {
        if (frozen || orders.liveCount() == 0) {
            return;
        }
        PendingOrderReferenceLedger.Order memory o = orders.order(orders.head());
        if (vm.getBlockNumber() != o.commitBlock || vm.getBlockTimestamp() + 1 > o.deadline) {
            return;
        }
        vm.warp(vm.getBlockTimestamp() + 1);
        _prices(currentPrice);
        bytes[] memory data = _orderPrices(o.id);
        if (!_prepareExpectedOrderOracle(o.id)) {
            _expectMissingHistoricalPrice(o, KEEPER, data);
            assertModel();
            return;
        }
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder{value: 1}(o.id, data);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.SameBlock));
        ++pendingSameBlockResults;
        assertModel();
    }

    function pendingMevBoundary() public {
        if (frozen || orders.liveCount() == 0) {
            return;
        }
        PendingOrderReferenceLedger.Order memory o = orders.order(orders.head());
        if (vm.getBlockTimestamp() > o.deadline) {
            return;
        }
        vm.roll(vm.getBlockNumber() + 1);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(2));
        pyth.setAllUniquePrices(ids, int64(int256(currentPrice)), 0, -8, o.commitTime, o.commitTime - 1);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(currentPrice);
        uint256 lastValid = uint256(o.commitTime) + 15;
        if (lastValid > vm.getBlockTimestamp()) {
            lastValid = vm.getBlockTimestamp();
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                IPletherOracle.PletherOracle__StalePrice.selector,
                IPletherOracle.PriceMode.OrderExecution,
                bytes32(0),
                lastValid,
                uint256(60),
                vm.getBlockTimestamp()
            )
        );
        router.executeOrder{value: 1}(o.id, data);
        ++pendingMevRejections;
        assertModel();
    }

    function executeSlippageFailure() public {
        if (frozen || orders.liveCount() != 0) {
            return;
        }
        uint256 i = 0;
        if (traders[i].lots > 400) {
            return;
        }
        _ensurePledge(i, traders[i].lots * 60e6);
        if (_free(i) < 1021e6) {
            _deposit(i, 2000e6);
        }
        _refresh(120_000_002);
        OrderV3Types.OrderRequest memory request = _orderRequest(i, 17, 1020e6, false);
        request.targetPrice = 120_000_002;
        _commitCustomOpen(i, request);
        _refresh(80_000_002);
        executeHead(false);
        ++slippageFailures;
    }

    function _commitCustomOpen(
        uint256 i,
        OrderV3Types.OrderRequest memory request
    ) internal {
        _collect(i);
        carry.reserveWithoutCheckpoint(actorAt(i), request.marginDelta + 200_000);
        uint64 id =
            orders.commit(i, positionEpochs[i], request, 200_000, 0, vm.getBlockTimestamp(), vm.getBlockNumber());
        vm.prank(actorAt(i));
        assertEq(router.commitOrder(request), id);
        ++orderCommits;
    }

    function riskOffPending() public {
        if (orders.liveCount() == 0) {
            return;
        }
        OrderRouterAdmin admin = OrderRouterAdmin(router.admin());
        vm.prank(owner);
        admin.pause();
        riskOffCutoff = orders.nextId() - 1;
        uint64[] memory ids = orders.liveIds();
        for (uint256 j; j < ids.length; ++j) {
            PendingOrderReferenceLedger.Order memory o = orders.order(ids[j]);
            if (o.request.isClose) {
                continue;
            }
            _releasePendingMargin(o.id);
            uint256 bounty = orders.takeBounty(o.id);
            carry.releaseProtectedWithoutCheckpoint(actorAt(o.actorIndex), bounty);
            _startRecordingLogs();
            vm.prank(KEEPER);
            router.clearRiskOffOrder(o.id);
            _finishPendingOrder(o, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.RiskOff, KEEPER, 0);
            ++riskOffOrders;
        }
        vm.prank(owner);
        admin.unpause();
        assertModel();
    }

    function _forfeitPendingBounties(
        uint256 i
    ) internal {
        uint64[] memory ids = orders.accountIds(i);
        for (uint256 j; j < ids.length; ++j) {
            PendingOrderReferenceLedger.Order memory o = orders.order(ids[j]);
            if (o.request.isClose) {
                ++unpaidCloseLiquidations;
            }
            assertEq(orders.takeBounty(o.id), o.bountyUsdc);
            uint256 amount = o.bountyFree;
            forfeitedOrderBounties[ids[j]] = amount;
            carry.consumeProtectedWithoutCheckpoint(actorAt(i), amount);
            traders[i].cash -= amount;
            expectedTreasury += amount;
        }
    }

    function _consumePendingMargin(
        uint256 i,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }
        orders.consumeMargin(i, amount);
        carry.consumeProtectedWithoutCheckpoint(actorAt(i), amount);
        pendingMarginConsumed += amount;
    }

    function _clearLiquidatedPendingOrders(
        uint256 i
    ) internal {
        uint64[] memory ids = orders.accountIds(i);
        for (uint256 j; j < ids.length; ++j) {
            PendingOrderReferenceLedger.Order memory o = orders.order(ids[j]);
            assertEq(forfeitedOrderBounties[o.id], o.bountyFree);
            _releasePendingMargin(o.id);
            _finishPendingOrder(
                o, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.AccountLiquidated, KEEPER, 0
            );
        }
    }

    function _vpi(
        uint256 i,
        uint256 lots,
        bool closing
    ) internal view returns (int256) {
        return _vpiAtDepth(i, lots, closing, _depth());
    }

    function _vpiAtDepth(
        uint256 i,
        uint256 lots,
        bool closing,
        uint256 depth
    ) internal view returns (int256) {
        if (depth == 0) {
            return 0;
        }
        uint256 longs = sideLots[0];
        uint256 shorts = sideLots[1];
        uint256 beforeSkew = longs > shorts ? longs - shorts : shorts - longs;
        if (i % 2 == 0) {
            longs = closing ? longs - lots : longs + lots;
        } else {
            shorts = closing ? shorts - lots : shorts + lots;
        }
        uint256 afterSkew = longs > shorts ? longs - shorts : shorts - longs;
        // k=1/200: C(S)=floor(S²/(400D)), an algebraically reduced exact rational independent of CfdMath.
        return int256((afterSkew * currentPrice) ** 2 / (400 * depth))
            - int256((beforeSkew * currentPrice) ** 2 / (400 * depth));
    }

    struct OpenValues {
        uint8 revertCode;
        uint256 margin;
        uint256 cash;
        uint256 fee;
        uint256 reserve;
        int256 vpi;
    }

    struct OpenScratch {
        uint256 depth;
        int256 cost;
        uint256 oldVpiReserve;
        int256 nextVpi;
        uint256 nextVpiReserve;
        uint256 available;
        uint256 extraVpi;
        uint256 vpiFromPledge;
        uint256 newPledge;
        int256 pnl;
        int256 equity;
        uint256 notional;
        uint256 initial;
    }

    function _projectOpen(
        uint256 i,
        uint256 lots,
        uint256 contribution,
        CarryReferenceLedger.Collection memory c
    ) internal view returns (OpenValues memory v) {
        Trader memory t = traders[i];
        OpenScratch memory x;
        if (c.unpaid != 0) {
            v.revertCode = 5;
            return v;
        }
        // The minimum supports the $1 liquidation charge at 10 bps on the live resulting position.
        // Earlier queued opens are still reservations and cannot satisfy this admission threshold.
        if ((t.lots + lots) * currentPrice < 1000e6) {
            v.revertCode = 3;
            return v;
        }
        t.margin -= c.fromMargin;
        t.cash -= c.fromMargin + c.fromFree;
        x.depth = _depth() + c.fromMargin + c.fromFree;
        v.vpi = _vpiAtDepth(i, lots, false, x.depth);
        v.fee = lots * currentPrice / 2500;
        x.cost = v.vpi + int256(v.fee);
        x.oldVpiReserve = t.vpi < 0 ? uint256(-t.vpi) : 0;
        x.nextVpi = t.vpi + v.vpi;
        x.nextVpiReserve = x.nextVpi < 0 ? uint256(-x.nextVpi) : 0;
        x.available = t.cash - t.margin - t.liquidationReserve - x.oldVpiReserve - orders.margin(i) - orders.bounty(i);
        if (x.oldVpiReserve > x.nextVpiReserve) {
            x.available += x.oldVpiReserve - x.nextVpiReserve;
        }
        if (x.cost < 0) {
            x.available += uint256(-x.cost);
        }
        if (contribution > x.available || (x.cost > 0 && uint256(x.cost) > t.margin + contribution)) {
            v.revertCode = 5;
            return v;
        }
        v.margin = t.margin + contribution - (x.cost > 0 ? uint256(x.cost) : 0);
        x.available -= contribution;
        x.extraVpi = x.nextVpiReserve > x.oldVpiReserve ? x.nextVpiReserve - x.oldVpiReserve : 0;
        x.vpiFromPledge = x.extraVpi > x.available ? x.extraVpi - x.available : 0;
        x.newPledge = v.margin > t.margin ? v.margin - t.margin : 0;
        if (x.vpiFromPledge > x.newPledge) {
            v.revertCode = 10;
            return v;
        }
        v.margin -= x.vpiFromPledge;
        v.reserve = (t.lots + lots) * currentPrice / 1000;
        if (v.reserve < 1e6) {
            v.reserve = 1e6;
        }
        if (v.reserve < t.liquidationReserve) {
            v.reserve = t.liquidationReserve;
        }
        if (v.reserve - t.liquidationReserve > x.newPledge - x.vpiFromPledge) {
            v.revertCode = 9;
            return v;
        }
        v.margin -= v.reserve - t.liquidationReserve;
        x.pnl = int256(t.basis) - int256(t.lots * currentPrice);
        if (i % 2 != 0) {
            x.pnl = -x.pnl;
        }
        x.equity = int256(v.margin + t.claim) + x.pnl;
        x.notional = (t.lots + lots) * currentPrice;
        x.initial = x.notional * 150 / 10_000;
        if (x.initial < 1e6) {
            x.initial = 1e6;
        }
        if (
            x.equity < int256(x.initial)
                || x.equity <= int256(x.notional * (_isFadReference(vm.getBlockTimestamp()) ? 300 : 100) / 10_000)
        ) {
            v.revertCode = 6;
            return v;
        }
        v.cash = uint256(int256(t.cash) - x.cost);
    }

    function _projectClose(
        uint256 i,
        uint256 lots,
        CarryReferenceLedger.Collection memory c
    ) internal view returns (CloseReferenceMath.Values memory) {
        Trader memory t = traders[i];
        uint256 paid = c.fromMargin + c.fromFree;
        uint256 depth = _depth() + paid;
        CloseReferenceMath.Input memory input;
        input.isLong = i % 2 == 0;
        input.lots = t.lots;
        input.basis = t.basis;
        input.margin = t.margin - c.fromMargin;
        input.cash = t.cash - paid;
        input.claim = t.claim;
        input.liquidationReserve = t.liquidationReserve;
        input.lifetimeVpi = t.vpi;
        input.closeLots = lots;
        input.price = currentPrice;
        if (lots <= t.lots) {
            input.vpiDelta = _vpiAtDepth(i, lots, true, depth);
        }
        input.frozen = frozen;
        input.unpaidCarry = c.unpaid;
        input.committedMargin = orders.margin(i);
        input.protectedBounty = orders.bounty(i);
        input.vpiReserve = t.vpi < 0 ? uint256(-t.vpi) : 0;
        input.poolCash = expectedPoolCash + paid;
        input.poolAccounted = expectedAccounted + paid;
        input.allClaims = expectedClaims;
        input.maintenanceBps = _isFadReference(vm.getBlockTimestamp()) ? 300 : 100;
        return CloseReferenceMath.calculate(input);
    }

    function _bookOpen(
        uint256 i,
        uint256 lots,
        uint256 contribution,
        int256
    ) internal {
        CarryReferenceLedger.Collection memory noAdditionalCarry;
        OpenValues memory v = _projectOpen(i, lots, contribution, noAdditionalCarry);
        assertEq(v.revertCode, 0, "independent admitted open economics");
        Trader storage t = traders[i];
        if (t.lots == 0) {
            ++successfulOpens;
            ++positionEpochs[i];
        } else {
            ++successfulIncreases;
        }
        t.margin = v.margin;
        t.cash = v.cash;
        t.liquidationReserve = v.reserve;
        expectedPoolCash = uint256(int256(expectedPoolCash) + v.vpi);
        expectedAccounted = uint256(int256(expectedAccounted) + v.vpi);
        expectedTreasury += v.fee;
        t.lots += lots;
        t.basis += lots * currentPrice;
        t.vpi += v.vpi;
        sideLots[i % 2] += lots;
        _countVpi(v.vpi);
    }

    function _bookClose(
        uint256 i,
        uint256 lots,
        int256
    ) internal {
        CarryReferenceLedger.Collection memory noAdditionalCarry;
        noAdditionalCarry.unpaid = carry.accountState(actorAt(i)).arrears;
        CloseReferenceMath.Values memory v = _projectClose(i, lots, noAdditionalCarry);
        assertEq(v.revertCode, 0, "independent admitted close economics");
        Trader storage t = traders[i];
        _consumePendingMargin(i, v.committedMarginConsumed);
        if (noAdditionalCarry.unpaid != 0) {
            carry.settleActionArrears(actorAt(i), v.carryCash, v.carryWithheld, v.carryVpiOffset, v.carryWaived);
            carryCollected += v.carryCash + v.carryWithheld + v.carryVpiOffset;
        }
        t.lots = v.remainingLots;
        t.basis = v.remainingBasis;
        t.margin = v.remainingMargin;
        t.cash = v.remainingCash;
        t.claim = v.remainingClaim;
        t.vpi = v.remainingVpi;
        t.liquidationReserve = v.remainingLiquidationReserve;
        expectedPoolCash = v.poolCashAfter;
        expectedAccounted = v.poolAccountedAfter;
        expectedClaims = v.allClaimsAfter;
        expectedTreasury += v.treasuryCredit;
        waivedActionCharges += v.actionWaived;
        sideLots[i % 2] -= lots;
        if (v.deferredPayout != 0) {
            ++deferredClaims;
        }
        if (v.remainingLots == 0) {
            ++fullCloses;
        } else {
            ++partialCloses;
        }
        if (frozen) {
            ++frozenCloses;
        }
        _countVpi(v.vpi);
    }

    function _countVpi(
        int256 value
    ) internal {
        if (value > 0) {
            ++positiveVpiActions;
        }
        if (value < 0) {
            ++negativeVpiActions;
        }
    }

    function _projectLpCapital() internal view returns (uint256 seniorCapital, uint256 juniorCapital, uint256 hwm) {
        int256 nav = int256(_depth()) - int256(expectedClaims);
        for (uint256 i; i < 4; ++i) {
            Trader storage t = traders[i];
            int256 pnl = int256(t.basis) - int256(t.lots * currentPrice);
            if (i % 2 != 0) {
                pnl = -pnl;
            }
            if (pnl > 0) {
                nav -= pnl;
            } else {
                uint256 loss = uint256(-pnl);
                uint256 backing = t.margin + t.claim;
                nav += int256(loss < backing ? loss : backing);
            }
        }
        WaterfallReferenceMath.Result memory result = WaterfallReferenceMath.reconcile(
            WaterfallReferenceMath.State(expectedSenior, expectedJunior, expectedHwm, expectedCouponTime),
            nav > 0 ? uint256(nav) : 0,
            800,
            vm.getBlockTimestamp()
        );
        return (result.state.senior, result.state.junior, result.state.highWaterMark);
    }

    function _reconcile() internal {
        uint64[] memory live = orders.liveIds();
        for (uint256 i; i < live.length; ++i) {
            if (orders.order(live[i]).request.isClose) {
                ++lpEpochsWithPendingCloses;
                break;
            }
        }
        (expectedSenior, expectedJunior, expectedHwm) = _projectLpCapital();
        expectedCouponTime = vm.getBlockTimestamp();
    }

    function assertPendingModel() public view {
        assertEq(router.nextCommitId(), orders.nextId(), "independent commit cursor");
        assertEq(router.nextExecuteId(), orders.head(), "independent global FIFO head");
        assertEq(router.globalTailOrderId(), orders.tail(), "independent global FIFO tail");
        uint64[] memory ids = orders.liveIds();
        assertLe(ids.length, 20);
        for (uint256 j; j < ids.length; ++j) {
            _assertLiveOrder(ids[j]);
        }
        for (uint256 i; i < 4; ++i) {
            address account = actorAt(i);
            uint64[] memory accountIds = orders.accountIds(i);
            assertEq(router.accountHeadOrderId(account), accountIds.length == 0 ? 0 : accountIds[0]);
            assertEq(router.pendingOrderCounts(account), accountIds.length);
            assertEq(router.pendingCloseSize(account), orders.pendingCloseLots(i) * 1e20);
            IMarginClearinghouse.AccountReservationSummary memory summary =
                clearinghouse.getAccountReservationSummary(account);
            uint64[] memory marginIds = clearinghouse.getMarginReservationIds(account);
            uint256 active;
            for (uint256 j; j < accountIds.length; ++j) {
                (, uint64 next) = router.getPendingOrderView(accountIds[j]);
                assertEq(next, j + 1 < accountIds.length ? accountIds[j + 1] : 0, "exact account FIFO link");
                if (orders.order(accountIds[j]).remainingMargin != 0) {
                    assertLt(active, marginIds.length);
                    assertEq(marginIds[active++], accountIds[j], "independent margin reservation FIFO");
                }
            }
            assertEq(marginIds.length, active);
            assertEq(summary.activeReservationCount, active);
            assertEq(summary.activeCommittedOrderMarginUsdc, orders.margin(i));
            assertEq(clearinghouse.orderMarginUsdc(account), orders.margin(i));
            assertEq(clearinghouse.totalBountyReservationsUsdc(account), orders.bounty(i));
            assertEq(
                clearinghouse.actionReserveUsdc(account),
                orders.bounty(i) + (traders[i].vpi < 0 ? uint256(-traders[i].vpi) : 0)
            );
            assertEq(engine.positionEpoch(account), positionEpochs[i], "independent position incarnation");
        }
    }

    function _assertLiveOrder(
        uint64 id
    ) internal view {
        PendingOrderReferenceLedger.Order memory o = orders.order(id);
        address account = actorAt(o.actorIndex);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(id);
        assertEq(pending.orderId, id);
        assertEq(pending.sizeDelta, o.request.sizeDelta);
        assertEq(pending.marginDelta, o.request.marginDelta);
        assertEq(pending.targetPrice, o.request.targetPrice);
        assertEq(pending.isClose, o.request.isClose);
        assertEq(uint8(pending.side), uint8(o.request.side));
        assertEq(pending.commitTime, o.commitTime);
        assertEq(pending.commitBlock, o.commitBlock);
        assertEq(pending.committedMarginUsdc, o.remainingMargin);
        assertEq(pending.executionBountyUsdc, o.remainingBounty);
        OrderV3Types.PendingIntent memory intent = router.lifecycleBook().pendingIntent(id);
        assertEq(intent.account, account);
        assertEq(intent.clientOrderId, o.request.clientOrderId);
        assertEq(intent.intentHash, _intentHash(o.actorIndex, o.request), "input-derived domain-separated intent");
        assertEq(keccak256(abi.encode(intent.bounds)), keccak256(abi.encode(o.request.bounds)));
        assertEq(intent.timing.executionDeadline, o.deadline);
        assertEq(router.lifecycleBook().clientIntent(account, o.request.clientOrderId).orderId, id);
        IMarginClearinghouse.OrderReservation memory margin = clearinghouse.getOrderReservation(id);
        assertEq(margin.remainingAmountUsdc, o.remainingMargin);
        assertEq(uint8(margin.status), uint8(o.marginStatus));
        IMarginClearinghouse.BountyReservation memory bounty =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        assertEq(bounty.account, account);
        assertEq(bounty.amountUsdc, o.remainingBounty);
        assertEq(bounty.freeFundedUsdc, o.bountyFree);
        assertEq(bounty.freeFundedUsdc, bounty.amountUsdc);
        assertEq(uint8(bounty.state), uint8(IMarginClearinghouse.BountyReservationState.Active));
        if (o.request.isClose) {
            assertEq(intent.commitment.carryCollectedUsdc, committedCarry[id]);
        }
    }

    function _assertTerminalOrder(
        uint64 id
    ) internal view {
        PendingOrderReferenceLedger.Order memory o = orders.order(id);
        OrderV3Types.TerminalOutcome memory terminal = router.lifecycleBook().terminalOutcome(id);
        assertEq(terminal.account, actorAt(o.actorIndex));
        assertEq(uint8(terminal.status), uint8(o.status));
        assertEq(uint8(terminal.reason), uint8(o.reason));
        assertEq(terminal.receiptHash, o.receiptHash);
        assertEq(router.lifecycleBook().clientIntent(actorAt(o.actorIndex), o.request.clientOrderId).orderId, id);
        assertEq(router.lifecycleBook().pendingIntent(id).account, address(0));
        (IOrderRouterAccounting.PendingOrderView memory pending, uint64 next) = router.getPendingOrderView(id);
        assertEq(pending.sizeDelta, 0);
        assertEq(next, 0);
        IMarginClearinghouse.OrderReservation memory margin = clearinghouse.getOrderReservation(id);
        assertEq(margin.remainingAmountUsdc, 0);
        assertEq(uint8(margin.status), uint8(o.marginStatus));
        IMarginClearinghouse.BountyReservation memory bounty =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        assertEq(bounty.amountUsdc, 0);
        assertEq(uint8(bounty.state), uint8(IMarginClearinghouse.BountyReservationState.Settled));
    }

    function economicFingerprint(
        uint256 i
    ) external view returns (bytes32) {
        return _economicFingerprint(i);
    }

    function _economicFingerprint(
        uint256 i
    ) internal view returns (bytes32) {
        (bool ok, bytes memory position) =
            address(engine).staticcall(abi.encodeWithSignature("positions(address)", actorAt(i)));
        assertTrue(ok);
        bytes32 account = keccak256(
            abi.encode(
                position,
                engine.positionEntryCostUsdcAtoms(actorAt(i)),
                engine.unsettledCarryUsdc(actorAt(i)),
                clearinghouse.balanceUsdc(actorAt(i)),
                clearinghouse.getAccountUsdcBuckets(actorAt(i)),
                engine.traderClaimBalanceUsdc(actorAt(i))
            )
        );
        bytes32 indexes = keccak256(
            abi.encode(
                engine.sideCarryIndex(0),
                engine.sideCarryIndex(1),
                engine.sideCarryTimestamp(0),
                engine.sideCarryTimestamp(1)
            )
        );
        bytes32 protocol =
            keccak256(abi.encode(pool.accountedAssets(), usdc.balanceOf(address(pool)), router.nextCommitId()));
        return keccak256(abi.encode(account, indexes, protocol));
    }

    function pausePending() public {
        OrderRouterAdmin admin = OrderRouterAdmin(router.admin());
        vm.prank(owner);
        admin.pause();
        riskOffCutoff = orders.nextId() - 1;
    }

    function unpausePending() public {
        OrderRouterAdmin admin = OrderRouterAdmin(router.admin());
        vm.prank(owner);
        admin.unpause();
    }

    function _refundRiskOffPendingBeforeLiquidation(
        uint256 i
    ) internal returns (uint64[] memory refunds) {
        uint64[] memory ids = orders.accountIds(i);
        uint256 count;
        for (uint256 j; j < ids.length; ++j) {
            PendingOrderReferenceLedger.Order memory o = orders.order(ids[j]);
            if (o.id <= riskOffCutoff && !o.request.isClose) {
                ++count;
            }
        }
        refunds = new uint64[](count);
        count = 0;
        for (uint256 j; j < ids.length; ++j) {
            PendingOrderReferenceLedger.Order memory o = orders.order(ids[j]);
            if (o.id > riskOffCutoff || o.request.isClose) {
                continue;
            }
            refunds[count++] = o.id;
            _releasePendingMargin(o.id);
            carry.releaseProtectedWithoutCheckpoint(actorAt(i), orders.takeBounty(o.id));
            orders.finalize(o.id, OrderV3Types.LifecycleStatus.Failed, OrderV3Types.TerminalReason.RiskOff);
        }
    }

    function _finishRiskOffLiquidationRefunds(
        uint64[] memory refunds
    ) internal {
        for (uint256 j; j < refunds.length; ++j) {
            PendingOrderReferenceLedger.Order memory o = orders.order(refunds[j]);
            OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), o.id);
            assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.RiskOff));
            assertEq(receipt.account, actorAt(o.actorIndex));
            assertEq(receipt.bountyRecipient, actorAt(o.actorIndex));
            assertEq(receipt.bountyUsdc, o.bountyUsdc);
            assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.RefundedToAccount));
            orders.recordReceipt(o.id, receipt.receiptHash);
            ++riskOffOrders;
            _assertTerminalOrder(o.id);
        }
    }

    /// @notice A real claim-backed zero-pledge account retains carry until a healing close offsets it with VPI.
    function exerciseUnpaidCarryVpiOffsetClose() external {
        assertEq(orders.liveCount(), 0);
        assertEq(traders[0].lots, 50, "existing public claim-backed half position");
        assertEq(traders[0].margin, 0);
        assertGt(traders[0].claim, 0);
        assertGt(traders[0].vpi, 0);
        _withdraw(0, _free(0));
        uint64 id = _commitTrade(0, 50, 0, true);
        _commitTrade(1, 17, 1020e6, false);
        assertEq(_free(0), 0, "close commits with no free settlement");
        vm.warp(vm.getBlockTimestamp() + 1);
        _refresh(currentPrice);
        uint256 beforeOffset = carry.totalVpiOffset();
        vm.warp(vm.getBlockTimestamp() + 49);
        CarryReferenceLedger.Collection memory projected = carry.previewCheckpoint(actorAt(0), vm.getBlockTimestamp());
        assertGt(projected.unpaid, 0, "elapsed public history produces actual unpaid carry");
        executeHead(false);
        assertEq(uint8(orders.order(id).status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertGt(carry.totalVpiOffset(), beforeOffset, "negative VPI economically extinguishes retained carry");
        assertEq(traders[0].lots, 0);
        assertEq(carry.accountState(actorAt(0)).arrears, 0);
        assertEq(orders.liveCount(), 1, "other account's funded request survives terminal close");
        assertModel();
    }

    /// @notice A losing full close spends older queued margins in FIFO order while every bounty stays protected.
    function exerciseQueuedMarginFullClose() external {
        assertEq(orders.liveCount(), 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(traders[i].lots, 0);
        }
        _refresh(80_000_002);
        _trade(0, 100, 300e6, false);
        _trade(1, 500, 30_000e6, false);
        uint64 closeId = _commitTrade(0, 100, 0, true);
        uint64 first = _commitTrade(0, 17, 2e6, false);
        uint64 second = _commitTrade(0, 17, 10e6, false);
        assertEq(orders.head(), closeId);
        _withdraw(0, _free(0));
        _refresh(140_000_002);
        uint256 keeperBefore = expectedKeeper;
        executeHead(false);
        assertEq(traders[0].lots, 0);
        assertEq(orders.order(first).remainingMargin, 0, "oldest committed margin fully consumed");
        assertGt(orders.order(second).remainingMargin, 0, "newer committed margin retains unspent cash");
        assertLt(orders.order(second).remainingMargin, 10e6, "next reservation partly consumed");
        assertEq(uint8(orders.order(first).marginStatus), uint8(PendingOrderReferenceLedger.MarginStatus.Consumed));
        assertEq(orders.order(first).remainingBounty, 136_000);
        assertEq(orders.order(second).remainingBounty, 136_000);
        assertEq(expectedKeeper - keeperBefore, 0, "close leaves queued open bounties protected");
        assertModel();
        executeHead(false);
        assertEq(uint8(orders.order(first).reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        executeHead(false);
        assertEq(uint8(orders.order(second).reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(orders.liveCount(), 0);
        assertModel();
    }

    /// @notice An unpaid pending close remains solvent at the current mark but cannot block liquidation after a loss.
    function exercisePendingCloseSolvencyHistory() external {
        uint256 i = 2;
        assertEq(orders.liveCount(), 0);
        assertEq(traders[i].lots, 0);
        _refresh(100_000_002);
        _trade(i, 100, 300e6, false);
        _withdraw(i, _free(i));
        uint64 id = _commitTrade(i, 100, 0, true);
        assertEq(orders.order(id).bountyUsdc, 0);
        assertFalse(_liquidateAt(i, 100_000_002), "unpaid pending close preserves solvent position");
        assertEq(orders.head(), id);
        assertTrue(_liquidateAt(i, 140_000_002), "unpaid pending close cannot shield losses");
        assertEq(orders.count(i), 0);
        assertModel();
    }

    function exerciseUnpaidCloseOverlapHistory() public {
        assertEq(orders.liveCount(), 0);
        uint256 i;
        assertGt(traders[i].lots, 0);
        _deposit(i, 1);
        _withdraw(i, _free(i));
        uint64 first = _commitTrade(i, traders[i].lots, 0, true);
        assertGt(first, 0);
        assertEq(orders.order(first).bountyUsdc, 0);
        uint256 nextBounty = 17 * currentPrice / 10_000;
        if (nextBounty > 200_000) {
            nextBounty = 200_000;
        }
        if (nextBounty < 10_000) {
            nextBounty = 10_000;
        }
        _deposit(i, 1020e6 + nextBounty);
        uint64 later = _commitTrade(i, 17, 1020e6, false);
        assertGt(later, first);
        assertEq(_free(i), 0);
        uint64 last = _commitTrade(i, 17, 0, true);
        assertGt(last, later, "unpaid later close requires no pledge reservation restriction");
        ++closeOpenCloseHistories;
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 keeperBefore = expectedKeeper;
        uint256 marginBefore = traders[i].margin;
        expirePending(0);
        assertEq(expectedKeeper, keeperBefore);
        assertEq(traders[i].margin, marginBefore);
        assertEq(orders.head(), later);
        expirePending(0);
        assertEq(expectedKeeper - keeperBefore, nextBounty);
        expirePending(0);
        assertEq(orders.liveCount(), 0);
        _refresh(currentPrice);
        assertModel();
    }

    function exercisePendingHistories() external {
        assertFalse(frozen);
        assertEq(orders.liveCount(), 0, "pending prelude starts after completed legacy examples");
        for (uint256 j; j < 5; ++j) {
            for (uint256 i; i < 4; ++i) {
                commitOpen(i, 17, 80_000_002);
            }
        }
        assertEq(orders.liveCount(), 20);
        for (uint256 i; i < 4; ++i) {
            rejectSixthOrder(i);
        }
        replayPending(orders.head() - 1, false);
        replayPending(orders.head() - 1, true);
        pendingSameBlock();
        pendingMevBoundary();
        executeBatch(7);
        assertEq(orders.liveCount(), 13, "inclusive batch bound preserves trailing live orders");
        executeBatch(orders.liveCount());
        assertEq(orders.liveCount(), 0);
        commitOpen(0, 17, 120_000_002);
        expirePending(0);
        vm.warp(vm.getBlockTimestamp() + 61);
        expirePending(0);
        executeSlippageFailure();
        commitOpen(1, 17, 80_000_002);
        riskOffPending();
        replayPending(0, false);
        assertModel();
    }

    function assertModel() public view {
        assertPendingModel();
        if (hasAcceptedMark) {
            assertEq(engine.lastMarkPrice(), currentPrice, "mixed input-derived cached mark");
            assertEq(engine.lastMarkTime(), currentMarkTime, "mixed input-derived cached mark time");
        }
        assertEq(carry.poolDepth(), _depth(), "independent carry denominator matches complete pool ledger");
        uint256 custody = expectedTreasury + expectedKeeper;
        uint256 arrears;
        uint256 wallets;
        uint256[2] memory expectedSideMargin;
        for (uint256 i; i < 4; ++i) {
            Trader storage t = traders[i];
            address account = actorAt(i);
            (uint256 size, uint256 margin,, uint256 maxProfit,,, int256 vpi) = engine.positions(account);
            assertEq(size, t.lots * 1e20, "mixed exact lots");
            assertEq(margin, t.margin, "mixed independent pledge");
            assertEq(engine.positionEntryCostUsdcAtoms(account), t.basis, "mixed exact entry basis");
            assertEq(maxProfit, i % 2 == 0 ? t.basis : t.lots * CAP - t.basis, "mixed endpoint liability");
            assertEq(vpi, t.vpi, "mixed lifetime VPI");
            assertEq(clearinghouse.balanceUsdc(account), t.cash, "mixed account cash");
            assertEq(engine.traderClaimBalanceUsdc(account), t.claim, "mixed independently generated claim");
            assertEq(clearinghouse.liquidationReserveUsdc(account), t.liquidationReserve, "mixed liquidation reserve");
            assertEq(clearinghouse.vpiRebateReserveUsdc(account), t.vpi < 0 ? uint256(-t.vpi) : 0, "mixed VPI backing");
            assertEq(usdc.balanceOf(account), t.wallet, "mixed trader external custody");
            CarryReferenceLedger.Account memory carryAccount = carry.accountState(account);
            assertEq(engine.unsettledCarryUsdc(account), carryAccount.arrears, "mixed carry arrears");
            assertEq(
                carryAccount.totalNewCarry,
                carryAccount.totalCollected + carryAccount.totalWaived + carryAccount.arrears,
                "per-account lifetime carry conservation"
            );
            arrears += carryAccount.arrears;
            assertEq(carryAccount.pledge, t.margin, "reference ledger pledge integration");
            assertEq(carryAccount.free, _free(i), "reference ledger free integration");
            (uint256 borrowBase, uint256 index, uint64 timestamp) = engine.positionCarryState(account);
            if (t.lots != 0) {
                assertEq(borrowBase, carryAccount.borrowBase, "mixed position borrow basis");
                assertEq(index, carryAccount.lastIndex, "mixed position checkpoint index");
                assertEq(timestamp, carryAccount.lastTime, "mixed position checkpoint timestamp");
            } else {
                assertEq(borrowBase, 0, "flat generation borrow basis cleared");
                assertEq(index, 0, "flat generation carry index cleared");
                assertEq(timestamp, 0, "flat generation carry timestamp cleared");
            }
            assertEq(
                carryAccount.protectedFunds,
                t.liquidationReserve + (t.vpi < 0 ? uint256(-t.vpi) : 0) + orders.margin(i) + orders.bounty(i),
                "independent complete protected funds"
            );
            custody += t.cash;
            wallets += t.wallet;
            expectedSideMargin[i % 2] += t.margin;
        }
        assertEq(
            carry.totalNewCarry(),
            carry.totalCollected() + carry.totalWaived() + arrears,
            "persistent aggregate carry conservation"
        );
        assertEq(carryCollected, carry.totalCollected(), "complete independent carry collection attribution");
        assertEq(usdc.balanceOf(address(clearinghouse)), custody, "mixed complete clearinghouse custody");
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), expectedTreasury, "mixed fee ownership");
        assertEq(clearinghouse.balanceUsdc(KEEPER), expectedKeeper, "mixed exact-once keeper credits");
        assertEq(engine.totalTraderClaimBalanceUsdc(), expectedClaims, "mixed aggregate claims");
        assertEq(usdc.balanceOf(address(pool)), expectedPoolCash, "mixed modeled physical pool cash");
        assertEq(pool.accountedAssets(), expectedAccounted, "mixed canonical pool backing");
        assertEq(pool.seniorPrincipal(), expectedSenior, "mixed independent Senior waterfall");
        assertEq(pool.juniorPrincipal(), expectedJunior, "mixed independent Junior waterfall");
        assertEq(pool.seniorHighWaterMark(), expectedHwm, "mixed independent Senior HWM");
        (uint256 vaultCash, uint256 lpWallets) = _assertLpModel();
        assertEq(
            usdc.totalSupply(),
            explicitFunding + externalShockIn - externalShockOut,
            "complete external issuance ledger"
        );
        assertEq(usdc.balanceOf(address(engine)), 0, "Engine retains no settlement cash");
        assertEq(usdc.balanceOf(address(router)), 0, "Router retains no settlement cash");
        assertEq(
            custody + expectedPoolCash + vaultCash + wallets + lpWallets + externalShockOut,
            explicitFunding + externalShockIn,
            "mixed external-flow conservation"
        );
        for (uint8 side; side < 2; ++side) {
            (, uint256 oi,, uint256 margin) = engine.sides(side);
            assertEq(margin, expectedSideMargin[side], "mixed aggregate side margin");
            assertEq(oi, sideLots[side] * 1e20);
            assertEq(engine.sideBorrowBaseUsdc(side), carry.sideState(side).borrowBase, "mixed carry borrow basis");
            assertEq(engine.sideCarryIndex(side), carry.sideState(side).index, "mixed independent side carry index");
            assertEq(engine.sideCarryTimestamp(side), carry.sideState(side).timestamp, "mixed carry clock");
        }
    }

    function _assertRedeemPosition(
        Lp storage lp,
        address account
    ) internal view {
        (bool success, bytes memory data) =
            address(junior).staticcall(abi.encodeCall(junior.redeemRequests, (account, lp.redeemEpoch)));
        assertTrue(success, "redemption position getter");
        TrancheVault.RedeemPosition memory actual = abi.decode(data, (TrancheVault.RedeemPosition));
        assertEq(actual.shares, lp.redeemBasis, "immutable controller redemption basis");
        assertEq(actual.claimedShares, lp.redeemedShares, "cumulative controller redeemed shares");
        assertEq(actual.claimedAssets, lp.redeemedAssets, "cumulative controller redeemed cash");
        assertEq(actual.refundedShares, lp.refundedShares, "cumulative controller refunded shares");
        assertEq(actual.previousRequestId, 0, "one pending redemption per controller");
        assertEq(actual.nextRequestId, 0, "one pending redemption per controller tail");
        assertEq(actual.queued, lp.redeemQueued, "redemption survives partial claims");
        assertEq(actual.fundingClaimed, lp.redeemFundingClaimed, "terminal funding acknowledgement");
        assertEq(actual.refundClaimed, lp.redeemRefundClaimed, "terminal refund acknowledgement");
    }

    function _assertRedeemEpoch(
        uint256 epochId
    ) internal view {
        LpRedeemEpoch storage expected = redeemEpochs[epochId];
        (bool success, bytes memory data) = address(junior).staticcall(abi.encodeCall(junior.redeemEpochs, (epochId)));
        assertTrue(success, "redemption epoch getter");
        TrancheVault.RedeemEpoch memory actual = abi.decode(data, (TrancheVault.RedeemEpoch));
        assertEq(actual.shares, expected.shares, "epoch original redemption basis");
        assertEq(actual.fundedShares, expected.fundedShares, "epoch cumulative funded shares");
        assertEq(actual.fundedAssets, expected.fundedAssets, "epoch cumulative funded cash");
        assertEq(actual.claimedShares, expected.claimedShares, "epoch consumed shares including terminal dust");
        assertEq(actual.claimedAssets, expected.claimedAssets, "epoch consumed cash including terminal dust");
        assertEq(
            actual.refundableShares,
            expected.refundable ? expected.shares - expected.fundedShares : 0,
            "epoch refund basis"
        );
        assertEq(actual.refundedShares, expected.refundedShares, "epoch refunded shares including terminal dust");
        assertEq(actual.fundingBasisClaimed, expected.fundingBasisClaimed, "epoch funding acknowledgements");
        assertEq(actual.refundBasisClaimed, expected.refundBasisClaimed, "epoch refund acknowledgements");
        assertEq(actual.refundEnabled, expected.refundable, "epoch refund classification");
    }

    function _assertLpModel() internal view returns (uint256 vaultCash, uint256 wallets) {
        uint256 pending;
        uint256 depositClaims = expectedDepositDustShares;
        uint256 redemptionClaims = expectedRedeemDustAssets;
        uint256 ownedShares = expectedJuniorSeedShares;
        for (uint256 i; i < 2; ++i) {
            Lp storage lp = lps[i];
            address account = lpAt(i);
            pending += lp.pending;
            depositClaims += lp.claimShares;
            ownedShares += lp.shares;
            redemptionClaims += lp.claimRedeemAssets;
            wallets += lp.wallet;
            assertEq(junior.balanceOf(account), lp.shares, "mixed LP share ownership");
            assertEq(usdc.balanceOf(account), lp.wallet, "mixed LP cancellation and redemption custody");
            assertEq(junior.lastDepositTime(account), lp.lastDepositTime, "mixed independent LP cooldown");
            if (lp.epoch != 0) {
                assertEq(junior.pendingDepositRequest(lp.epoch, account), lp.pending, "mixed pending deposit ownership");
                assertEq(junior.claimableDepositRequest(lp.epoch, account), lp.claimAssets, "mixed deposit claim basis");
                assertEq(
                    junior.claimableDepositShares(lp.epoch, account), lp.claimShares, "mixed independent share quote"
                );
            }
            assertEq(
                junior.controllerRedeemHead(account),
                lp.redeemQueued ? lp.redeemEpoch : 0,
                "mixed controller redemption head"
            );
            assertEq(
                junior.controllerRedeemTail(account),
                lp.redeemQueued ? lp.redeemEpoch : 0,
                "mixed controller redemption tail"
            );
            if (lp.redeemEpoch != 0) {
                _assertRedeemPosition(lp, account);
                assertEq(
                    junior.redeemRefundPending(lp.redeemEpoch, account),
                    redeemEpochs[lp.redeemEpoch].refundable && lp.redeemBasis != 0 && !lp.redeemRefundClaimed,
                    "mixed zero-entitlement refund acknowledgement"
                );
                assertEq(
                    junior.pendingRedeemRequest(lp.redeemEpoch, account),
                    lp.pendingRedeemShares,
                    "mixed pending redemption ownership"
                );
                assertEq(
                    junior.claimableRedeemRequest(lp.redeemEpoch, account),
                    lp.claimRedeemShares,
                    "mixed claimable redemption shares"
                );
                assertEq(
                    junior.claimableRedeemAssets(lp.redeemEpoch, account),
                    lp.claimRedeemAssets,
                    "mixed independently priced redemption cash"
                );
                assertEq(
                    junior.refundableRedeemRequest(lp.redeemEpoch, account),
                    lp.refundableRedeemShares,
                    "mixed independently priced redemption refund"
                );
            }
        }
        for (uint256 e; e < modeledRedeemEpochIds.length; ++e) {
            _assertRedeemEpoch(modeledRedeemEpochIds[e]);
        }
        vaultCash = pending + redemptionClaims;
        assertEq(usdc.balanceOf(address(junior)), vaultCash, "mixed complete LP cash escrow");
        assertEq(junior.pendingDepositEscrowAssets(), pending, "mixed pending deposit escrow");
        assertEq(junior.withdrawalEscrowAssets(), redemptionClaims, "mixed redemption entitlement and dust escrow");
        assertEq(
            junior.pendingRedeemEscrowShares(),
            expectedPendingRedeemEscrowShares,
            "mixed exact pending and refundable redemption share escrow"
        );
        assertEq(junior.depositClaimEscrowShares(), depositClaims, "mixed deposit entitlement and dust escrow");
        assertEq(
            junior.balanceOf(address(junior)),
            depositClaims + expectedPendingRedeemEscrowShares,
            "mixed complete LP share escrow"
        );
        assertEq(junior.totalSupply(), expectedJuniorSupply, "mixed independently priced supply");
        assertEq(
            ownedShares + depositClaims + expectedPendingRedeemEscrowShares,
            expectedJuniorSupply,
            "mixed every issued share has an owner including unallocated dust"
        );
        assertEq(junior.balanceOf(seedOwner), expectedJuniorSeedShares, "Junior seed and refunded rounding shares");
        assertEq(senior.totalSupply(), 500_000e9, "fixed Senior owners");
        assertEq(senior.balanceOf(seedOwner), 500_000e9, "fixed Senior seed owner");
    }

}
