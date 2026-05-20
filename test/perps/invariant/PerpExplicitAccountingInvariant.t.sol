// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdEngineLens} from "../../../src/perps/CfdEngineLens.sol";
import {CfdEngineProtocolLens} from "../../../src/perps/CfdEngineProtocolLens.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {HousePool} from "../../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {ICfdEngineTypes} from "../../../src/perps/interfaces/ICfdEngineTypes.sol";
import {ProtocolLensViewTypes} from "../../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {BasePerpTest} from "../BasePerpTest.sol";
import {Test} from "forge-std/Test.sol";

contract PerpExplicitAccountingHandler is Test {

    struct CloseObserved {
        uint256 immediatePayoutUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 badDebtUsdc;
        uint256 remainingSize;
        uint256 remainingMargin;
        bool degradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct LiquidationObserved {
        uint256 immediatePayoutUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 badDebtUsdc;
        uint256 keeperBountyUsdc;
        uint256 remainingSize;
        bool degradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    MockUSDC internal immutable usdc;
    CfdEngine internal immutable engine;
    CfdEngineLens internal immutable engineLens;
    CfdEngineProtocolLens internal immutable engineProtocolLens;
    MarginClearinghouse internal immutable clearinghouse;
    HousePool internal immutable pool;
    OrderRouter internal immutable router;

    address internal constant BULL_TRADER = address(0xACCA01);
    address internal constant BEAR_TRADER = address(0xACCA02);
    address internal constant KEEPER = address(0xACCA03);

    bool public closePreviewLiveMismatch;
    bool public liquidationPreviewLiveMismatch;
    bool public lpTraderProtocolConservationMismatch;
    bool public physicalCashConservationMismatch;

    uint8 public closeMismatchCode;
    uint8 public liquidationMismatchCode;
    uint256 public expectedValue;
    uint256 public actualValue;

    constructor(
        MockUSDC usdc_,
        CfdEngine engine_,
        CfdEngineLens engineLens_,
        CfdEngineProtocolLens engineProtocolLens_,
        MarginClearinghouse clearinghouse_,
        HousePool pool_,
        OrderRouter router_
    ) {
        usdc = usdc_;
        engine = engine_;
        engineLens = engineLens_;
        engineProtocolLens = engineProtocolLens_;
        clearinghouse = clearinghouse_;
        pool = pool_;
        router = router_;
    }

    function closePreviewMatchesLive(
        uint256 sizeFuzz,
        uint256 marginFuzz,
        uint256 closeSizeFuzz,
        uint256 closePriceFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool mismatch;
        uint8 mismatchCode;
        uint256 expected;
        uint256 actual;

        uint256 size = bound(sizeFuzz, 20_000e18, 300_000e18);
        uint256 margin = _boundedHealthyMargin(size, marginFuzz);
        uint256 closePrice = bound(closePriceFuzz, 0.6e8, 1.4e8);

        if (_openPair(size, margin, 1e8)) {
            uint256 closeSize = bound(closeSizeFuzz, 1, size);
            ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(BULL_TRADER, closeSize, closePrice);
            if (preview.valid) {
                uint256 settlementBefore = clearinghouse.balanceUsdc(BULL_TRADER);
                uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
                bool degradedBefore = engine.degradedMode();

                bool executed = _close(BULL_TRADER, CfdTypes.Side.BULL, closeSize, closePrice);
                if (!executed) {
                    mismatch = true;
                    mismatchCode = 1;
                } else {
                    CloseObserved memory observed =
                        _observeClose(BULL_TRADER, settlementBefore, badDebtBefore, degradedBefore);
                    (mismatch, mismatchCode, expected, actual) = _closeMismatch(preview, observed, degradedBefore);
                }
            }
        }

        vm.revertToState(snapshot);
        if (mismatch) {
            closePreviewLiveMismatch = true;
            closeMismatchCode = mismatchCode;
            expectedValue = expected;
            actualValue = actual;
        }
    }

    function liquidationPreviewMatchesLive(
        uint256 sizeFuzz,
        uint256 liquidationPriceFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool mismatch;
        uint8 mismatchCode;
        uint256 expected;
        uint256 actual;

        uint256 size = bound(sizeFuzz, 20_000e18, 300_000e18);
        uint256 margin = _initialishMargin(size);
        uint256 liquidationPrice = bound(liquidationPriceFuzz, 1.05e8, 1.8e8);

        if (_openPair(size, margin, 1e8)) {
            ICfdEngineTypes.LiquidationPreview memory preview =
                engineLens.previewLiquidation(BULL_TRADER, liquidationPrice);
            if (preview.liquidatable) {
                uint256 settlementBefore = clearinghouse.balanceUsdc(BULL_TRADER);
                uint256 keeperBefore = clearinghouse.balanceUsdc(KEEPER);
                uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
                bool degradedBefore = engine.degradedMode();

                bool executed = _liquidate(BULL_TRADER, liquidationPrice, KEEPER);
                if (!executed) {
                    mismatch = true;
                    mismatchCode = 1;
                } else {
                    LiquidationObserved memory observed = _observeLiquidation(
                        BULL_TRADER, KEEPER, settlementBefore, keeperBefore, badDebtBefore, degradedBefore
                    );
                    (mismatch, mismatchCode, expected, actual) = _liquidationMismatch(preview, observed, degradedBefore);
                }
            }
        }

        vm.revertToState(snapshot);
        if (mismatch) {
            liquidationPreviewLiveMismatch = true;
            liquidationMismatchCode = mismatchCode;
            expectedValue = expected;
            actualValue = actual;
        }
    }

    function pairedRoundTripConservesLpTraderProtocolValue(
        uint256 sizeFuzz,
        uint256 marginFuzz,
        uint256 closePriceFuzz,
        uint256 elapsedFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool valueMismatch;
        bool cashMismatch;
        uint256 expected;
        uint256 actual;

        uint256 size = bound(sizeFuzz, 20_000e18, 250_000e18);
        uint256 margin = _boundedHealthyMargin(size, marginFuzz);
        uint256 closePrice = bound(closePriceFuzz, 0.7e8, 1.3e8);

        if (_openPair(size, margin, 1e8)) {
            uint256 valueBefore = _lpTraderProtocolValue();
            uint256 physicalCashBefore = _protocolPhysicalCash();

            vm.warp(block.timestamp + bound(elapsedFuzz, 0, 30 days));

            ICfdEngineTypes.ClosePreview memory bullPreview = engineLens.previewClose(BULL_TRADER, size, closePrice);
            if (bullPreview.valid && _close(BULL_TRADER, CfdTypes.Side.BULL, size, closePrice)) {
                ICfdEngineTypes.ClosePreview memory bearPreview = engineLens.previewClose(BEAR_TRADER, size, closePrice);
                if (bearPreview.valid && _close(BEAR_TRADER, CfdTypes.Side.BEAR, size, closePrice)) {
                    uint256 valueAfter = _lpTraderProtocolValue();
                    uint256 physicalCashAfter = _protocolPhysicalCash();
                    valueMismatch = valueAfter != valueBefore;
                    cashMismatch = physicalCashAfter != physicalCashBefore;
                    expected = valueMismatch ? valueBefore : physicalCashBefore;
                    actual = valueMismatch ? valueAfter : physicalCashAfter;
                }
            }
        }

        vm.revertToState(snapshot);
        if (valueMismatch) {
            lpTraderProtocolConservationMismatch = true;
            expectedValue = expected;
            actualValue = actual;
        }
        if (cashMismatch) {
            physicalCashConservationMismatch = true;
            expectedValue = expected;
            actualValue = actual;
        }
    }

    function _observeClose(
        address account,
        uint256 settlementBefore,
        uint256 badDebtBefore,
        bool
    ) internal view returns (CloseObserved memory observed) {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        (observed.remainingSize, observed.remainingMargin,,,,,) = engine.positions(account);
        uint256 settlementAfter = clearinghouse.balanceUsdc(account);
        observed.immediatePayoutUsdc = settlementAfter > settlementBefore ? settlementAfter - settlementBefore : 0;
        observed.traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
        observed.badDebtUsdc = afterSnapshot.accumulatedBadDebtUsdc - badDebtBefore;
        observed.degradedMode = engine.degradedMode();
        observed.effectiveAssetsAfterUsdc = afterSnapshot.effectiveSolvencyAssetsUsdc;
        observed.maxLiabilityAfterUsdc = afterSnapshot.maxLiabilityUsdc;
    }

    function _observeLiquidation(
        address account,
        address keeper,
        uint256 settlementBefore,
        uint256 keeperBefore,
        uint256 badDebtBefore,
        bool
    ) internal view returns (LiquidationObserved memory observed) {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        (observed.remainingSize,,,,,,) = engine.positions(account);
        uint256 settlementAfter = clearinghouse.balanceUsdc(account);
        observed.immediatePayoutUsdc = settlementAfter > settlementBefore ? settlementAfter - settlementBefore : 0;
        observed.traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
        observed.badDebtUsdc = afterSnapshot.accumulatedBadDebtUsdc - badDebtBefore;
        uint256 keeperAfter = clearinghouse.balanceUsdc(keeper);
        observed.keeperBountyUsdc = keeperAfter > keeperBefore ? keeperAfter - keeperBefore : 0;
        observed.degradedMode = engine.degradedMode();
        observed.effectiveAssetsAfterUsdc = afterSnapshot.effectiveSolvencyAssetsUsdc;
        observed.maxLiabilityAfterUsdc = afterSnapshot.maxLiabilityUsdc;
    }

    function _closeMismatch(
        ICfdEngineTypes.ClosePreview memory preview,
        CloseObserved memory observed,
        bool degradedBefore
    ) internal pure returns (bool mismatch, uint8 code, uint256 expected, uint256 actual) {
        if (observed.immediatePayoutUsdc != preview.immediatePayoutUsdc) {
            return (true, 2, preview.immediatePayoutUsdc, observed.immediatePayoutUsdc);
        }
        if (observed.traderClaimBalanceUsdc != preview.traderClaimBalanceUsdc) {
            return (true, 3, preview.traderClaimBalanceUsdc, observed.traderClaimBalanceUsdc);
        }
        if (observed.badDebtUsdc != preview.badDebtUsdc) {
            return (true, 4, preview.badDebtUsdc, observed.badDebtUsdc);
        }
        if (observed.remainingSize != preview.remainingSize) {
            return (true, 5, preview.remainingSize, observed.remainingSize);
        }
        if (observed.remainingMargin != preview.remainingMargin) {
            return (true, 6, preview.remainingMargin, observed.remainingMargin);
        }
        bool expectedDegraded = degradedBefore || preview.triggersDegradedMode;
        if (observed.degradedMode != expectedDegraded) {
            return (true, 7, expectedDegraded ? 1 : 0, observed.degradedMode ? 1 : 0);
        }
        if (observed.effectiveAssetsAfterUsdc != preview.effectiveAssetsAfterUsdc) {
            return (true, 8, preview.effectiveAssetsAfterUsdc, observed.effectiveAssetsAfterUsdc);
        }
        if (observed.maxLiabilityAfterUsdc != preview.maxLiabilityAfterUsdc) {
            return (true, 9, preview.maxLiabilityAfterUsdc, observed.maxLiabilityAfterUsdc);
        }
        return (false, 0, 0, 0);
    }

    function _liquidationMismatch(
        ICfdEngineTypes.LiquidationPreview memory preview,
        LiquidationObserved memory observed,
        bool degradedBefore
    ) internal pure returns (bool mismatch, uint8 code, uint256 expected, uint256 actual) {
        if (observed.immediatePayoutUsdc != preview.immediatePayoutUsdc) {
            return (true, 2, preview.immediatePayoutUsdc, observed.immediatePayoutUsdc);
        }
        if (observed.traderClaimBalanceUsdc != preview.traderClaimBalanceUsdc) {
            return (true, 3, preview.traderClaimBalanceUsdc, observed.traderClaimBalanceUsdc);
        }
        if (observed.badDebtUsdc != preview.badDebtUsdc) {
            return (true, 4, preview.badDebtUsdc, observed.badDebtUsdc);
        }
        if (observed.keeperBountyUsdc != preview.keeperBountyUsdc) {
            return (true, 5, preview.keeperBountyUsdc, observed.keeperBountyUsdc);
        }
        if (observed.remainingSize != 0) {
            return (true, 6, 0, observed.remainingSize);
        }
        bool expectedDegraded = degradedBefore || preview.triggersDegradedMode;
        if (observed.degradedMode != expectedDegraded) {
            return (true, 7, expectedDegraded ? 1 : 0, observed.degradedMode ? 1 : 0);
        }
        if (observed.effectiveAssetsAfterUsdc != preview.effectiveAssetsAfterUsdc) {
            return (true, 8, preview.effectiveAssetsAfterUsdc, observed.effectiveAssetsAfterUsdc);
        }
        if (observed.maxLiabilityAfterUsdc != preview.maxLiabilityAfterUsdc) {
            return (true, 9, preview.maxLiabilityAfterUsdc, observed.maxLiabilityAfterUsdc);
        }
        return (false, 0, 0, 0);
    }

    function _openPair(
        uint256 size,
        uint256 margin,
        uint256 price
    ) internal returns (bool) {
        uint256 fee = _executionFee(size, price);
        _fundTrader(BULL_TRADER, margin + fee + 10e6);
        _fundTrader(BEAR_TRADER, margin + fee + 10e6);
        return _open(BULL_TRADER, CfdTypes.Side.BULL, size, margin, price)
            && _open(BEAR_TRADER, CfdTypes.Side.BEAR, size, margin, price);
    }

    function _open(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price
    ) internal returns (bool) {
        vm.prank(address(router));
        try engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            pool.totalAssets(),
            uint64(block.timestamp)
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _close(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) internal returns (bool) {
        vm.prank(address(router));
        try engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: true
            }),
            price,
            pool.totalAssets(),
            uint64(block.timestamp)
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _liquidate(
        address account,
        uint256 price,
        address keeper
    ) internal returns (bool) {
        vm.prank(address(router));
        try engine.liquidatePosition(account, price, pool.totalAssets(), uint64(block.timestamp), keeper) returns (
            uint256
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _fundTrader(
        address account,
        uint256 amount
    ) internal {
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();
    }

    function _lpTraderProtocolValue() internal view returns (uint256) {
        uint256 traderClaims = engine.traderClaimBalanceUsdc(BULL_TRADER) + engine.traderClaimBalanceUsdc(BEAR_TRADER);
        uint256 lpNetAssets = pool.totalAssets() > traderClaims ? pool.totalAssets() - traderClaims : 0;
        return lpNetAssets + traderClaims + clearinghouse.balanceUsdc(BULL_TRADER)
            + clearinghouse.balanceUsdc(BEAR_TRADER) + clearinghouse.balanceUsdc(KEEPER)
            + clearinghouse.balanceUsdc(engine.protocolTreasury());
    }

    function _protocolPhysicalCash() internal view returns (uint256) {
        return usdc.balanceOf(address(pool)) + usdc.balanceOf(address(clearinghouse)) + usdc.balanceOf(address(engine))
            + usdc.balanceOf(address(router));
    }

    function _boundedHealthyMargin(
        uint256 size,
        uint256 marginFuzz
    ) internal pure returns (uint256) {
        uint256 notionalUsdc = _notional(size, 1e8);
        uint256 minMargin = (notionalUsdc * 2000) / 10_000;
        uint256 maxMargin = (notionalUsdc * 7000) / 10_000;
        return bound(marginFuzz, minMargin, maxMargin);
    }

    function _initialishMargin(
        uint256 size
    ) internal pure returns (uint256) {
        uint256 notionalUsdc = _notional(size, 1e8);
        return (notionalUsdc * 200) / 10_000;
    }

    function _executionFee(
        uint256 size,
        uint256 price
    ) internal view returns (uint256) {
        return (_notional(size, price) * engine.executionFeeBps()) / 10_000;
    }

    function _notional(
        uint256 size,
        uint256 price
    ) internal pure returns (uint256) {
        return (size * price) / 1e20;
    }

}

contract PerpExplicitAccountingInvariantTest is BasePerpTest {

    PerpExplicitAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpExplicitAccountingHandler(
            usdc, engine, engineLens, engineProtocolLens, clearinghouse, pool, router
        );

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.closePreviewMatchesLive.selector;
        selectors[1] = handler.liquidationPreviewMatchesLive.selector;
        selectors[2] = handler.pairedRoundTripConservesLpTraderProtocolValue.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_ClosePreviewMatchesLiveSettlement() public view {
        assertFalse(handler.closePreviewLiveMismatch(), "Close preview diverged from live settlement");
    }

    function invariant_LiquidationPreviewMatchesLiveSettlement() public view {
        assertFalse(handler.liquidationPreviewLiveMismatch(), "Liquidation preview diverged from live settlement");
    }

    function invariant_LpTraderProtocolValueIsConservedAcrossRoundTrip() public view {
        assertFalse(handler.lpTraderProtocolConservationMismatch(), "LP/trader/protocol value was not conserved");
    }

    function invariant_ProtocolPhysicalCashIsConservedAcrossRoundTrip() public view {
        assertFalse(handler.physicalCashConservationMismatch(), "Protocol physical cash was not conserved");
    }

}
