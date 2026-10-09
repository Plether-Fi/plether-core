// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Historical audit identifiers and test names are retained for traceability.
// The assertions below exercise current behavior; legacy names do not describe unfixed vulnerabilities.

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

// ═══════════════════════════════════════════════════════════════════
// C-01 regression: withdrawal rejects an unhealthy open position
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_C01_WithdrawGuardTest is BasePerpTest {

    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_C01_WithdrawWhilePositionUnderwater() public {
        address aliceAccount = alice;
        _fundTrader(alice, 100_000e6);

        // LONG profits when price drops, loses when price rises
        _open(aliceAccount, CfdTypes.Side.LONG, 500_000e18, 10_000e6, 1e8);

        // Price rises to 1.15e8 → LONG unrealized loss ≈ 75K.
        // The loss exceeds its isolated PnL pledge. Free settlement does not back price-risk equity,
        // so the account cannot withdraw merely because clearinghouse funds are unencumbered.
        uint256 underwaterPrice = 1.15e8;
        vm.prank(address(router));
        engine.updateMarkPrice(underwaterPrice, uint64(block.timestamp));

        uint256 chBalance = clearinghouse.balanceUsdc(aliceAccount);
        uint256 locked = clearinghouse.lockedMarginUsdc(aliceAccount);
        uint256 withdrawable = chBalance - locked;

        // Attempting to withdraw all locally free settlement must fail the Engine health guard.
        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceAccount, withdrawable);
    }

}

// ═══════════════════════════════════════════════════════════════════
// C-02 regression: repeated old-mark reconciliation preserves Senior coupon value
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_C02_ReconcileTimeConsumptionTest is BasePerpTest {

    address alice = address(0xA11CE);

    function refreshMarkPrice() external {
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_C02_FrozenWindowReconcile_DoesNotDestroySeniorCouponCheckpointing() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1000;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        uint256 seniorBefore = pool.seniorPrincipal();

        // Capture the runtime timestamp after asynchronous setup has advanced the shared LP clock.
        uint256 baseTs = block.timestamp;

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(baseTs));

        // Warp past staleness limit, then reconcile repeatedly with stale mark.
        // Use absolute timestamps to avoid optimizer caching timestamp().
        uint256 staleStart = baseTs + 200;
        for (uint256 i = 0; i < 48; i++) {
            vm.warp(staleStart + i * 1 hours);
            vm.prank(address(juniorVault));
            pool.reconcile();
        }

        // Refresh mark at end of stale period
        uint256 freshTs = staleStart + 48 hours;
        vm.warp(freshTs);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTs));

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorAfter = pool.seniorPrincipal();
        assertGe(seniorAfter, seniorBefore, "Frozen-window reconcile should not destroy senior coupon value");
    }

}

// ═══════════════════════════════════════════════════════════════════
// C-03 regression: policy-valid closes execute while oracle-frozen.
// MockPyth supplies the production oracle path with controlled feed data.
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_C03_OracleFrozenCloseTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0xA11CE);

    /// @dev Thursday 2024-03-07 12:00 UTC (weekday, no FAD)
    uint256 constant THURSDAY_NOON = 1_709_812_800;
    /// @dev Saturday 2024-03-09 12:00 UTC (oracle frozen)
    uint256 constant SATURDAY_NOON = 1_709_985_600;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();
        mockPyth.setSynchronizeLegacyUniquePrices(true);

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();

        _fundJunior(address(this), 1_000_000e6);

        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);

        vm.warp(THURSDAY_NOON);
    }

    function test_C03_CloseOrderBlockedDuringOracleFrozen() public {
        address aliceAccount = alice;

        // Open position directly via engine (bypass router oracle timing)
        _open(aliceAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position should be open");

        // Warp to Saturday, which is oracle-frozen under the canonical market calendar.
        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        // Alice commits a close order (commitOrder allows closes even when paused)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        // The frozen close uses the applicable frozen oracle policy and must clear the position.
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        router.executeOrder{value: 0.01 ether}(1, updateData);

        (size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "C-03: close orders must execute during oracle freeze");
    }

}

// ═══════════════════════════════════════════════════════════════════
// H-01 regression: stale live-market marks block new LP deposit requests
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_H01_DepositStaleMark is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_H01_SeniorDepositAtStaleNAV() public {
        _fundSenior(bob, 500_000e6);
        _fundJunior(address(this), 500_000e6);

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        _warpForward(200);

        usdc.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(seniorVault), 100_000e6);

        assertEq(seniorVault.maxRequestDeposit(attacker), 0, "stale mark should zero senior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(100_000e6, attacker);
        vm.stopPrank();
    }

    function test_H01_JuniorDepositAtStaleNAV() public {
        _fundJunior(bob, 500_000e6);

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        _warpForward(200);

        usdc.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 100_000e6);

        assertEq(juniorVault.maxRequestDeposit(attacker), 0, "stale mark should zero junior request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        juniorVault.requestDeposit(100_000e6, attacker);
        vm.stopPrank();
    }

}

// ═══════════════════════════════════════════════════════════════════
// H-02 regression: the frozen oracle age limit permits eligible weekend redemption funding
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_H02_WeekendWithdrawalDoS is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev Friday 2024-03-08 22:30 UTC (oracle frozen, just past FX close)
    uint256 constant FRIDAY_AFTER_CLOSE = 1_709_938_200;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function test_H02_WeekendWithdrawalBlockedByHardcodedStaleness() public {
        _fundJunior(bob, 100_000e6);

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.warp(FRIDAY_AFTER_CLOSE);

        uint64 fridayPublishTime = uint64(FRIDAY_AFTER_CLOSE - 1800);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, fridayPublishTime);

        uint256 withdrawAmount = 50_000e6;
        uint256 redeemShares = juniorVault.estimateWithdrawShares(withdrawAmount);
        vm.prank(bob);
        uint256 requestId = juniorVault.requestRedeem(redeemShares, bob, bob);

        uint256 saturdayNoon = FRIDAY_AFTER_CLOSE + 14 hours;
        vm.warp(saturdayNoon);

        // The coordinated async exit remains live while frozen, using the frozen mark-age limit.
        _settleLpEpochForTest();
        uint256 claimableShares = juniorVault.claimableRedeemRequest(requestId, bob);
        vm.prank(bob);
        uint256 withdrawnAssets = juniorVault.claimRedeem(requestId, claimableShares, bob, bob);

        assertGt(withdrawnAssets, 0, "H-02: LP withdrawal must work during FAD window");
        assertEq(usdc.balanceOf(bob), withdrawnAssets, "funded FAD exit should remain independently claimable");
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-01 regression: a VPI rebate cannot substitute for required isolated price collateral
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_M01_VPIRebateIMRTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.05e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 2_000_000e6;
    }

    function test_M01_ZeroMarginPositionViaVPIRebate() public {
        _fundTrader(alice, 200_000e6);
        address aliceAccount = alice;
        // Alice creates LONG skew; pays VPI to open
        _open(aliceAccount, CfdTypes.Side.LONG, 300_000e18, 50_000e6, 1e8);

        // Bob attempts an opposing SHORT with zero margin. Its skew-reducing rebate must not
        // substitute for the required PnL pledge and protected reserves.
        _fundTrader(bob, 1e6);
        address bobAccount = bob;

        uint256 poolDepth = pool.totalAssets();
        vm.prank(address(router));
        vm.expectRevert();
        engine.processOrderTyped(
            CfdTypes.Order({
                account: bobAccount,
                sizeDelta: 300_000e18,
                marginDelta: 0,
                targetPrice: 1e8,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.SHORT,
                isClose: false
            }),
            1e8,
            poolDepth,
            uint64(block.timestamp)
        );
    }

    function test_M01_NonzeroMarginRebateOpenProjectsFreshVpiLiability() public {
        _fundTrader(alice, 200_000e6);
        _open(alice, CfdTypes.Side.LONG, 300_000e18, 50_000e6, 1e8);

        _fundTrader(bob, 4000e6);

        uint8 code = engineLens.previewOpenRevertCode(
            bob, CfdTypes.Side.SHORT, 300_000e18, 4000e6, 1e8, uint64(block.timestamp)
        );
        assertEq(
            code,
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "planner should subtract fresh negative VPI liability before admitting the open"
        );

        uint256 vaultDepth = pool.totalAssets();
        vm.prank(address(router));
        vm.expectRevert();
        engine.processOrderTyped(
            CfdTypes.Order({
                account: bob,
                sizeDelta: 300_000e18,
                marginDelta: 4000e6,
                targetPrice: 1e8,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.SHORT,
                isClose: false
            }),
            1e8,
            vaultDepth,
            uint64(block.timestamp)
        );
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-02 historical gas-griefing fixture: sufficient-gas batch execution succeeds
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_M02_GasGriefingTest is BasePerpTest {

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_M02_BatchTryCatchEnablesGasGriefing() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        // Alice commits a valid order
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);

        uint64 orderId = router.nextCommitId() - 1;
        bytes[] memory priceData = _mockPythUpdateData();

        // This call does not constrain gas or inject a failure. It checks only the successful
        // batch path. The current router has execution-gas checks and leaves retryable
        // failures pending; this fixture does not demonstrate an EIP-150 exploit.
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        router.executeOrderBatch{value: 0.01 ether}(orderId, priceData);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);

        // Confirm the sufficient-gas batch opened the position.
        assertGt(size, 0, "M-02: order executed with sufficient gas (vulnerability is gas-dependent)");
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-03 historical feed-rotation fixture: Engine-to-Router wiring is set once.
// This assertion does not exercise feed replacement; the current RouterAdmin can
// timelock-rotate the oracle while preserving the canonical Router binding.
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_M03_ImmutablePythArraysTest is BasePerpTest {

    function test_M03_NoPythFeedUpdateMechanism() public {
        vm.expectRevert(ICfdEngineTypes.CfdEngine__RouterAlreadySet.selector);
        engine.setOrderRouter(address(0x123));
    }

}
