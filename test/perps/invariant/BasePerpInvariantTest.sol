// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "../../../src/perps/CfdEngineAccountLens.sol";
import {CfdEngineAdmin} from "../../../src/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "../../../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "../../../src/perps/CfdEnginePlanner.sol";
import {CfdEngineProtocolLens} from "../../../src/perps/CfdEngineProtocolLens.sol";
import {CfdEngineSettlementModule} from "../../../src/perps/CfdEngineSettlementModule.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "../../../src/perps/OrderRouterAdmin.sol";
import {PerpsPublicLens} from "../../../src/perps/PerpsPublicLens.sol";
import {DeferredEngineViewTypes} from "../../../src/perps/interfaces/DeferredEngineViewTypes.sol";
import {IOrderRouterAccounting} from "../../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {PerpsViewTypes} from "../../../src/perps/interfaces/PerpsViewTypes.sol";
import {MockPyth} from "../../mocks/MockPyth.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {OrderRouterDebugLens} from "../../utils/OrderRouterDebugLens.sol";
import {MockInvariantVault} from "./mocks/MockInvariantVault.sol";
import {Test} from "forge-std/Test.sol";

abstract contract BasePerpInvariantTest is Test {

    MockUSDC internal usdc;
    CfdEngine internal engine;
    CfdEngineAdmin internal engineAdmin;
    CfdEngineAccountLens internal engineAccountLens;
    CfdEngineLens internal engineLens;
    CfdEngineProtocolLens internal engineProtocolLens;
    MarginClearinghouse internal clearinghouse;
    MockInvariantVault internal vault;
    MockPyth internal mockPyth;
    OrderRouter internal router;
    OrderRouterAdmin internal routerAdmin;
    PerpsPublicLens internal publicLens;

    uint256 internal constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 internal constant CAP_PRICE = 2e8;

    function setUp() public virtual {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        vault = new MockInvariantVault(address(usdc), address(engine));
        mockPyth = new MockPyth();
        mockPyth.setPrice(bytes32(uint256(1)), int64(100_000_000), int32(-8), uint64(SETUP_TIMESTAMP));
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        router = new OrderRouter(
            address(engine),
            address(engineLens),
            address(vault),
            address(mockPyth),
            feedIds,
            weights,
            basePrices,
            new bool[](1)
        );
        _syncRouterAdmin();

        clearinghouse.setEngine(address(engine));
        vm.warp(SETUP_TIMESTAMP);

        engine.setVault(address(vault));
        engine.setOrderRouter(address(router));
        vault.setOrderRouter(address(router));
        publicLens = new PerpsPublicLens(address(engineAccountLens), address(engine), address(router), address(0));

        uint256 initialVaultAssets = _initialVaultAssets();
        if (initialVaultAssets > 0) {
            vault.seedAssets(initialVaultAssets);
        }
    }

    function _riskParams() internal pure virtual returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 9
        });
    }

    function _initialVaultAssets() internal pure virtual returns (uint256) {
        return 1_000_000_000e6;
    }

    function _syncEngineAdmin() internal {
        engineAdmin = CfdEngineAdmin(engine.admin());
    }

    function _deployEngine(
        CfdTypes.RiskParams memory riskParams_
    ) internal returns (CfdEngine deployedEngine) {
        deployedEngine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, riskParams_);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementModule settlement = new CfdEngineSettlementModule(address(deployedEngine));
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(deployedEngine), address(this));
        deployedEngine.setDependencies(address(planner), address(settlement), address(adminModule));
    }

    function _syncRouterAdmin() internal {
        routerAdmin = OrderRouterAdmin(router.admin());
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

    function _terminalReachableUsdc(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.getAccountUsdcBuckets(account).settlementBalanceUsdc;
    }

    function _publicPosition(
        address account
    ) internal view returns (PerpsViewTypes.PositionView memory viewData) {
        return publicLens.getPosition(account);
    }

    function _publicProtocolStatus() internal view returns (PerpsViewTypes.ProtocolStatusView memory viewData) {
        return publicLens.getProtocolStatus();
    }

    function _maxLiability() internal view returns (uint256) {
        (uint256 bullMaxProfit,,,) = engine.sides(uint8(CfdTypes.Side.BULL));
        (uint256 bearMaxProfit,,,) = engine.sides(uint8(CfdTypes.Side.BEAR));
        return bullMaxProfit > bearMaxProfit ? bullMaxProfit : bearMaxProfit;
    }

    function _withdrawalReservedUsdc() internal view returns (uint256) {
        return engineProtocolLens.getProtocolAccountingSnapshot().withdrawalReservedUsdc;
    }

    function _unrealizedTraderPnl() internal view returns (int256) {
        uint256 price = engine.lastMarkPrice();
        if (price == 0) {
            return 0;
        }
        (uint256 bullMaxProfit, uint256 bullOi, uint256 bullEntryNotional,) = engine.sides(uint8(CfdTypes.Side.BULL));
        bullMaxProfit;
        (uint256 bearMaxProfit, uint256 bearOi, uint256 bearEntryNotional,) = engine.sides(uint8(CfdTypes.Side.BEAR));
        bearMaxProfit;
        int256 bullPnl = (int256(bullEntryNotional) - int256(bullOi * price)) / int256(1e20);
        int256 bearPnl = (int256(bearOi * price) - int256(bearEntryNotional)) / int256(1e20);
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

    function _deferredCreditStatus(
        address account,
        address keeper
    ) internal view returns (DeferredEngineViewTypes.DeferredCreditStatus memory status) {
        uint256 deferredTraderCreditUsdc = engine.deferredTraderCreditUsdc(account);
        uint256 deferredKeeperCreditUsdc = engine.deferredKeeperCreditUsdc(keeper);
        bool anyLiquidity = vault.totalAssets() > 0;

        status.deferredTraderCreditUsdc = deferredTraderCreditUsdc;
        status.traderPayoutClaimableNow = deferredTraderCreditUsdc > 0 && anyLiquidity;
        status.deferredKeeperCreditUsdc = deferredKeeperCreditUsdc;
        status.keeperCreditClaimableNow = deferredKeeperCreditUsdc > 0 && anyLiquidity;
    }

}
