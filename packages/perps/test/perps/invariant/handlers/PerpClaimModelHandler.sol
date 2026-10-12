// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MockInvariantHousePool} from "../mocks/MockInvariantHousePool.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Persistent claim and withdrawal-reserve model for funded whole-position trades at a fixed timestamp.
/// @dev Expected claims use only this ledger and submitted lots/prices/fee rate. No planner, preview, event, or
///      production claim balance supplies an expected value. Router authorization and the real LP waterfall are
///      outside this Engine-settlement harness; its mock pool deliberately controls physical payout liquidity.
///      Generated entries span 17–251 lots and $0.80000001–$1.20000003, including exact-basis and buffer dust.
contract PerpClaimModelHandler is Test {

    uint256 internal constant PRICE_MOVE = 0.5e8;
    uint256 internal constant MARGIN_USDC = 20_000e6;
    uint256 internal constant CAP_PRICE = 2e8;

    struct CloseAmounts {
        uint256 lots;
        uint256 price;
        uint256 fee;
        uint256 pnl;
        uint256 poolBefore;
        uint256 settlementBefore;
    }

    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    MockInvariantHousePool public immutable pool;
    MockUSDC public immutable usdc;
    address public immutable router;
    uint256 public immutable feeBps;
    uint256 public immutable bufferBps;
    CfdEngineProtocolLens public immutable protocolLens;
    address[3] internal accounts = [address(0xC1A101), address(0xC1A102), address(0xC1A103)];

    mapping(address => uint256) public expectedClaim;
    mapping(address => bool) public expectedOpen;
    mapping(address => CfdTypes.Side) public expectedSide;
    mapping(address => uint256) public expectedLots;
    mapping(address => uint256) public expectedEntryCostUsdc;
    uint256 public expectedTotalClaims;
    uint256 public attempts;
    uint256 public skipped;
    uint256 public successfulOpens;
    uint256 public deferredCloses;
    uint256 public immediateCloses;
    uint256 public lossCloses;
    uint256 public claimConsumptionUsdc;
    uint256 public successfulSettlements;
    uint256 public livePositionSettlements;
    uint256 public expectedRejections;
    uint256 public unexpectedFailures;
    bytes4 public lastUnexpectedSelector;
    bool public cashMismatch;

    error WithdrawalReserveMismatch(uint256 expected, uint256 actual);
    error ClaimModelMismatch(address account, uint256 expected, uint256 actual);
    error ClaimTotalMismatch(uint256 expected, uint256 actual);
    error PositionModelMismatch(address account);

    constructor(
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        MockInvariantHousePool pool_,
        MockUSDC usdc_,
        address router_
    ) {
        engine = engine_;
        clearinghouse = clearinghouse_;
        pool = pool_;
        usdc = usdc_;
        router = router_;
        feeBps = engine_.executionFeeBps();
        bufferBps = engine_.settlementBufferBps();
        protocolLens = new CfdEngineProtocolLens(address(engine_));
    }

    function accountAt(
        uint256 index
    ) external view returns (address) {
        return accounts[index];
    }

    function open(
        uint256 actorSeed,
        bool shortSide
    ) external {
        _open(actorSeed, shortSide, 100, 1e8);
    }

    /// @notice Broader entry domain for persistent reserve and claim transitions, retaining the fixed examples above.
    function openAt(
        uint256 actorSeed,
        bool shortSide,
        uint256 lotsSeed,
        uint256 entryPriceSeed
    ) external {
        _open(actorSeed, shortSide, bound(lotsSeed, 17, 251), bound(entryPriceSeed, 80_000_001, 120_000_003));
    }

    function _open(
        uint256 actorSeed,
        bool shortSide,
        uint256 lots,
        uint256 entryPrice
    ) internal {
        address account = accounts[actorSeed % accounts.length];
        if (expectedOpen[account]) {
            skipped++;
            return;
        }
        attempts++;
        // Replenishment is an explicit environment input, not a repair of any expected claim balance.
        pool.setAssets(expectedTotalClaims + 1_000_000_000e6);
        if (engine.degradedMode()) {
            vm.prank(engine.owner());
            engine.clearDegradedMode();
        }
        usdc.mint(account, 100_000e6);
        vm.startPrank(account);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(account, 100_000e6);
        vm.stopPrank();

        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 poolBefore = usdc.balanceOf(address(pool));
        (bool ok, bytes memory err) = _trade(account, side, lots, entryPrice, false);
        if (!ok) {
            _unexpected(err);
            return;
        }
        expectedOpen[account] = true;
        expectedSide[account] = side;
        expectedLots[account] = lots;
        expectedEntryCostUsdc[account] = lots * entryPrice;
        successfulOpens++;
        uint256 fee = lots * entryPrice * feeBps / 10_000;
        cashMismatch = cashMismatch || clearinghouse.balanceUsdc(account) != settlementBefore - fee
            || usdc.balanceOf(address(pool)) != poolBefore;
    }

    function close(
        uint256 actorSeed,
        bool profitable,
        bool liquidPool
    ) external {
        address account = accounts[actorSeed % accounts.length];
        if (!expectedOpen[account]) {
            skipped++;
            return;
        }
        attempts++;
        CloseAmounts memory amounts;
        amounts.poolBefore = liquidPool ? expectedTotalClaims + 100_000_000e6 : 0;
        pool.setAssets(amounts.poolBefore);
        amounts.lots = expectedLots[account];
        {
            bool lowerPrice = profitable == (expectedSide[account] == CfdTypes.Side.LONG);
            uint256 entryPrice = expectedEntryCostUsdc[account] / amounts.lots;
            amounts.price = lowerPrice ? entryPrice - PRICE_MOVE : entryPrice + PRICE_MOVE;
        }
        amounts.fee = amounts.lots * amounts.price * feeBps / 10_000;
        amounts.pnl = amounts.lots * PRICE_MOVE;
        amounts.settlementBefore = clearinghouse.balanceUsdc(account);

        (bool ok, bytes memory err) = _trade(account, expectedSide[account], amounts.lots, amounts.price, true);
        if (!ok) {
            _unexpected(err);
            return;
        }
        expectedOpen[account] = false;
        delete expectedLots[account];
        delete expectedEntryCostUsdc[account];
        uint256 expectedPoolAfter = amounts.poolBefore;
        uint256 expectedSettlementAfter = amounts.settlementBefore;
        if (profitable) {
            uint256 payout = amounts.pnl - amounts.fee;
            if (liquidPool) {
                immediateCloses++;
                expectedPoolAfter -= amounts.pnl;
                expectedSettlementAfter += payout;
            } else {
                deferredCloses++;
                expectedClaim[account] += payout;
                expectedTotalClaims += payout;
            }
        } else {
            lossCloses++;
            uint256 claim = expectedClaim[account];
            uint256 consumedClaim = claim < amounts.pnl ? claim : amounts.pnl;
            expectedClaim[account] -= consumedClaim;
            expectedTotalClaims -= consumedClaim;
            claimConsumptionUsdc += consumedClaim;
            uint256 collectedPledge = amounts.pnl - consumedClaim;
            expectedPoolAfter += collectedPledge;
            expectedSettlementAfter -= collectedPledge + amounts.fee;
        }
        cashMismatch = cashMismatch || usdc.balanceOf(address(pool)) != expectedPoolAfter
            || clearinghouse.balanceUsdc(account) != expectedSettlementAfter;
    }

    /// @dev Modes cover zero, own-claim-only, global-short-by-one, exact-global, and surplus liquidity.
    function settle(
        uint256 actorSeed,
        uint8 liquidityMode
    ) external {
        address account = accounts[actorSeed % accounts.length];
        uint256 claim = expectedClaim[account];
        uint256 mode = liquidityMode % 5;
        uint256 cash = mode == 0
            ? 0
            : mode == 1
                ? claim
                : mode == 2
                    ? (expectedTotalClaims == 0 ? 0 : expectedTotalClaims - 1)
                    : expectedTotalClaims + (mode == 4 ? 1e6 : 0);
        pool.setAssets(cash);
        attempts++;
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 pledgeBefore = clearinghouse.getPnlIsolationBuckets(account).pnlPledgeUsdc;
        vm.prank(account);
        (bool ok, bytes memory err) = address(engine).call(abi.encodeCall(engine.settleTraderClaim, (account)));
        bytes4 expectedError = claim == 0
            ? ICfdEngineTypes.CfdEngine__NoTraderClaim.selector
            : cash < expectedTotalClaims ? ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector : bytes4(0);
        if (expectedError != bytes4(0)) {
            if (ok || _selector(err) != expectedError) {
                _unexpected(err);
            } else {
                expectedRejections++;
            }
            cashMismatch = cashMismatch || usdc.balanceOf(address(pool)) != cash
                || clearinghouse.balanceUsdc(account) != settlementBefore
                || clearinghouse.getPnlIsolationBuckets(account).pnlPledgeUsdc != pledgeBefore;
            return;
        }
        if (!ok) {
            _unexpected(err);
            return;
        }
        expectedClaim[account] = 0;
        expectedTotalClaims -= claim;
        successfulSettlements++;
        if (expectedOpen[account]) {
            livePositionSettlements++;
        }
        uint256 expectedPledge = pledgeBefore + (expectedOpen[account] ? claim : 0);
        cashMismatch = cashMismatch || usdc.balanceOf(address(pool)) != cash - claim
            || clearinghouse.balanceUsdc(account) != settlementBefore + claim
            || clearinghouse.getPnlIsolationBuckets(account).pnlPledgeUsdc != expectedPledge;
    }

    /// @notice Base Engine withdrawal reserve in this mock-pool domain; no tranche/epoch reserves are represented.
    function expectedWithdrawalReserve() public view returns (uint256) {
        uint256 longLiability;
        uint256 shortLiability;
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (!expectedOpen[account]) {
                continue;
            }
            // Endpoint payoffs derive from submitted entries, not Engine side aggregates or displayed averages.
            if (expectedSide[account] == CfdTypes.Side.LONG) {
                longLiability += expectedEntryCostUsdc[account];
            } else {
                shortLiability += expectedLots[account] * CAP_PRICE - expectedEntryCostUsdc[account];
            }
        }
        uint256 liability = longLiability > shortLiability ? longLiability : shortLiability;
        uint256 product = liability * bufferBps;
        uint256 buffer = product / 10_000 + (product % 10_000 == 0 ? 0 : 1);
        return liability + expectedTotalClaims + buffer;
    }

    function checkWithdrawalReserveModel() public view {
        uint256 expected = expectedWithdrawalReserve();
        uint256 actual = protocolLens.getProtocolAccountingSnapshot().withdrawalReservedUsdc;
        if (actual != expected) {
            revert WithdrawalReserveMismatch(expected, actual);
        }
    }

    function checkModel() external view {
        uint256 total;
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            uint256 actual = engine.traderClaimBalanceUsdc(account);
            if (actual != expectedClaim[account]) {
                revert ClaimModelMismatch(account, expectedClaim[account], actual);
            }
            total += expectedClaim[account];
            (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
            if (
                size != expectedLots[account] * CfdTypes.SIZE_QUANTUM
                    || engine.positionEntryCostUsdcAtoms(account) != expectedEntryCostUsdc[account]
                    || (expectedOpen[account] && side != expectedSide[account])
            ) {
                revert PositionModelMismatch(account);
            }
        }
        if (total != expectedTotalClaims) {
            revert ClaimTotalMismatch(expectedTotalClaims, total);
        }
        uint256 liveTotal = engine.totalTraderClaimBalanceUsdc();
        if (expectedTotalClaims != liveTotal) {
            revert ClaimTotalMismatch(expectedTotalClaims, liveTotal);
        }
    }

    function _trade(
        address account,
        CfdTypes.Side side,
        uint256 lots,
        uint256 price,
        bool isClose
    ) internal returns (bool, bytes memory) {
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: lots * CfdTypes.SIZE_QUANTUM,
            marginDelta: isClose ? 0 : MARGIN_USDC,
            targetPrice: price,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: side,
            isClose: isClose
        });
        uint256 depth = pool.totalAssets();
        vm.prank(router);
        return
            address(engine)
                .call(abi.encodeCall(engine.processOrderTyped, (order, price, depth, uint64(block.timestamp))));
    }

    function _unexpected(
        bytes memory err
    ) internal {
        unexpectedFailures++;
        lastUnexpectedSelector = _selector(err);
    }

    function _selector(
        bytes memory err
    ) internal pure returns (bytes4 result) {
        if (err.length >= 4) {
            assembly ("memory-safe") { result := mload(add(err, 32)) }
        }
    }

}
