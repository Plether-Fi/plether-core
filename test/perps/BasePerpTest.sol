// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {DecimalConstants} from "../../src/libraries/DecimalConstants.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "../../src/perps/CfdEngineAccountLens.sol";
import {CfdEngineAdmin} from "../../src/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "../../src/perps/CfdEnginePlanner.sol";
import {CfdEngineProtocolLens} from "../../src/perps/CfdEngineProtocolLens.sol";
import {CfdEngineSettlementSidecar} from "../../src/perps/CfdEngineSettlementSidecar.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "../../src/perps/OrderRouterAdmin.sol";
import {PerpsPublicLens} from "../../src/perps/PerpsPublicLens.sol";
import {PletherOracle} from "../../src/perps/PletherOracle.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ClaimEngineViewTypes} from "../../src/perps/interfaces/ClaimEngineViewTypes.sol";
import {HousePoolEngineViewTypes} from "../../src/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineAdminHost} from "../../src/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "../../src/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "../../src/perps/interfaces/IHousePool.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "../../src/perps/interfaces/IOrderRouterAdminHost.sol";
import {PerpsViewTypes} from "../../src/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {PositionRiskAccountingLib} from "../../src/perps/libraries/PositionRiskAccountingLib.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {OrderRouterDebugLens} from "../utils/OrderRouterDebugLens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

abstract contract BasePerpTest is Test {

    struct CloseParitySnapshot {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot protocol;
        uint256 settlementUsdc;
        uint256 traderClaimBalanceUsdc;
    }

    struct CloseParityObserved {
        uint256 immediatePayoutUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 badDebtUsdc;
        uint256 remainingSize;
        uint256 remainingMargin;
        bool degradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct LiquidationParitySnapshot {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot protocol;
        uint256 settlementUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 keeperSettlementUsdc;
    }

    struct LiquidationParityObserved {
        uint256 immediatePayoutUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 badDebtUsdc;
        uint256 keeperSettlementUsdc;
        uint256 remainingSize;
        bool degradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct WithdrawParityState {
        bool checkWithdrawPasses;
        bytes4 checkWithdrawSelector;
        bool withdrawPasses;
        bytes4 withdrawSelector;
    }

    MockUSDC usdc;
    CfdEngine engine;
    CfdEngineAdmin engineAdmin;
    CfdEngineAccountLens engineAccountLens;
    CfdEngineLens engineLens;
    CfdEngineProtocolLens engineProtocolLens;
    HousePool pool;
    MarginClearinghouse clearinghouse;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    OrderRouter router;
    OrderRouterAdmin routerAdmin;
    PletherOracle pletherOracle;
    PerpsPublicLens publicLens;
    MockPyth baseMockPyth;

    /// @dev Monday 2024-03-04 10:00 UTC. Avoids FAD window.
    uint256 constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 constant CAP_PRICE = 2e8;
    bytes32 internal constant BASE_PYTH_FEED_A = bytes32(uint256(1));
    bytes32 internal constant BASE_PYTH_FEED_B = bytes32(uint256(2));
    address internal constant PROTOCOL_TREASURY_ACCOUNT = address(0xFEE50001);

    receive() external payable {}

    function setUp() public virtual {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        pool = new HousePool(address(usdc), address(engine));
        baseMockPyth = new MockPyth();
        bytes32[] memory baseFeedIds = _basePythFeedIds();
        baseMockPyth.setAllPrices(baseFeedIds, int64(100_000_000), int32(-8), SETUP_TIMESTAMP);

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");

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
        router = new OrderRouter(address(engine), address(engineLens), address(pool), address(pletherOracle));
        _syncRouterAdmin();
        engine.setOrderRouter(address(router));
        publicLens = new PerpsPublicLens(address(engineAccountLens), address(engine), address(router), address(pool));

        _bypassAllTimelocks();

        uint256 juniorSeed = _initialJuniorSeedDeposit();
        if (juniorSeed > 0) {
            usdc.mint(address(this), juniorSeed);
            usdc.approve(address(pool), juniorSeed);
            pool.initializeSeedPosition(false, juniorSeed, _juniorSeedReceiver());
        }

        uint256 seniorSeed = _initialSeniorSeedDeposit();
        if (seniorSeed > 0) {
            usdc.mint(address(this), seniorSeed);
            usdc.approve(address(pool), seniorSeed);
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
        vm.warp(SETUP_TIMESTAMP);
    }

    function _bootstrapSeededLifecycle() internal {
        uint256 juniorSeed = _initialJuniorSeedDeposit();
        if (juniorSeed > 0 && !pool.hasSeedLifecycleStarted()) {
            usdc.mint(address(this), juniorSeed);
            usdc.approve(address(pool), juniorSeed);
            pool.initializeSeedPosition(false, juniorSeed, _juniorSeedReceiver());
        }

        uint256 seniorSeed = _initialSeniorSeedDeposit();
        if (seniorSeed > 0 && !pool.isSeedLifecycleComplete()) {
            usdc.mint(address(this), seniorSeed);
            usdc.approve(address(pool), seniorSeed);
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
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
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
            _basePythFeedIds(), int64(uint64(price)), 0, int32(-8), publishTime, publishTime == 0 ? 0 : publishTime - 1
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

    // --- Legacy side-index placeholder helpers ---

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundJuniorDelayed(
        address lp,
        uint256 amount
    ) internal returns (uint256 shares) {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        uint256 epochId = juniorVault.requestDeposit(amount, lp);
        vm.stopPrank();

        uint256 activationTime = juniorVault.depositEpochStart(epochId);
        vm.warp(activationTime);
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(activationTime));
        shares = juniorVault.finalizeDepositEpoch(epochId);

        vm.prank(lp);
        juniorVault.claimDepositShares(epochId);
    }

    function _fundSenior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(seniorVault), amount);
        seniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        address account = trader;
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();
    }

    function _currentPoolConfig() internal view returns (IHousePool.PoolConfig memory config) {
        config = IHousePool.PoolConfig({
            seniorRateBps: pool.seniorRateBps(),
            markStalenessLimit: pool.markStalenessLimit(),
            seniorFrozenLpFeeBps: pool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: pool.juniorFrozenLpFeeBps()
        });
    }

    // --- Trading helpers ---

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
        snapshot.settlementUsdc = clearinghouse.balanceUsdc(account);
        snapshot.traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
    }

    function _observeCloseParity(
        address account,
        CloseParitySnapshot memory beforeSnapshot
    ) internal view returns (CloseParityObserved memory observed) {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        (observed.remainingSize, observed.remainingMargin,,,,,) = engine.positions(account);
        uint256 settlementAfter = clearinghouse.balanceUsdc(account);
        observed.immediatePayoutUsdc =
            settlementAfter > beforeSnapshot.settlementUsdc ? settlementAfter - beforeSnapshot.settlementUsdc : 0;
        observed.traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
        observed.badDebtUsdc = afterSnapshot.accumulatedBadDebtUsdc - beforeSnapshot.protocol.accumulatedBadDebtUsdc;
        observed.degradedMode = engine.degradedMode();
        observed.effectiveAssetsAfterUsdc = afterSnapshot.effectiveSolvencyAssetsUsdc;
        observed.maxLiabilityAfterUsdc = afterSnapshot.maxLiabilityUsdc;
    }

    function _assertClosePreviewMatchesObserved(
        ICfdEngineTypes.ClosePreview memory preview,
        CloseParityObserved memory observed,
        bool degradedModeBefore
    ) internal pure {
        assertApproxEqAbs(
            observed.immediatePayoutUsdc,
            preview.immediatePayoutUsdc,
            40_000_000,
            "Immediate payout should stay close to close preview"
        );
        assertApproxEqAbs(
            observed.traderClaimBalanceUsdc,
            preview.traderClaimBalanceUsdc,
            40_000_000,
            "Trader claim should stay close to close preview"
        );
        assertEq(observed.badDebtUsdc, preview.badDebtUsdc, "Bad debt should match close preview");
        assertEq(observed.remainingSize, preview.remainingSize, "Remaining size should match close preview");
        assertEq(observed.remainingMargin, preview.remainingMargin, "Remaining margin should match close preview");
        assertEq(
            observed.degradedMode,
            degradedModeBefore || preview.triggersDegradedMode,
            "Latched degraded mode should match close preview transition semantics"
        );
        assertEq(
            observed.effectiveAssetsAfterUsdc,
            preview.effectiveAssetsAfterUsdc,
            "Effective assets after close should match preview"
        );
        assertEq(
            observed.maxLiabilityAfterUsdc,
            preview.maxLiabilityAfterUsdc,
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
        assertEq(actual.realizedPnlUsdc, expected.realizedPnlUsdc, "Close realized pnl should match");
        assertEq(actual.vpiDeltaUsdc, expected.vpiDeltaUsdc, "Close VPI delta should match");
        assertEq(actual.vpiUsdc, expected.vpiUsdc, "Close VPI should match");
        assertEq(actual.executionFeeUsdc, expected.executionFeeUsdc, "Close execution fee should match");
        assertEq(actual.freshTraderPayoutUsdc, expected.freshTraderPayoutUsdc, "Close fresh payout should match");
        assertEq(
            actual.existingTraderClaimConsumedUsdc,
            expected.existingTraderClaimConsumedUsdc,
            "Close trader claim consumption should match"
        );
        assertEq(
            actual.existingTraderClaimRemainingUsdc,
            expected.existingTraderClaimRemainingUsdc,
            "Close trader claim remainder should match"
        );
        assertEq(actual.immediatePayoutUsdc, expected.immediatePayoutUsdc, "Close immediate payout should match");
        assertEq(actual.traderClaimBalanceUsdc, expected.traderClaimBalanceUsdc, "Close trader claim should match");
        assertEq(actual.seizedCollateralUsdc, expected.seizedCollateralUsdc, "Close seized collateral should match");
        assertEq(actual.badDebtUsdc, expected.badDebtUsdc, "Close bad debt should match");
        assertEq(actual.remainingSize, expected.remainingSize, "Close remaining size should match");
        assertEq(actual.remainingMargin, expected.remainingMargin, "Close remaining margin should match");
        assertEq(actual.triggersDegradedMode, expected.triggersDegradedMode, "Close degraded trigger should match");
        assertEq(actual.postOpDegradedMode, expected.postOpDegradedMode, "Close post-op degraded mode should match");
        assertEq(
            actual.effectiveAssetsAfterUsdc, expected.effectiveAssetsAfterUsdc, "Close effective assets should match"
        );
        assertEq(actual.maxLiabilityAfterUsdc, expected.maxLiabilityAfterUsdc, "Close max liability should match");
    }

    function _captureLiquidationParitySnapshot(
        address account,
        address keeper
    ) internal view returns (LiquidationParitySnapshot memory snapshot) {
        snapshot.protocol = engineProtocolLens.getProtocolAccountingSnapshot();
        snapshot.settlementUsdc = clearinghouse.balanceUsdc(account);
        snapshot.traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
        snapshot.keeperSettlementUsdc = clearinghouse.balanceUsdc(keeper);
    }

    function _observeLiquidationParity(
        address account,
        address keeper,
        LiquidationParitySnapshot memory beforeSnapshot
    ) internal view returns (LiquidationParityObserved memory observed) {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        (observed.remainingSize,,,,,,) = engine.positions(account);
        uint256 settlementAfter = clearinghouse.balanceUsdc(account);
        observed.immediatePayoutUsdc =
            settlementAfter > beforeSnapshot.settlementUsdc ? settlementAfter - beforeSnapshot.settlementUsdc : 0;
        observed.traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
        observed.badDebtUsdc = afterSnapshot.accumulatedBadDebtUsdc - beforeSnapshot.protocol.accumulatedBadDebtUsdc;
        uint256 keeperSettlementAfter = clearinghouse.balanceUsdc(keeper);
        observed.keeperSettlementUsdc = keeperSettlementAfter > beforeSnapshot.keeperSettlementUsdc
            ? keeperSettlementAfter - beforeSnapshot.keeperSettlementUsdc
            : 0;
        observed.degradedMode = engine.degradedMode();
        observed.effectiveAssetsAfterUsdc = afterSnapshot.effectiveSolvencyAssetsUsdc;
        observed.maxLiabilityAfterUsdc = afterSnapshot.maxLiabilityUsdc;
    }

    function _assertLiquidationPreviewMatchesObserved(
        ICfdEngineTypes.LiquidationPreview memory preview,
        LiquidationParityObserved memory observed,
        bool degradedModeBefore
    ) internal pure {
        assertEq(
            observed.immediatePayoutUsdc,
            preview.immediatePayoutUsdc,
            "Immediate trader payout should match liquidation preview"
        );
        assertEq(
            observed.traderClaimBalanceUsdc,
            preview.traderClaimBalanceUsdc,
            "Trader claim balance should match liquidation preview"
        );
        assertEq(observed.badDebtUsdc, preview.badDebtUsdc, "Bad debt should match liquidation preview");
        assertEq(
            observed.keeperSettlementUsdc,
            preview.keeperBountyUsdc,
            "Keeper bounty settlement should match liquidation preview"
        );
        assertEq(observed.remainingSize, 0, "Liquidation parity helper expects the position to be fully removed");
        assertEq(
            observed.degradedMode,
            degradedModeBefore || preview.triggersDegradedMode,
            "Latched degraded mode should match liquidation preview transition semantics"
        );
        assertEq(
            observed.effectiveAssetsAfterUsdc,
            preview.effectiveAssetsAfterUsdc,
            "Effective assets after liquidation should match preview"
        );
        assertEq(
            observed.maxLiabilityAfterUsdc,
            preview.maxLiabilityAfterUsdc,
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
        assertEq(actual.equityUsdc, expected.equityUsdc, "Liquidation equity should match");
        assertEq(actual.pnlUsdc, expected.pnlUsdc, "Liquidation pnl should match");
        assertEq(actual.reachableCollateralUsdc, expected.reachableCollateralUsdc, "Reachable collateral should match");
        assertEq(actual.keeperBountyUsdc, expected.keeperBountyUsdc, "Keeper bounty should match");
        assertEq(actual.seizedCollateralUsdc, expected.seizedCollateralUsdc, "Seized collateral should match");
        assertEq(actual.settlementRetainedUsdc, expected.settlementRetainedUsdc, "Settlement retained should match");
        assertEq(actual.freshTraderPayoutUsdc, expected.freshTraderPayoutUsdc, "Fresh trader payout should match");
        assertEq(
            actual.existingTraderClaimConsumedUsdc,
            expected.existingTraderClaimConsumedUsdc,
            "Trader claim consumption should match"
        );
        assertEq(
            actual.existingTraderClaimRemainingUsdc,
            expected.existingTraderClaimRemainingUsdc,
            "Trader claim remainder should match"
        );
        assertEq(actual.immediatePayoutUsdc, expected.immediatePayoutUsdc, "Immediate payout should match");
        assertEq(actual.traderClaimBalanceUsdc, expected.traderClaimBalanceUsdc, "Trader claim should match");
        assertEq(actual.badDebtUsdc, expected.badDebtUsdc, "Bad debt should match");
        assertEq(actual.triggersDegradedMode, expected.triggersDegradedMode, "Degraded trigger should match");
        assertEq(actual.postOpDegradedMode, expected.postOpDegradedMode, "Post-op degraded mode should match");
        assertEq(actual.effectiveAssetsAfterUsdc, expected.effectiveAssetsAfterUsdc, "Effective assets should match");
        assertEq(actual.maxLiabilityAfterUsdc, expected.maxLiabilityAfterUsdc, "Max liability should match");
    }

    function _observeWithdrawParity(
        address account,
        address trader,
        uint256 amountUsdc
    ) internal returns (WithdrawParityState memory state) {
        vm.prank(address(clearinghouse));
        try engine.checkWithdraw(account) {
            state.checkWithdrawPasses = true;
        } catch (bytes memory err) {
            state.checkWithdrawSelector = _revertSelector(err);
        }

        vm.prank(trader);
        try clearinghouse.withdraw(account, amountUsdc) {
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
        return bytes4(err);
    }

    // --- Governance helpers ---

    function _engineRiskConfig() internal view returns (ICfdEngineAdminHost.EngineRiskConfig memory config) {
        (
            config.riskParams.vpiFactor,
            config.riskParams.maxSkewRatio,
            config.riskParams.maintMarginBps,
            config.riskParams.initMarginBps,
            config.riskParams.fadMarginBps,
            config.riskParams.baseCarryBps,
            config.riskParams.minBountyUsdc,
            config.riskParams.bountyBps
        ) = engine.riskParams();
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
        config.maxOrderAge = router.maxOrderAge();
        config.orderExecutionStalenessLimit = router.orderExecutionStalenessLimit();
        config.liquidationStalenessLimit = router.liquidationStalenessLimit();
        config.pythMaxConfidenceRatioBps = router.pythMaxConfidenceRatioBps();
        config.orderSettlementWindow = router.orderSettlementWindow();
        config.maxComponentPublishTimeDivergence = router.maxComponentPublishTimeDivergence();
        config.adverseConfidenceMultiplierBps = router.adverseConfidenceMultiplierBps();
        config.minOpenNotionalUsdc = router.minOpenNotionalUsdc();
        config.openOrderExecutionBountyBps = router.openOrderExecutionBountyBps();
        config.minOpenOrderExecutionBountyUsdc = router.minOpenOrderExecutionBountyUsdc();
        config.maxOpenOrderExecutionBountyUsdc = router.maxOpenOrderExecutionBountyUsdc();
        config.closeOrderExecutionBountyUsdc = router.closeOrderExecutionBountyUsdc();
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
        deployedEngine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, riskParams_);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(deployedEngine));
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(deployedEngine), address(this));
        deployedEngine.setDependencies(address(planner), address(settlement), address(adminModule));
        deployedEngine.setProtocolTreasury(PROTOCOL_TREASURY_ACCOUNT);
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
        (state.maxProfitUsdc, state.openInterest, state.entryNotional, state.totalMargin) = engine.sides(uint8(side));
    }

    function _maxLiability() internal view returns (uint256) {
        ICfdEngineTypes.SideState memory bull = _sideState(CfdTypes.Side.BULL);
        ICfdEngineTypes.SideState memory bear = _sideState(CfdTypes.Side.BEAR);
        return bull.maxProfitUsdc > bear.maxProfitUsdc ? bull.maxProfitUsdc : bear.maxProfitUsdc;
    }

    function _withdrawalReservedUsdc() internal view returns (uint256) {
        return engineProtocolLens.getProtocolAccountingSnapshot().withdrawalReservedUsdc;
    }

    function _unrealizedTraderPnl() internal view returns (int256) {
        uint256 price = engine.lastMarkPrice();
        if (price == 0) {
            return 0;
        }
        ICfdEngineTypes.SideState memory bull = _sideState(CfdTypes.Side.BULL);
        ICfdEngineTypes.SideState memory bear = _sideState(CfdTypes.Side.BEAR);
        int256 bullPnl = (int256(bull.entryNotional) - int256(bull.openInterest * price)) / int256(1e20);
        int256 bearPnl = (int256(bear.openInterest * price) - int256(bear.entryNotional)) / int256(1e20);
        return bullPnl + bearPnl;
    }

    function _maintenanceMarginUsdc(
        uint256 size,
        uint256 price
    ) internal view returns (uint256) {
        (,, uint256 maintMarginBps,, uint256 fadMarginBps,,,) = engine.riskParams();
        uint256 requiredBps = engine.isFadWindow() ? fadMarginBps : maintMarginBps;
        uint256 notionalUsdc = (size * price) / 1e20;
        return (notionalUsdc * requiredBps) / 10_000;
    }

    function _quoteOpenOrderExecutionBountyUsdc(
        uint256 sizeDelta
    ) internal view returns (uint256) {
        uint256 price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }
        uint256 notionalUsdc = (sizeDelta * price) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        uint256 executionBountyUsdc = (notionalUsdc * router.openOrderExecutionBountyBps()) / 10_000;
        if (executionBountyUsdc < router.minOpenOrderExecutionBountyUsdc()) {
            executionBountyUsdc = router.minOpenOrderExecutionBountyUsdc();
        }
        uint256 maxExecutionBountyUsdc = router.maxOpenOrderExecutionBountyUsdc();
        return executionBountyUsdc > maxExecutionBountyUsdc ? maxExecutionBountyUsdc : executionBountyUsdc;
    }

    function _engineExecutionFeeUsdc(
        uint256 sizeDelta,
        uint256 price
    ) internal view returns (uint256) {
        uint256 notionalUsdc = (sizeDelta * price) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        return (notionalUsdc * engine.executionFeeBps()) / 10_000;
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

    // Historical helper name retained for obsolete carry/spread regression context.
    // The live system does not maintain a legacy side-index state; this helper is intentionally zero.
    function _legacySideIndexZero(
        CfdTypes.Side side
    ) internal pure returns (int256) {
        side;
        return 0;
    }

    // Historical helper name retained for obsolete carry/spread regression context.
    // The live carry model does not use a legacy side-entry index; this helper is intentionally zero.
    function _legacySideEntryIndexZero(
        CfdTypes.Side side
    ) internal pure returns (int256) {
        side;
        return 0;
    }

    function _sideMaxProfit(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).maxProfitUsdc;
    }

    function _orderRecord(
        uint64 orderId
    ) internal view returns (OrderRouter.OrderRecord memory record) {
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
        return clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
    }

    function _executionBountyReserve(
        uint64 orderId
    ) internal view returns (uint256) {
        return _orderRecord(orderId).executionBountyUsdc;
    }

    function _isInMarginQueue(
        uint64 orderId
    ) internal view returns (bool) {
        return _orderRecord(orderId).inMarginQueue;
    }

    function _freeSettlementUsdc(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc;
    }

    function _expectedIndexedCarryUsdc(
        address account
    ) internal view returns (uint256) {
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return 0;
        }
        (uint256 borrowBaseUsdc, uint256 startIndex,) = engine.positionCarryState(account);
        if (borrowBaseUsdc == 0) {
            return 0;
        }
        uint256 endIndex = _currentSideCarryIndex(side);
        if (endIndex <= startIndex) {
            return 0;
        }
        return PositionRiskAccountingLib.computeIndexedCarryUsdc(borrowBaseUsdc, endIndex - startIndex);
    }

    function _positionBorrowBaseUsdc(
        address account
    ) internal view returns (uint256 borrowBaseUsdc) {
        (borrowBaseUsdc,,) = engine.positionCarryState(account);
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
        (,,,,, uint256 baseCarryBps,,) = engine.riskParams();
        index = PositionRiskAccountingLib.computeCurrentCarryIndex(
            engine.sideCarryIndex(sideIndex),
            engine.sideCarryTimestamp(sideIndex),
            block.timestamp,
            engine.sideBorrowBaseUsdc(sideIndex),
            pool.totalAssets(),
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
        return clearinghouse.balanceUsdc(_accountOf(account));
    }

    function _fundProtocolTreasury(
        uint256 amountUsdc
    ) internal {
        address treasury = engine.protocolTreasury();
        usdc.mint(address(clearinghouse), amountUsdc);
        vm.prank(address(engine));
        clearinghouse.settleUsdc(treasury, int256(amountUsdc));
    }

    function _withdrawProtocolTreasury(
        uint256 amountUsdc
    ) internal {
        address treasury = engine.protocolTreasury();
        vm.prank(treasury);
        clearinghouse.withdraw(treasury, amountUsdc);
    }

    function _terminalReachableUsdc(
        address account
    ) internal view returns (uint256) {
        uint256 settlementBalance = clearinghouse.getAccountUsdcBuckets(account).settlementBalanceUsdc;
        uint256 executionReservation = router.getAccountReservations(account).executionBountyUsdc;
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
        uint256 traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
        bool anyLiquidity = pool.totalAssets() > 0;

        status.traderClaimBalanceUsdc = traderClaimBalanceUsdc;
        status.traderClaimServiceableNow = traderClaimBalanceUsdc > 0 && anyLiquidity;
        keeper;
    }

    function _poolMtmAdjustment() internal view returns (uint256) {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        return snapshot.unrealizedMtmLiabilityUsdc;
    }

}
