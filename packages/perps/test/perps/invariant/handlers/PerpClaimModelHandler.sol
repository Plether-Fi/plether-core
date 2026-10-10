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

/// @notice Persistent claim reference model for funded, whole-position trades at a fixed timestamp.
/// @dev Expected claims use only this ledger and submitted lots/prices/fee rate. No planner, preview, event, or
///      production claim balance supplies an expected value. Router authorization and the real LP waterfall are
///      outside this Engine-settlement harness; its mock pool deliberately controls physical payout liquidity.
contract PerpClaimModelHandler is Test {

    uint256 internal constant LOTS = 100;
    uint256 internal constant ENTRY_PRICE = 1e8;
    uint256 internal constant PRICE_MOVE = 0.5e8;
    uint256 internal constant PNL_USDC = LOTS * PRICE_MOVE;
    uint256 internal constant MARGIN_USDC = 20_000e6;

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
        (bool ok, bytes memory err) = _trade(account, side, ENTRY_PRICE, false);
        if (!ok) {
            _unexpected(err);
            return;
        }
        expectedOpen[account] = true;
        expectedSide[account] = side;
        successfulOpens++;
        uint256 fee = LOTS * ENTRY_PRICE * feeBps / 10_000;
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
        uint256 poolBefore = liquidPool ? expectedTotalClaims + 100_000_000e6 : 0;
        pool.setAssets(poolBefore);
        CfdTypes.Side side = expectedSide[account];
        bool lowerPrice = profitable == (side == CfdTypes.Side.LONG);
        uint256 price = lowerPrice ? ENTRY_PRICE - PRICE_MOVE : ENTRY_PRICE + PRICE_MOVE;
        uint256 fee = LOTS * price * feeBps / 10_000;
        uint256 claimBefore = expectedClaim[account];
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);

        (bool ok, bytes memory err) = _trade(account, side, price, true);
        if (!ok) {
            _unexpected(err);
            return;
        }
        expectedOpen[account] = false;
        uint256 expectedPoolAfter = poolBefore;
        uint256 expectedSettlementAfter = settlementBefore;
        if (profitable) {
            uint256 payout = PNL_USDC - fee;
            if (liquidPool) {
                immediateCloses++;
                expectedPoolAfter -= PNL_USDC;
                expectedSettlementAfter += payout;
            } else {
                deferredCloses++;
                expectedClaim[account] += payout;
                expectedTotalClaims += payout;
            }
        } else {
            lossCloses++;
            uint256 consumedClaim = claimBefore < PNL_USDC ? claimBefore : PNL_USDC;
            expectedClaim[account] -= consumedClaim;
            expectedTotalClaims -= consumedClaim;
            claimConsumptionUsdc += consumedClaim;
            uint256 collectedPledge = PNL_USDC - consumedClaim;
            expectedPoolAfter += collectedPledge;
            expectedSettlementAfter -= collectedPledge + fee;
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
            // All reference positions have 100 lots at the submitted 1e8 entry, with a 2e8 price cap.
            if (expectedSide[account] == CfdTypes.Side.LONG) {
                longLiability += LOTS * ENTRY_PRICE;
            } else {
                shortLiability += LOTS * (2e8 - ENTRY_PRICE);
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
            (uint256 size,,,,,,) = engine.positions(account);
            if (size != (expectedOpen[account] ? LOTS * CfdTypes.SIZE_QUANTUM : 0)) {
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
        uint256 price,
        bool isClose
    ) internal returns (bool, bytes memory) {
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: LOTS * CfdTypes.SIZE_QUANTUM,
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
