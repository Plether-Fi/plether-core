// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../utils/LegacyOrderRouterHarness.sol";
import {MockSettlementToken} from "../utils/MockSettlementToken.sol";
import {OrderRouterDebugLens} from "../utils/OrderRouterDebugLens.sol";
import {RecordedOrderReceipts} from "../utils/RecordedOrderReceipts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "@plether/perps/CfdEngineAccountLens.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ClaimEngineViewTypes} from "@plether/perps/interfaces/ClaimEngineViewTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineRiskParamsView} from "@plether/perps/interfaces/ICfdEngineRiskParamsView.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

abstract contract BasePerpTest is RecordedOrderReceipts {

    struct CloseParitySnapshot {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot protocol;
        uint256 settlementAssets;
        uint256 traderClaimBalanceAssets;
    }

    struct CloseParityObserved {
        uint256 immediatePayoutAssets;
        uint256 traderClaimBalanceAssets;
        uint256 remainingSize;
        uint256 remainingMargin;
        bool degradedMode;
        uint256 effectiveAssetsAfterAssets;
        uint256 maxLiabilityAfterAssets;
    }

    struct LiquidationParitySnapshot {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot protocol;
        uint256 settlementAssets;
        uint256 traderClaimBalanceAssets;
        uint256 keeperSettlementAssets;
        uint256 protocolTreasurySettlementAssets;
    }

    struct LiquidationParityObserved {
        uint256 immediatePayoutAssets;
        uint256 traderClaimBalanceAssets;
        uint256 keeperSettlementAssets;
        uint256 protocolLiquidationFeeAssets;
        uint256 remainingSize;
        bool degradedMode;
        uint256 effectiveAssetsAfterAssets;
        uint256 maxLiabilityAfterAssets;
    }

    struct WithdrawParityState {
        bool checkWithdrawPasses;
        bytes4 checkWithdrawSelector;
        bool withdrawPasses;
        bytes4 withdrawSelector;
    }

    MockSettlementToken settlementToken;
    CfdEngine engine;
    TerminalNavBookV2 terminalNavBook;
    CfdEngineAdmin engineAdmin;
    CfdEngineAccountLens engineAccountLens;
    CfdEngineLens engineLens;
    CfdEngineProtocolLens engineProtocolLens;
    HousePool pool;
    HousePoolRedemptionMathSidecar housePoolRedemptionMathSidecar;
    MarginClearinghouse clearinghouse;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    LegacyOrderRouterHarness router;
    CfdOrderPolicyEvaluator policyEvaluator;
    OrderRouterExecutionSidecar orderExecutionSidecar;
    OrderRouterAdmin routerAdmin;
    PletherOracle pletherOracle;
    PerpsPublicLens publicLens;
    MockPyth baseMockPyth;

    /// @dev Monday 2024-03-04 10:00 UTC. Avoids FAD window.
    uint256 constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 constant CAP_PRICE = 2e8;
    uint256 constant FROZEN_CLOSE_SPREAD_BPS = 50;
    uint256 internal constant TEST_MAX_SENIOR_EXPOSURE_ASSETS = type(uint256).max - 1;
    uint256 internal constant TEST_MAX_SENIOR_SHARE_BPS = 9999;
    bytes32 internal constant BASE_PYTH_FEED_A = bytes32(uint256(1));
    bytes32 internal constant BASE_PYTH_FEED_B = bytes32(uint256(2));
    address internal constant PROTOCOL_TREASURY_ACCOUNT = address(0xFEE50001);

    receive() external payable {}

    function setUp() public virtual {
        settlementToken = new MockSettlementToken();
        clearinghouse = new MarginClearinghouse(address(settlementToken));

        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        housePoolRedemptionMathSidecar = new HousePoolRedemptionMathSidecar();
        pool = new HousePool(address(settlementToken), address(engine), address(housePoolRedemptionMathSidecar));
        baseMockPyth = new MockPyth();
        baseMockPyth.setSynchronizeLegacyUniquePrices(true);
        bytes32[] memory baseFeedIds = _basePythFeedIds();
        baseMockPyth.setAllPrices(baseFeedIds, int64(100_000_000), int32(-8), SETUP_TIMESTAMP);

        seniorVault = new TrancheVault(
            IERC20(address(settlementToken)), address(pool), true, "Plether Senior LP", "seniorAssets", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(settlementToken)), address(pool), false, "Plether Junior LP", "juniorAssets", 0, address(0)
        );

        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        pletherOracle = new PletherOracle(
            address(engine),
            address(pool),
            address(baseMockPyth),
            baseFeedIds,
            _basePythWeights(),
            _basePythBasePrices(),
            _basePythInversions()
        );
        router = _deployLegacyOrderRouter(address(engine), address(engineLens), address(pool), address(pletherOracle));
        _syncRouterAdmin();
        engine.setOrderRouter(address(router));
        publicLens = new PerpsPublicLens(address(engineAccountLens), address(engine), address(router), address(pool));

        _bypassAllTimelocks();

        uint256 juniorSeed = _initialJuniorSeedDeposit();
        if (juniorSeed > 0) {
            settlementToken.mint(address(this), juniorSeed);
            settlementToken.approve(address(pool), juniorSeed);
            pool.initializeSeedPosition(false, juniorSeed, _juniorSeedReceiver());
        }

        uint256 seniorSeed = _initialSeniorSeedDeposit();
        if (seniorSeed > 0) {
            settlementToken.mint(address(this), seniorSeed);
            settlementToken.approve(address(pool), seniorSeed);
            pool.initializeSeedPosition(true, seniorSeed, _seniorSeedReceiver());
        }

        if (_autoActivateTrading() && pool.isSeedLifecycleComplete()) {
            pool.activateTrading();
        }

        uint256 junior = _initialJuniorDeposit();
        if (junior > 0) {
            _fundJunior(address(this), junior);
        }

        uint256 senior = _initialSeniorDeposit();
        if (senior > 0) {
            _fundSenior(address(this), senior);
        }
    }

    function _bypassAllTimelocks() internal {
        clearinghouse.setEngine(address(engine));

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.maxSeniorExposureAssets = TEST_MAX_SENIOR_EXPOSURE_ASSETS;
        config.maxSeniorShareBps = TEST_MAX_SENIOR_SHARE_BPS;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        pool.finalizePoolConfig();

        vm.warp(SETUP_TIMESTAMP);
    }

    function _bootstrapSeededLifecycle() internal {
        uint256 juniorSeed = _initialJuniorSeedDeposit();
        if (juniorSeed > 0 && !pool.hasSeedLifecycleStarted()) {
            settlementToken.mint(address(this), juniorSeed);
            settlementToken.approve(address(pool), juniorSeed);
            pool.initializeSeedPosition(false, juniorSeed, _juniorSeedReceiver());
        }

        uint256 seniorSeed = _initialSeniorSeedDeposit();
        if (seniorSeed > 0 && !pool.isSeedLifecycleComplete()) {
            settlementToken.mint(address(this), seniorSeed);
            settlementToken.approve(address(pool), seniorSeed);
            pool.initializeSeedPosition(true, seniorSeed, _seniorSeedReceiver());
        }

        if (_autoActivateTrading() && pool.isSeedLifecycleComplete() && !pool.isTradingActive()) {
            pool.activateTrading();
        }
    }

    // --- Virtual hooks ---

    function _riskParams() internal pure virtual returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure virtual returns (uint256) {
        return 1_000_000 * 1e6;
    }

    function _initialSeniorDeposit() internal pure virtual returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure virtual returns (uint256) {
        return 1000e6;
    }

    function _initialSeniorSeedDeposit() internal pure virtual returns (uint256) {
        return 1000e6;
    }

    function _juniorSeedReceiver() internal view virtual returns (address) {
        return address(this);
    }

    function _autoActivateTrading() internal pure virtual returns (bool) {
        return true;
    }

    function _seniorSeedReceiver() internal view virtual returns (address) {
        return address(this);
    }

    function _basePythFeedIds() internal pure returns (bytes32[] memory feedIds) {
        feedIds = new bytes32[](2);
        feedIds[0] = BASE_PYTH_FEED_A;
        feedIds[1] = BASE_PYTH_FEED_B;
    }

    function _basePythWeights() internal pure returns (uint256[] memory weights) {
        weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
    }

    function _basePythBasePrices() internal pure returns (uint256[] memory basePrices) {
        basePrices = new uint256[](2);
        basePrices[0] = 1e8;
        basePrices[1] = 1e8;
    }

    function _basePythInversions() internal pure returns (bool[] memory inversions) {
        inversions = new bool[](2);
    }

    function _mockPythUpdateData() internal returns (bytes[] memory updateData) {
        return _mockPythUpdateData(1e8);
    }

    function _mockPythUpdateData(
        uint256 price
    ) internal returns (bytes[] memory updateData) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 publishTime = _mockHistoricalPublishTime();
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(),
            SafeCast.toInt64(SafeCast.toInt256(price)),
            0,
            int32(-8),
            publishTime,
            publishTime == 0 ? 0 : publishTime - 1
        );
        updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
    }

    function _mockHistoricalPublishTime() internal view returns (uint256 publishTime) {
        publishTime = block.timestamp;
        uint64 nextOrderId = router.nextExecuteId();
        if (nextOrderId == 0) {
            return publishTime;
        }

        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(nextOrderId);
        uint256 candidate = uint256(pending.commitTime) + 1;
        if (pending.orderId != 0 && candidate <= block.timestamp) {
            publishTime = candidate;
        }
    }

    // --- Asynchronous LP funding helpers ---

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        _fundTrancheAsync(juniorVault, lp, amount);
    }

    function _fundJuniorDelayed(
        address lp,
        uint256 amount
    ) internal returns (uint256 shares) {
        shares = _fundTrancheAsync(juniorVault, lp, amount);
    }

    function _fundSenior(
        address lp,
        uint256 amount
    ) internal {
        _fundTrancheAsync(seniorVault, lp, amount);
    }

    function _fundTrancheAsync(
        TrancheVault vault,
        address lp,
        uint256 amount
    ) internal returns (uint256 shares) {
        settlementToken.mint(lp, amount);
        vm.startPrank(lp);
        settlementToken.approve(address(vault), amount);
        uint256 requestId = vault.requestDeposit(amount, lp, lp);
        vm.stopPrank();

        uint256 activationTime = vault.depositEpochStart(requestId);
        if (block.timestamp < activationTime) {
            vm.warp(activationTime);
        }
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, SafeCast.toUint64(block.timestamp));
        _settleLpEpochForTest();

        uint256 claimableAssets = vault.claimableDepositRequest(requestId, lp);
        assertEq(claimableAssets, amount, "async tranche funding must finalize the requested asset basis");
        vm.prank(lp);
        shares = vault.claimDeposit(requestId, claimableAssets, lp, lp);
        assertGt(shares, 0, "async tranche funding must mint claimable shares");
    }

    /// @dev Unit and economics tests install marks directly through the configured Router address. Route settlement
    ///      through the production authorization split without forcing every test to construct Pyth update blobs.
    ///      No-position and frozen-mode calls intentionally exercise the cached-mark liveness path.
    function _settleLpEpochForTest() internal returns (IHousePool.LpEpochSettlementResult memory result) {
        ICfdEngineTypes.TerminalNavSnapshot memory terminalSnapshot = engine.terminalNavSnapshot();

        if (!terminalSnapshot.hasOpenPositions || engine.isOracleFrozen()) {
            return pool.settleLpEpoch(0, 0);
        }

        vm.prank(address(router));
        result = pool.settleLpEpoch(terminalSnapshot.markPrice, terminalSnapshot.markTime);
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        address account = trader;
        settlementToken.mint(trader, amount);
        vm.startPrank(trader);
        settlementToken.approve(address(clearinghouse), amount);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();
    }

    function _currentPoolConfig() internal view returns (IHousePool.PoolConfig memory config) {
        config = IHousePool.PoolConfig({
            seniorRateBps: pool.seniorRateBps(),
            markStalenessLimit: pool.markStalenessLimit(),
            seniorFrozenLpFeeBps: pool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: pool.juniorFrozenLpFeeBps(),
            maxSeniorExposureAssets: pool.maxSeniorExposureAssets(),
            maxSeniorShareBps: pool.maxSeniorShareBps()
        });
    }

    function _setSeniorCapacity(
        uint256 maxSeniorExposureAssets,
        uint256 maxSeniorShareBps
    ) internal {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.maxSeniorExposureAssets = maxSeniorExposureAssets;
        config.maxSeniorShareBps = maxSeniorShareBps;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        pool.finalizePoolConfig();
    }

    // --- Trading helpers ---

    function _ensureLaterOracleTime() internal {
        if (vm.getBlockTimestamp() <= engine.lastMarkTime()) {
            vm.warp(uint256(engine.lastMarkTime()) + 1);
        }
    }

    function _open(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price
    ) internal {
        _open(account, side, size, margin, price, pool.totalAssets());
    }

    function _open(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
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

    function _close(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) internal {
        _close(account, side, size, price, pool.totalAssets());
    }

    function _close(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth
    ) internal {
        _closeAt(account, side, size, price, depth, uint64(block.timestamp));
    }

    function _closeAt(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth,
        uint64 publishTime
    ) internal {
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: publishTime,
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: true
            }),
            price,
            depth,
            publishTime
        );
    }

    function _captureCloseParitySnapshot(
        address account
    ) internal view returns (CloseParitySnapshot memory snapshot) {
        snapshot.protocol = engineProtocolLens.getProtocolAccountingSnapshot();
        snapshot.settlementAssets = clearinghouse.balanceAssets(account);
        snapshot.traderClaimBalanceAssets = engine.traderClaimBalanceAssets(account);
    }

    function _observeCloseParity(
        address account,
        CloseParitySnapshot memory beforeSnapshot
    ) internal view returns (CloseParityObserved memory observed) {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        (observed.remainingSize, observed.remainingMargin,,,,,) = engine.positions(account);
        uint256 settlementAfter = clearinghouse.balanceAssets(account);
        observed.immediatePayoutAssets =
            settlementAfter > beforeSnapshot.settlementAssets ? settlementAfter - beforeSnapshot.settlementAssets : 0;
        observed.traderClaimBalanceAssets = engine.traderClaimBalanceAssets(account);
        observed.degradedMode = engine.degradedMode();
        observed.effectiveAssetsAfterAssets = afterSnapshot.effectiveSolvencyAssets;
        observed.maxLiabilityAfterAssets = afterSnapshot.maxLiabilityAssets;
        _assertTerminalCurveMatchesEngine(account);
        _assertTerminalNavSnapshotMatchesBook();
    }

    function _assertClosePreviewMatchesObserved(
        ICfdEngineTypes.ClosePreview memory preview,
        CloseParityObserved memory observed,
        bool degradedModeBefore
    ) internal pure {
        assertApproxEqAbs(
            observed.immediatePayoutAssets,
            preview.immediatePayoutAssets,
            40_000_000,
            "Immediate payout should stay close to close preview"
        );
        assertApproxEqAbs(
            observed.traderClaimBalanceAssets,
            preview.traderClaimBalanceAssets,
            40_000_000,
            "Trader claim should stay close to close preview"
        );
        assertEq(observed.remainingSize, preview.remainingSize, "Remaining size should match close preview");
        assertEq(observed.remainingMargin, preview.remainingMargin, "Remaining margin should match close preview");
        assertEq(
            observed.degradedMode,
            degradedModeBefore || preview.triggersDegradedMode,
            "Latched degraded mode should match close preview transition semantics"
        );
        assertEq(
            observed.effectiveAssetsAfterAssets,
            preview.effectiveAssetsAfterAssets,
            "Effective assets after close should match preview"
        );
        assertEq(
            observed.maxLiabilityAfterAssets,
            preview.maxLiabilityAfterAssets,
            "Max liability after close should match preview"
        );
    }

    function _assertClosePreviewEquals(
        ICfdEngineTypes.ClosePreview memory actual,
        ICfdEngineTypes.ClosePreview memory expected
    ) internal pure {
        assertEq(actual.valid, expected.valid, "Close preview validity should match");
        assertEq(uint8(actual.invalidReason), uint8(expected.invalidReason), "Close invalid reason should match");
        assertEq(actual.executionPrice, expected.executionPrice, "Close execution price should match");
        assertEq(actual.sizeDelta, expected.sizeDelta, "Close size delta should match");
        assertEq(actual.realizedPnlAssets, expected.realizedPnlAssets, "Close realized pnl should match");
        assertEq(actual.vpiDeltaAssets, expected.vpiDeltaAssets, "Close VPI delta should match");
        assertEq(actual.vpiAssets, expected.vpiAssets, "Close VPI should match");
        assertEq(actual.executionFeeAssets, expected.executionFeeAssets, "Close execution fee should match");
        assertEq(actual.frozenSpreadAssets, expected.frozenSpreadAssets, "Close assessed frozen spread should match");
        assertEq(
            actual.frozenSpreadPaidAssets, expected.frozenSpreadPaidAssets, "Close paid frozen spread should match"
        );
        assertEq(
            actual.frozenSpreadWaivedAssets,
            expected.frozenSpreadWaivedAssets,
            "Close waived frozen spread should match"
        );
        assertEq(actual.freshTraderPayoutAssets, expected.freshTraderPayoutAssets, "Close fresh payout should match");
        assertEq(
            actual.existingTraderClaimConsumedAssets,
            expected.existingTraderClaimConsumedAssets,
            "Close trader claim consumption should match"
        );
        assertEq(
            actual.existingTraderClaimRemainingAssets,
            expected.existingTraderClaimRemainingAssets,
            "Close trader claim remainder should match"
        );
        assertEq(actual.immediatePayoutAssets, expected.immediatePayoutAssets, "Close immediate payout should match");
        assertEq(actual.payoutToPnlPledgeAssets, expected.payoutToPnlPledgeAssets, "Close pledged payout should match");
        assertEq(
            actual.payoutToFreeSettlementAssets, expected.payoutToFreeSettlementAssets, "Close free payout should match"
        );
        assertEq(actual.deferredPayoutAssets, expected.deferredPayoutAssets, "Close deferred payout should match");
        assertEq(actual.traderClaimBalanceAssets, expected.traderClaimBalanceAssets, "Close trader claim should match");
        assertEq(actual.seizedCollateralAssets, expected.seizedCollateralAssets, "Close seized collateral should match");
        assertEq(actual.remainingSize, expected.remainingSize, "Close remaining size should match");
        assertEq(actual.remainingMargin, expected.remainingMargin, "Close remaining margin should match");
        assertEq(actual.triggersDegradedMode, expected.triggersDegradedMode, "Close degraded trigger should match");
        assertEq(actual.postOpDegradedMode, expected.postOpDegradedMode, "Close post-op degraded mode should match");
        assertEq(
            actual.effectiveAssetsAfterAssets,
            expected.effectiveAssetsAfterAssets,
            "Close effective assets should match"
        );
        assertEq(actual.maxLiabilityAfterAssets, expected.maxLiabilityAfterAssets, "Close max liability should match");
    }

    function _captureLiquidationParitySnapshot(
        address account,
        address keeper
    ) internal view returns (LiquidationParitySnapshot memory snapshot) {
        snapshot.protocol = engineProtocolLens.getProtocolAccountingSnapshot();
        snapshot.settlementAssets = clearinghouse.balanceAssets(account);
        snapshot.traderClaimBalanceAssets = engine.traderClaimBalanceAssets(account);
        snapshot.keeperSettlementAssets = clearinghouse.balanceAssets(keeper);
        snapshot.protocolTreasurySettlementAssets = clearinghouse.balanceAssets(engine.protocolTreasury());
    }

    function _observeLiquidationParity(
        address account,
        address keeper,
        LiquidationParitySnapshot memory beforeSnapshot
    ) internal view returns (LiquidationParityObserved memory observed) {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        (observed.remainingSize,,,,,,) = engine.positions(account);
        uint256 settlementAfter = clearinghouse.balanceAssets(account);
        observed.immediatePayoutAssets =
            settlementAfter > beforeSnapshot.settlementAssets ? settlementAfter - beforeSnapshot.settlementAssets : 0;
        observed.traderClaimBalanceAssets = engine.traderClaimBalanceAssets(account);
        uint256 keeperSettlementAfter = clearinghouse.balanceAssets(keeper);
        observed.keeperSettlementAssets = keeperSettlementAfter > beforeSnapshot.keeperSettlementAssets
            ? keeperSettlementAfter - beforeSnapshot.keeperSettlementAssets
            : 0;
        observed.protocolLiquidationFeeAssets =
            clearinghouse.balanceAssets(engine.protocolTreasury()) - beforeSnapshot.protocolTreasurySettlementAssets;
        observed.degradedMode = engine.degradedMode();
        observed.effectiveAssetsAfterAssets = afterSnapshot.effectiveSolvencyAssets;
        observed.maxLiabilityAfterAssets = afterSnapshot.maxLiabilityAssets;
        _assertTerminalCurveMatchesEngine(account);
        _assertTerminalNavSnapshotMatchesBook();
    }

    function _assertLiquidationPreviewMatchesObserved(
        ICfdEngineTypes.LiquidationPreview memory preview,
        LiquidationParityObserved memory observed,
        bool degradedModeBefore
    ) internal pure {
        assertEq(
            observed.immediatePayoutAssets,
            preview.immediatePayoutAssets,
            "Immediate trader payout should match liquidation preview"
        );
        assertEq(
            observed.traderClaimBalanceAssets,
            preview.traderClaimBalanceAssets,
            "Trader claim balance should match liquidation preview"
        );
        assertEq(
            observed.keeperSettlementAssets,
            preview.keeperBountyAssets,
            "Keeper bounty settlement should match liquidation preview"
        );
        assertEq(
            observed.protocolLiquidationFeeAssets,
            preview.protocolLiquidationFeeAssets,
            "Protocol treasury credit should match liquidation preview"
        );
        assertEq(observed.remainingSize, 0, "Liquidation parity helper expects the position to be fully removed");
        assertEq(
            observed.degradedMode,
            degradedModeBefore || preview.triggersDegradedMode,
            "Latched degraded mode should match liquidation preview transition semantics"
        );
        assertEq(
            observed.effectiveAssetsAfterAssets,
            preview.effectiveAssetsAfterAssets,
            "Effective assets after liquidation should match preview"
        );
        assertEq(
            observed.maxLiabilityAfterAssets,
            preview.maxLiabilityAfterAssets,
            "Max liability after liquidation should match preview"
        );
    }

    function _assertLiquidationPreviewEquals(
        ICfdEngineTypes.LiquidationPreview memory actual,
        ICfdEngineTypes.LiquidationPreview memory expected
    ) internal pure {
        assertEq(
            actual.liquidatable, expected.liquidatable, "Liquidatable flag should match canonical simulateLiquidation"
        );
        assertEq(actual.oraclePrice, expected.oraclePrice, "Liquidation oracle price should match");
        assertEq(actual.equityAssets, expected.equityAssets, "Liquidation equity should match");
        assertEq(actual.pnlAssets, expected.pnlAssets, "Liquidation pnl should match");
        assertEq(
            actual.reachableCollateralAssets, expected.reachableCollateralAssets, "Reachable collateral should match"
        );
        assertEq(actual.liquidationChargeAssets, expected.liquidationChargeAssets, "Liquidation charge should match");
        assertEq(actual.keeperBountyAssets, expected.keeperBountyAssets, "Keeper bounty should match");
        assertEq(
            actual.protocolLiquidationFeeAssets,
            expected.protocolLiquidationFeeAssets,
            "Protocol liquidation fee should match"
        );
        assertEq(actual.lpLiquidationFeeAssets, expected.lpLiquidationFeeAssets, "LP liquidation fee should match");
        assertEq(actual.seizedCollateralAssets, expected.seizedCollateralAssets, "Seized collateral should match");
        assertEq(actual.settlementRetainedAssets, expected.settlementRetainedAssets, "Settlement retained should match");
        assertEq(actual.freshTraderPayoutAssets, expected.freshTraderPayoutAssets, "Fresh trader payout should match");
        assertEq(
            actual.existingTraderClaimConsumedAssets,
            expected.existingTraderClaimConsumedAssets,
            "Trader claim consumption should match"
        );
        assertEq(
            actual.existingTraderClaimRemainingAssets,
            expected.existingTraderClaimRemainingAssets,
            "Trader claim remainder should match"
        );
        assertEq(actual.immediatePayoutAssets, expected.immediatePayoutAssets, "Immediate payout should match");
        assertEq(actual.traderClaimBalanceAssets, expected.traderClaimBalanceAssets, "Trader claim should match");
        assertEq(actual.triggersDegradedMode, expected.triggersDegradedMode, "Degraded trigger should match");
        assertEq(actual.postOpDegradedMode, expected.postOpDegradedMode, "Post-op degraded mode should match");
        assertEq(
            actual.effectiveAssetsAfterAssets, expected.effectiveAssetsAfterAssets, "Effective assets should match"
        );
        assertEq(actual.maxLiabilityAfterAssets, expected.maxLiabilityAfterAssets, "Max liability should match");
    }

    function _observeWithdrawParity(
        address account,
        address trader,
        uint256 amountAssets
    ) internal returns (WithdrawParityState memory state) {
        vm.prank(address(clearinghouse));
        try engine.checkWithdraw(account) {
            state.checkWithdrawPasses = true;
        } catch (bytes memory err) {
            state.checkWithdrawSelector = _revertSelector(err);
        }

        vm.prank(trader);
        try clearinghouse.withdraw(account, amountAssets) {
            state.withdrawPasses = true;
        } catch (bytes memory err) {
            state.withdrawSelector = _revertSelector(err);
        }
    }

    function _assertWithdrawParity(
        WithdrawParityState memory state,
        bytes4 expectedGuardSelector
    ) internal pure {
        assertEq(state.withdrawPasses, state.checkWithdrawPasses, "Withdraw result should mirror checkWithdraw gate");
        if (!state.checkWithdrawPasses) {
            assertEq(
                state.checkWithdrawSelector, expectedGuardSelector, "checkWithdraw should fail with expected selector"
            );
            assertEq(state.withdrawSelector, expectedGuardSelector, "live withdraw should fail with same selector");
        }
    }

    function _revertSelector(
        bytes memory err
    ) internal pure returns (bytes4 selector) {
        if (err.length < 4) {
            return bytes4(0);
        }
        assembly ("memory-safe") {
            selector := mload(add(err, 32))
        }
    }

    // --- Governance helpers ---

    function _engineRiskConfig() internal view returns (ICfdEngineAdminHost.EngineRiskConfig memory config) {
        config.riskParams = ICfdEngineRiskParamsView(address(engine)).riskParams();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        config.executionFeeBps = engine.executionFeeBps();
        config.settlementBufferBps = engine.settlementBufferBps();
    }

    function _engineCalendarConfig() internal view returns (ICfdEngineAdminHost.EngineCalendarConfig memory config) {
        config.fadRunwaySeconds = engine.fadRunwaySeconds();
    }

    function _engineFreshnessConfig() internal view returns (ICfdEngineAdminHost.EngineFreshnessConfig memory config) {
        config.fadMaxStaleness = engine.fadMaxStaleness();
        config.engineMarkStalenessLimit = engine.engineMarkStalenessLimit();
    }

    function _setRiskParams(
        CfdTypes.RiskParams memory params
    ) internal {
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        config.settlementBufferBps = engine.settlementBufferBps();
        engineAdmin.proposeRiskConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        engineAdmin.finalizeRiskConfig();
    }

    function _setCalendarConfig(
        ICfdEngineAdminHost.EngineCalendarConfig memory config
    ) internal {
        engineAdmin.proposeCalendarConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        engineAdmin.finalizeCalendarConfig();
    }

    function _setFreshnessConfig(
        ICfdEngineAdminHost.EngineFreshnessConfig memory config
    ) internal {
        engineAdmin.proposeFreshnessConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        engineAdmin.finalizeFreshnessConfig();
    }

    function _routerConfig() internal view returns (IOrderRouterAdminHost.RouterConfig memory config) {
        config.maxExecutionWindowSeconds = router.maxExecutionWindowSeconds();
        config.orderExecutionStalenessLimit = router.pletherOracle().orderExecutionStalenessLimit();
        config.liquidationStalenessLimit = router.pletherOracle().liquidationStalenessLimit();
        config.basketMaxConfidenceRatioBps = router.pletherOracle().basketMaxConfidenceRatioBps();
        config.orderSettlementWindow = router.pletherOracle().orderSettlementWindow();
        config.maxComponentPublishTimeDivergence = router.pletherOracle().maxComponentPublishTimeDivergence();
        config.adverseConfidenceMultiplierBps = router.pletherOracle().adverseConfidenceMultiplierBps();
        config.minOpenNotionalAssets = router.minOpenNotionalAssets();
        config.openOrderExecutionBountyBps = router.openOrderExecutionBountyBps();
        config.minOpenOrderExecutionBountyAssets = router.minOpenOrderExecutionBountyAssets();
        config.maxOpenOrderExecutionBountyAssets = router.maxOpenOrderExecutionBountyAssets();
        config.positionProtectionTriggerBountyAssets = router.positionProtectionTriggerBountyAssets();
        config.maxPendingOrders = router.maxPendingOrders();
        config.minEngineGas = router.minEngineGas();
        config.maxPruneOrdersPerCall = router.maxPruneOrdersPerCall();
    }

    function _setRouterConfig(
        IOrderRouterAdminHost.RouterConfig memory config
    ) internal {
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();
    }

    function _syncEngineAdmin() internal {
        engineAdmin = CfdEngineAdmin(engine.admin());
    }

    function _deployEngine(
        CfdTypes.RiskParams memory riskParams_
    ) internal returns (CfdEngine deployedEngine) {
        deployedEngine = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, riskParams_, _frozenCloseSpreadBps()
        );
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(deployedEngine));
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(deployedEngine), address(this));
        deployedEngine.setDependencies(address(planner), address(settlement), address(adminModule));
        deployedEngine.setProtocolTreasury(PROTOCOL_TREASURY_ACCOUNT);
    }

    /// @dev Deploys the test-only legacy adapter around the production bounded-order router.
    function _deployLegacyOrderRouter(
        address engine_,
        address engineLens_,
        address pool_,
        address oracle_
    ) internal returns (LegacyOrderRouterHarness deployedRouter) {
        policyEvaluator = new CfdOrderPolicyEvaluator();
        orderExecutionSidecar = new OrderRouterExecutionSidecar();
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, engine_, address(clearinghouse), pool_);
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        deployedRouter = new LegacyOrderRouterHarness(
            engine_,
            engineLens_,
            pool_,
            oracle_,
            address(keeperSidecar),
            address(policyEvaluator),
            address(orderExecutionSidecar),
            address(lifecycleBook)
        );
        assertEq(address(deployedRouter), predictedRouter);
    }

    function _frozenCloseSpreadBps() internal pure virtual returns (uint256) {
        return FROZEN_CLOSE_SPREAD_BPS;
    }

    function _syncRouterAdmin() internal {
        routerAdmin = OrderRouterAdmin(router.admin());
    }

    // --- Time helpers ---

    function _warpForward(
        uint256 delta
    ) internal {
        vm.warp(block.timestamp + delta);
    }

    function _sideState(
        CfdTypes.Side side
    ) internal view returns (ICfdEngineTypes.SideState memory state) {
        (state.maxProfitAssets, state.openInterest, state.entryNotional, state.totalMargin) = engine.sides(uint8(side));
    }

    function _maxLiability() internal view returns (uint256) {
        ICfdEngineTypes.SideState memory long = _sideState(CfdTypes.Side.LONG);
        ICfdEngineTypes.SideState memory short = _sideState(CfdTypes.Side.SHORT);
        return long.maxProfitAssets > short.maxProfitAssets ? long.maxProfitAssets : short.maxProfitAssets;
    }

    function _withdrawalReservedAssets() internal view returns (uint256) {
        return engineProtocolLens.getProtocolAccountingSnapshot().withdrawalReservedAssets;
    }

    function _unrealizedTraderPnl() internal view returns (int256) {
        uint256 price = engine.lastMarkPrice();
        if (price == 0) {
            return 0;
        }
        ICfdEngineTypes.SideState memory long = _sideState(CfdTypes.Side.LONG);
        ICfdEngineTypes.SideState memory short = _sideState(CfdTypes.Side.SHORT);
        int256 longPnl =
            (SafeCast.toInt256(long.entryNotional) - SafeCast.toInt256(long.openInterest * price)) / int256(1e20);
        int256 shortPnl =
            (SafeCast.toInt256(short.openInterest * price) - SafeCast.toInt256(short.entryNotional)) / int256(1e20);
        return longPnl + shortPnl;
    }

    function _maintenanceMarginAssets(
        uint256 size,
        uint256 price
    ) internal view returns (uint256) {
        (,, uint256 maintMarginBps,, uint256 fadMarginBps,,,,,) = engine.riskParams();
        uint256 requiredBps = engine.isFadWindow() ? fadMarginBps : maintMarginBps;
        uint256 notionalAssets = (size * price) / 1e20;
        return (notionalAssets * requiredBps) / 10_000;
    }

    function _quoteOpenOrderExecutionBountyAssets(
        uint256 sizeDelta
    ) internal view returns (uint256) {
        uint256 price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }
        uint256 notionalAssets = (sizeDelta * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        uint256 executionBountyAssets = (notionalAssets * router.openOrderExecutionBountyBps()) / 10_000;
        if (executionBountyAssets < router.minOpenOrderExecutionBountyAssets()) {
            executionBountyAssets = router.minOpenOrderExecutionBountyAssets();
        }
        uint256 maxExecutionBountyAssets = router.maxOpenOrderExecutionBountyAssets();
        return executionBountyAssets > maxExecutionBountyAssets ? maxExecutionBountyAssets : executionBountyAssets;
    }

    function _engineExecutionFeeAssets(
        uint256 sizeDelta,
        uint256 price
    ) internal view returns (uint256) {
        uint256 notionalAssets = (sizeDelta * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        return (notionalAssets * engine.executionFeeBps()) / 10_000;
    }

    function _sideOpenInterest(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).openInterest;
    }

    function _sideEntryNotional(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).entryNotional;
    }

    function _sideTotalMargin(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).totalMargin;
    }

    function _sideMaxProfit(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).maxProfitAssets;
    }

    function _orderRecord(
        uint64 orderId
    ) internal view returns (OrderRouterDebugLens.OrderRecord memory record) {
        return OrderRouterDebugLens.loadOrderRecord(vm, router, orderId);
    }

    function _pendingOrders(
        address account
    ) internal view returns (IOrderRouterAccounting.PendingOrderView[] memory pending) {
        uint64 orderId = router.accountHeadOrderId(account);
        uint256 pendingCount = router.pendingOrderCounts(account);
        pending = new IOrderRouterAccounting.PendingOrderView[](pendingCount);
        for (uint256 i; i < pendingCount; ++i) {
            (pending[i], orderId) = router.getPendingOrderView(orderId);
        }
    }

    function _remainingCommittedMargin(
        uint64 orderId
    ) internal view returns (uint256) {
        return clearinghouse.getOrderReservation(orderId).remainingAmountAssets;
    }

    function _executionBountyReserve(
        uint64 orderId
    ) internal view returns (uint256) {
        return _orderRecord(orderId).executionBountyAssets;
    }

    function _isInMarginQueue(
        uint64 orderId
    ) internal view returns (bool) {
        return _orderRecord(orderId).inMarginQueue;
    }

    function _freeSettlementAssets(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.getAccountAssetBuckets(account).freeSettlementAssets;
    }

    function _expectedIndexedCarryAssets(
        address account
    ) internal view returns (uint256) {
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return 0;
        }
        (uint256 borrowBaseAssets, uint256 startIndex,) = engine.positionCarryState(account);
        if (borrowBaseAssets == 0) {
            return 0;
        }
        uint256 endIndex = _currentSideCarryIndex(side);
        if (endIndex <= startIndex) {
            return 0;
        }
        return PositionRiskAccountingLib.computeIndexedCarryAssets(borrowBaseAssets, endIndex - startIndex);
    }

    function _positionBorrowBaseAssets(
        address account
    ) internal view returns (uint256 borrowBaseAssets) {
        (borrowBaseAssets,,) = engine.positionCarryState(account);
    }

    function _lastCarryTimestamp(
        address account
    ) internal view returns (uint64 lastCarryTimestamp) {
        (,, lastCarryTimestamp) = engine.positionCarryState(account);
    }

    function _currentSideCarryIndex(
        CfdTypes.Side side
    ) internal view returns (uint256 index) {
        uint256 sideIndex = uint256(side);
        (,,,,, uint256 baseCarryBps,,,,) = engine.riskParams();
        uint256 grossAssets = pool.totalAssets();
        uint256 claims = engine.totalTraderClaimBalanceAssets();
        index = PositionRiskAccountingLib.computeCurrentCarryIndex(
            engine.sideCarryIndex(sideIndex),
            engine.sideCarryTimestamp(sideIndex),
            vm.getBlockTimestamp(),
            engine.sideBorrowBaseAssets(sideIndex),
            grossAssets > claims ? grossAssets - claims : 0,
            baseCarryBps
        );
    }

    function _accountOf(
        address account
    ) internal pure returns (address) {
        return account;
    }

    function _settlementBalance(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.balanceAssets(_accountOf(account));
    }

    function _fundProtocolTreasury(
        uint256 amountAssets
    ) internal {
        address treasury = engine.protocolTreasury();
        settlementToken.mint(address(clearinghouse), amountAssets);
        vm.prank(address(engine));
        clearinghouse.settleAssets(treasury, SafeCast.toInt256(amountAssets));
    }

    function _withdrawProtocolTreasury(
        uint256 amountAssets
    ) internal {
        address treasury = engine.protocolTreasury();
        vm.prank(treasury);
        clearinghouse.withdraw(treasury, amountAssets);
    }

    function _terminalReachableAssets(
        address account
    ) internal view returns (uint256) {
        uint256 settlementBalance = clearinghouse.getAccountAssetBuckets(account).settlementBalanceAssets;
        uint256 executionReservation = router.getAccountReservations(account).executionBountyAssets;
        return settlementBalance > executionReservation ? settlementBalance - executionReservation : 0;
    }

    function _publicPosition(
        address account
    ) internal view returns (PerpsViewTypes.PositionView memory viewData) {
        return publicLens.getPosition(account);
    }

    function _publicProtocolStatus() internal view returns (PerpsViewTypes.ProtocolStatusView memory viewData) {
        return publicLens.getProtocolStatus();
    }

    function _traderClaimStatus(
        address account,
        address keeper
    ) internal view returns (ClaimEngineViewTypes.TraderClaimStatus memory status) {
        uint256 traderClaimBalanceAssets = engine.traderClaimBalanceAssets(account);
        bool anyLiquidity = pool.totalAssets() > 0;

        status.traderClaimBalanceAssets = traderClaimBalanceAssets;
        status.traderClaimServiceableNow = traderClaimBalanceAssets > 0 && anyLiquidity;
        keeper;
    }

    function _poolMtmAdjustment() internal view returns (uint256) {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        int256 delta = snapshot.terminalLpPriceDeltaAssets;
        return delta < 0 ? uint256(-(delta + 1)) + 1 : 0;
    }

    function _terminalLpPriceDelta() internal view returns (int256) {
        return engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit()).terminalLpPriceDeltaAssets;
    }

    /// @dev Verifies that the account-local V2 terminal curve is the exact committed image of live Engine state.
    function _assertTerminalCurveMatchesEngine(
        address account
    ) internal view {
        ITerminalNavBookV2.CurveRecord memory curve = terminalNavBook.curveOf(account);
        bytes32 curveHash = terminalNavBook.curveHashOf(account);
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);

        if (size == 0) {
            assertEq(curveHash, bytes32(0), "Terminal account must not retain an orphan curve");
            assertEq(uint256(curve.lots), 0, "Closed terminal curve must clear lots");
            assertEq(uint256(curve.entryCostAssetAtoms), 0, "Closed terminal curve must clear entry cost");
            assertEq(uint256(curve.effectiveCapAssetAtoms), 0, "Closed terminal curve must clear collectible cap");
            return;
        }

        assertTrue(curveHash != bytes32(0), "Live position must retain a terminal curve commitment");
        assertEq(size % CfdTypes.SIZE_QUANTUM, 0, "Live terminal position must contain whole lots");
        uint256 lots = size / CfdTypes.SIZE_QUANTUM;
        uint256 entryCostAssetAtoms = engine.positionEntryCostAssetAtoms(account);
        uint256 maximumCollectibleAssets =
            side == CfdTypes.Side.LONG ? lots * CAP_PRICE - entryCostAssetAtoms : entryCostAssetAtoms;
        uint256 candidateCapAssets = clearinghouse.pnlPledgeAssets(account) + engine.traderClaimBalanceAssets(account);
        uint256 expectedCapAssets =
            candidateCapAssets < maximumCollectibleAssets ? candidateCapAssets : maximumCollectibleAssets;

        assertEq(uint256(curve.lots), lots, "Terminal curve lots must match Engine position");
        assertEq(
            uint256(curve.entryCostAssetAtoms),
            entryCostAssetAtoms,
            "Terminal curve basis must match exact Engine basis"
        );
        assertEq(
            uint256(curve.effectiveCapAssetAtoms),
            expectedCapAssets,
            "Terminal curve cap must match pledge, nettable claim, and collectible close escrow"
        );
        assertEq(uint8(curve.side), uint8(side), "Terminal curve side must match Engine position");
    }

    /// @dev Verifies the authenticated Engine snapshot against the exact aggregate book and live protocol state.
    function _assertTerminalNavSnapshotMatchesBook() internal view {
        ICfdEngineTypes.TerminalNavSnapshot memory snapshot = engine.terminalNavSnapshot();
        ITerminalNavBookV2.BookState memory bookState = terminalNavBook.bookState();

        assertEq(snapshot.markPrice, engine.lastMarkPrice(), "Terminal snapshot mark must match Engine mark");
        assertEq(snapshot.markTime, engine.lastMarkTime(), "Terminal snapshot time must match Engine mark time");
        assertEq(snapshot.bookVersion, bookState.bookVersion, "Terminal snapshot version must match book version");
        assertEq(
            snapshot.terminalLpPriceDeltaAssets,
            terminalNavBook.terminalLpPriceDeltaAssetAtoms(snapshot.markPrice),
            "Terminal snapshot delta must equal exact book evaluation"
        );
        assertEq(
            snapshot.totalTraderClaimsAssets,
            engine.totalTraderClaimBalanceAssets(),
            "Terminal snapshot claims must match Engine claims"
        );
        assertEq(
            snapshot.maxDirectionalLiabilityAssets,
            _maxLiability(),
            "Terminal snapshot liability must match live side state"
        );
        assertEq(
            snapshot.hasOpenPositions,
            bookState.activeCurveCount > 0,
            "Terminal open-position flag must match active curve count"
        );
        assertEq(snapshot.degradedMode, engine.degradedMode(), "Terminal snapshot degraded flag must match Engine");
    }

}
