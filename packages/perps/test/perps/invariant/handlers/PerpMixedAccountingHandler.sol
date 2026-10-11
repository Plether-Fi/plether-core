// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {RecordedOrderReceipts} from "../../../utils/RecordedOrderReceipts.sol";
import {CarryReferenceLedger} from "../ghost/CarryReferenceLedger.sol";
import {WaterfallReferenceMath} from "../ghost/WaterfallReferenceMath.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

/// @notice Persistent public-Router campaign joining carry, exact basis, VPI, claims, and delayed Junior deposits.
/// @dev Four traders and two LPs are the complete actor domain. Expected state comes only from initialization and
/// submitted actions, never previews, receipts, production math, or balance deltas. Receipts authenticate outcomes.
/// Generated partial closes retain ample collateral; the deterministic shortage history separately proves deferred
/// claims and claim-backed partial closes. Senior owners and maintenance-free Junior seed shares stay fixed.
contract PerpMixedAccountingHandler is RecordedOrderReceipts {

    uint256 internal constant CAP = 2e8;
    uint256 internal constant INITIAL_CASH = 100_000e6;
    address public constant KEEPER = address(0xAA7700);

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
        uint256 assetDust;
        uint256 refundDust;
        bool refundable;
    }

    struct CloseValues {
        uint256 closedBasis;
        uint256 released;
        uint256 consumedClaim;
        uint256 consumedMargin;
        uint256 payout;
        uint256 paidRebate;
        uint256 fee;
        uint256 spread;
        uint256 creditedFee;
        int256 vpi;
        int256 pnl;
        int256 proportionalVpi;
        int256 action;
        uint256 gain;
        uint256 withheld;
        uint256 cashCharge;
        uint256 feeFromCash;
        uint256 available;
        bool deferred;
        uint256 paidGain;
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
        carry = new CarryReferenceLedger(expectedPoolCash, vm.getBlockTimestamp(), 500);
        vm.deal(address(this), 100_000 ether);
        vm.deal(KEEPER, 100_000 ether);
        for (uint256 i; i < 4; ++i) {
            address account = actorAt(i);
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
        if (redeemEpochs[lp.redeemEpoch].refundable && !lp.redeemRefundClaimed) {
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
                || lp.claimRedeemShares != 0 || lp.refundableRedeemShares != 0
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
        lp.redeemFundingClaimed = false;
        lp.redeemRefundClaimed = false;
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
                uint256 entitledShares = lp.redeemBasis * epoch.fundedShares / epoch.shares;
                lp.claimRedeemShares = entitledShares;
                lp.claimRedeemAssets = entitledShares == 0 ? 0 : lp.redeemBasis * epoch.fundedAssets / epoch.shares;
                lp.pendingRedeemShares = epoch.refundable ? 0 : lp.redeemBasis - entitledShares;
                allocatedAssets += lp.claimRedeemAssets;
                if (epoch.refundable) {
                    lp.refundableRedeemShares = lp.redeemBasis * (epoch.shares - epoch.fundedShares) / epoch.shares;
                    allocatedRefunds += lp.refundableRedeemShares;
                }
            }
        }
        expectedRedeemDustAssets = expectedRedeemDustAssets - epoch.assetDust + epoch.fundedAssets - allocatedAssets;
        epoch.assetDust = epoch.fundedAssets - allocatedAssets;
        if (epoch.refundable) {
            epoch.refundDust = epoch.shares - epoch.fundedShares - allocatedRefunds;
        }
    }

    function claimJuniorRedeem(
        uint256 lpSeed
    ) external {
        uint256 i = lpSeed % 2;
        Lp storage lp = lps[i];
        if (lp.redeemBasis == 0) {
            return;
        }
        LpRedeemEpoch storage epoch = redeemEpochs[lp.redeemEpoch];
        // Partial-funding entitlements are checked after every settlement. Claims wait for the terminal epoch,
        // bounding controller histories while still testing successive funding rounds and exact pro-rata ownership.
        if (!epoch.refundable && epoch.fundedShares != epoch.shares) {
            return;
        }
        if (!lp.redeemFundingClaimed && lp.claimRedeemShares != 0) {
            vm.prank(lpAt(i));
            uint256 assets = junior.claimRedeem(lp.redeemEpoch, lp.claimRedeemShares, lpAt(i), lpAt(i));
            assertEq(assets, lp.claimRedeemAssets, "independent redemption cash entitlement");
            lp.wallet += lp.claimRedeemAssets;
            lp.claimRedeemShares = 0;
            lp.claimRedeemAssets = 0;
            _finishRedeemFunding(lp, epoch);
            ++lpRedemptionClaims;
        }
        if (epoch.refundable && !lp.redeemRefundClaimed) {
            vm.prank(lpAt(i));
            uint256 shares = junior.claimRedeemRefund(lp.redeemEpoch, lpAt(i), lpAt(i));
            assertEq(shares, lp.refundableRedeemShares, "independent worthless remainder refund");
            if (!lp.redeemFundingClaimed) {
                _finishRedeemFunding(lp, epoch);
            }
            lp.shares += shares;
            expectedPendingRedeemEscrowShares -= shares;
            lp.refundableRedeemShares = 0;
            lp.redeemRefundClaimed = true;
            if (shares != 0) {
                lp.lastDepositTime = vm.getBlockTimestamp();
            }
            if (--epoch.refundClaimsRemaining == 0) {
                expectedJuniorSeedShares += epoch.refundDust;
                expectedPendingRedeemEscrowShares -= epoch.refundDust;
                epoch.refundDust = 0;
            }
            ++lpRedemptionRefunds;
        }
        assertModel();
    }

    function _finishRedeemFunding(
        Lp storage lp,
        LpRedeemEpoch storage epoch
    ) internal {
        lp.redeemFundingClaimed = true;
        if (--epoch.fundingClaimsRemaining == 0) {
            expectedPoolCash += epoch.assetDust;
            expectedRedeemDustAssets -= epoch.assetDust;
            returnedRedemptionDustAssets += epoch.assetDust;
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
        _deposit(3, arrears + 1000e6);
        assertEq(carry.accountState(actorAt(3)).arrears, 0, "new deposit pays old carry before becoming spendable");
        _collect(3);
        vm.prank(actorAt(3));
        engine.addMargin(actorAt(3), 500e6);
        traders[3].margin += 500e6;
        _apply(3);
        _liquidateShort(3);
        _withdraw(3, traders[3].cash);
        _rejectExcessWithdrawal(3);
        _deposit(3, 1000e6);
        _refresh(120_000_001);
        _trade(3, 100, 300e6, false);
        _liquidateShort(3);
        _withdraw(3, traders[3].cash);
        _rejectExcessWithdrawal(3);
        assertEq(generations[3], 2, "same address completes two liquidation generations");
        assertModel();
    }

    /// @notice Generated same-address liquidation generations; economically healthy existing shorts are left intact.
    function liquidateAndReuse(
        uint256 actorSeed
    ) external {
        if (frozen) {
            return;
        }
        uint256 i = 1 + (actorSeed % 2) * 2;
        if (traders[i].claim != 0) {
            return;
        }
        if (traders[i].lots == 0) {
            if (_free(i) < 1000e6) {
                _deposit(i, 1000e6);
            }
            _refresh(120_000_002);
            _trade(i, 100, 300e6, false);
        }
        if (traders[i].basis <= traders[i].lots * 60_000_000 + traders[i].margin) {
            return;
        }
        _liquidateShort(i);
        _withdraw(i, traders[i].cash);
        _rejectExcessWithdrawal(i);
        assertModel();
    }

    function withdrawFreeCollateral(
        uint256 actorSeed,
        uint256 amountSeed
    ) external {
        uint256 i = actorSeed % 4;
        if (traders[i].lots != 0 || traders[i].cash == 0) {
            return;
        }
        _withdraw(i, bound(amountSeed, 1, traders[i].cash));
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

    function _liquidateShort(
        uint256 i
    ) internal {
        _refresh(60_000_001);
        _collect(i);
        Trader storage t = traders[i];
        assertEq(i % 2, 1);
        assertGt(t.basis - t.lots * currentPrice, t.margin + t.claim, "independently insolvent price loss");
        assertEq(t.claim, 0, "liquidation prelude claim domain");
        assertEq(carry.accountState(actorAt(i)).arrears, 0, "arrears already paid before liquidation");
        uint256 charge = t.lots * currentPrice / 1000;
        if (charge < 1e6) {
            charge = 1e6;
        }
        if (charge > t.liquidationReserve) {
            charge = t.liquidationReserve;
        }
        uint256 keeperPart = charge / 2;
        uint256 clawback = t.vpi < 0 ? uint256(-t.vpi) : 0;
        bytes[] memory updateData = _prices(currentPrice);
        vm.prank(KEEPER);
        router.executeLiquidation{value: 1}(actorAt(i), updateData);
        uint256 toPool = t.margin + charge - keeperPart + clawback;
        expectedPoolCash += toPool;
        expectedAccounted += toPool;
        expectedKeeper += keeperPart;
        t.cash -= t.margin + charge + clawback;
        sideLots[i % 2] -= t.lots;
        t.lots = 0;
        t.basis = 0;
        t.margin = 0;
        t.vpi = 0;
        t.liquidationReserve = 0;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        _apply(i);
        ++liquidations;
        ++generations[i];
        assertModel();
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
        return t.cash - t.margin - t.liquidationReserve - (t.vpi < 0 ? uint256(-t.vpi) : 0);
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
            t.liquidationReserve + (t.vpi < 0 ? uint256(-t.vpi) : 0),
            t.lots != 0,
            vm.getBlockTimestamp()
        );
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
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(2));
        pyth.setAllUniquePrices(ids, int64(int256(price)), 0, -8, vm.getBlockTimestamp(), vm.getBlockTimestamp() - 1);
        data = new bytes[](1);
        data[0] = abi.encode(price);
    }

    function _refresh(
        uint256 price
    ) internal {
        router.updateMarkPrice{value: 1}(_prices(price));
        carry.advance(vm.getBlockTimestamp());
        currentPrice = 2 * (price / 2);
    }

    function _trade(
        uint256 i,
        uint256 lots,
        uint256 contribution,
        bool isClose
    ) internal {
        uint256 bounty = isClose ? 200_000 : lots * currentPrice / 10_000;
        if (bounty > 200_000) {
            bounty = 200_000;
        }
        if (bounty < 10_000) {
            bounty = 10_000;
        }
        OrderV3Types.OrderRequest memory request;
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
        bool belowMinimum =
            isClose ? lots < traders[i].lots && lots * currentPrice < 1000e6 : lots * currentPrice < 100e6;
        if (belowMinimum) {
            // Router size admission precedes all collateral checkpoints and reservations.
            vm.prank(actorAt(i));
            vm.expectRevert(
                abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CommitValidation.selector, uint8(11))
            );
            router.commitOrder(request);
            ++rejectedSmallOrders;
            assertModel();
            return;
        }
        _collect(i); // Public commitment checkpoints active carry before reserving bounty and margin.
        vm.prank(actorAt(i));
        uint64 id = router.commitOrder(request);
        // The preceding checkpoint has modeled commitment collection; this step classifies its new locks.
        carry.reserveWithoutCheckpoint(actorAt(i), contribution + bounty);
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        _collect(i);
        int256 vpi = _vpi(i, lots, isClose);
        bytes[] memory updateData = _prices(currentPrice);
        _startRecordingLogs();
        vm.prank(KEEPER);
        router.executeOrder{value: 1}(id, updateData);
        OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), id);
        assertEq(
            uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed), "modeled public order must execute"
        );
        assertEq(receipt.executionPrice, currentPrice, "authenticated modeled price");
        assertEq(receipt.bountyUsdc, bounty, "independent keeper entitlement");
        assertEq(receipt.bountyRecipient, KEEPER);
        IMarginClearinghouse.BountyReservation memory bountyReservation =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        assertEq(bountyReservation.amountUsdc, 0, "executed bounty reservation emptied");
        assertEq(
            uint8(bountyReservation.state),
            uint8(IMarginClearinghouse.BountyReservationState.Settled),
            "authenticated keeper bounty settles exactly once"
        );
        assertEq(clearinghouse.getOrderReservation(id).remainingAmountUsdc, 0, "executed order margin released");
        if (isClose) {
            _bookClose(i, lots, vpi);
        } else {
            _bookOpen(i, lots, contribution, vpi);
        }
        traders[i].cash -= bounty;
        expectedKeeper += bounty;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        _apply(i);
    }

    function _vpi(
        uint256 i,
        uint256 lots,
        bool closing
    ) internal view returns (int256) {
        if (_depth() == 0) {
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
        return int256((afterSkew * currentPrice) ** 2 / (400 * _depth()))
            - int256((beforeSkew * currentPrice) ** 2 / (400 * _depth()));
    }

    function _bookOpen(
        uint256 i,
        uint256 lots,
        uint256 contribution,
        int256 vpi
    ) internal {
        Trader storage t = traders[i];
        uint256 fee = lots * currentPrice * 4 / 10_000;
        int256 cost = vpi + int256(fee);
        uint256 reserve = (t.lots + lots) * currentPrice / 1000;
        if (reserve < t.liquidationReserve) {
            reserve = t.liquidationReserve;
        }
        if (reserve < 1e6) {
            reserve = 1e6;
        }
        t.margin += contribution - (cost > 0 ? uint256(cost) : 0) - (reserve - t.liquidationReserve);
        t.liquidationReserve = reserve;
        t.cash = uint256(int256(t.cash) - cost);
        expectedPoolCash = uint256(int256(expectedPoolCash) + vpi);
        expectedAccounted = uint256(int256(expectedAccounted) + vpi);
        expectedTreasury += fee;
        if (t.lots == 0) {
            ++successfulOpens;
        } else {
            ++successfulIncreases;
        }
        t.lots += lots;
        t.basis += lots * currentPrice;
        t.vpi += vpi;
        sideLots[i % 2] += lots;
        _countVpi(vpi);
    }

    function _bookClose(
        uint256 i,
        uint256 lots,
        int256 vpi
    ) internal {
        Trader storage t = traders[i];
        CloseValues memory c;
        c.closedBasis = t.basis * lots / t.lots;
        c.proportionalVpi = t.vpi * int256(lots) / int256(t.lots);
        if (vpi + c.proportionalVpi < 0) {
            vpi = -c.proportionalVpi;
        }
        c.vpi = vpi;
        c.pnl = int256(c.closedBasis) - int256(lots * currentPrice);
        if (i % 2 != 0) {
            c.pnl = -c.pnl;
        }
        c.fee = lots * currentPrice * 4 / 10_000;
        c.spread = frozen ? lots * currentPrice / 200 : 0;
        c.released = t.margin * lots / t.lots;
        uint256 oldClaim = t.claim;
        if (c.pnl < 0) {
            uint256 loss = uint256(-c.pnl);
            c.consumedClaim = oldClaim < loss ? oldClaim : loss;
            loss -= c.consumedClaim;
            c.consumedMargin = loss < c.released ? loss : c.released;
            // This campaign's generated partials remain healthy and fully fund their proportional price loss.
            if (lots < t.lots) {
                assertEq(c.consumedMargin, loss, "partial loss domain must be fully funded");
            }
            t.claim -= c.consumedClaim;
            expectedClaims -= c.consumedClaim;
        }
        c.action = vpi + int256(c.fee + c.spread);
        c.gain = c.pnl > 0 ? uint256(c.pnl) : 0;
        c.withheld = c.action > 0 ? uint256(c.action) : 0;
        if (c.withheld > c.gain) {
            c.withheld = c.gain;
        }
        c.cashCharge = c.action > 0 ? uint256(c.action) - c.withheld : 0;
        if (lots == t.lots) {
            // A terminal close can spend every released bucket except the committed execution bounty. Price-loss
            // pledge has already been consumed separately. Charges beyond physical cash are explicitly waived.
            uint256 capacity = t.cash - c.consumedMargin - 200_000;
            if (c.cashCharge > capacity) {
                waivedActionCharges += c.cashCharge - capacity;
                c.cashCharge = capacity;
            }
        }
        _allocateCloseFee(c);
        c.available = expectedPoolCash + c.consumedMargin + c.cashCharge - c.feeFromCash;
        c.payout = c.gain - c.withheld;
        c.deferred = c.payout > (c.available > expectedClaims ? c.available - expectedClaims : 0);
        if (c.deferred) {
            t.claim += c.payout;
            expectedClaims += c.payout;
            ++deferredClaims;
        } else {
            c.available -= c.payout;
        }
        if (c.action < 0) {
            uint256 freeCash = c.available > expectedClaims ? c.available - expectedClaims : 0;
            c.paidRebate = uint256(-c.action) < freeCash ? uint256(-c.action) : freeCash;
            c.available -= c.paidRebate;
        }
        uint256 topup = c.creditedFee - c.feeFromCash;
        uint256 freeForFee = c.available > expectedClaims ? c.available - expectedClaims : 0;
        if (topup > freeForFee) {
            topup = freeForFee;
        }
        c.creditedFee = c.feeFromCash + topup;
        c.available -= topup;
        int256 poolDelta = int256(c.available) - int256(expectedPoolCash);
        expectedPoolCash = c.available;
        expectedAccounted = uint256(int256(expectedAccounted) + poolDelta);
        expectedTreasury += c.creditedFee;
        c.paidGain = c.deferred ? 0 : c.payout;
        t.cash = t.cash - c.consumedMargin - c.cashCharge + c.paidGain + c.paidRebate;
        t.margin -= c.released;
        if (lots < t.lots) {
            t.margin += c.paidGain;
        }
        t.lots -= lots;
        t.basis -= c.closedBasis;
        t.vpi -= c.proportionalVpi;
        sideLots[i % 2] -= lots;
        uint256 reserve = t.lots == 0 ? 0 : t.lots * currentPrice / 1000;
        if (t.lots != 0 && reserve < 1e6) {
            reserve = 1e6;
        }
        if (reserve < t.liquidationReserve) {
            t.liquidationReserve = reserve;
        }
        if (t.lots == 0) {
            ++fullCloses;
        } else {
            ++partialCloses;
        }
        if (frozen) {
            ++frozenCloses;
        }
        _countVpi(vpi);
    }

    function _allocateCloseFee(
        CloseValues memory c
    ) internal pure {
        uint256 clawback = c.proportionalVpi < 0 ? uint256(-c.proportionalVpi) : 0;
        uint256 clawbackWithheld = c.withheld < clawback ? c.withheld : clawback;
        uint256 clawbackCash = clawback - clawbackWithheld;
        uint256 feeEligible = c.withheld - clawbackWithheld + c.cashCharge - clawbackCash;
        c.creditedFee = feeEligible < c.fee ? feeEligible : c.fee;
        uint256 nonClawbackWithheld = c.withheld - clawbackWithheld;
        uint256 feeWithheld = c.creditedFee < nonClawbackWithheld ? c.creditedFee : nonClawbackWithheld;
        c.feeFromCash = c.creditedFee - feeWithheld;
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
        (expectedSenior, expectedJunior, expectedHwm) = _projectLpCapital();
        expectedCouponTime = vm.getBlockTimestamp();
    }

    function assertModel() public view {
        if (nonce != 0) {
            assertEq(engine.lastMarkPrice(), currentPrice, "mixed input-derived cached mark");
        }
        uint256 custody = expectedTreasury + expectedKeeper;
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
            assertEq(router.accountHeadOrderId(account), 0, "completed generation leaves no queued order");
            assertEq(router.pendingOrderCounts(account), 0, "completed public action leaves no pending order");
            IMarginClearinghouse.AccountReservationSummary memory reservations =
                clearinghouse.getAccountReservationSummary(account);
            assertEq(reservations.activeCommittedOrderMarginUsdc, 0, "completed action releases order margin");
            assertEq(reservations.activeReservationCount, 0, "completed action unlinks every reservation");
            assertEq(
                clearinghouse.actionReserveUsdc(account),
                t.vpi < 0 ? uint256(-t.vpi) : 0,
                "only modeled lifetime VPI remains reserved"
            );
            custody += t.cash;
            wallets += t.wallet;
            expectedSideMargin[i % 2] += t.margin;
        }
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
            if (lp.redeemEpoch != 0) {
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
