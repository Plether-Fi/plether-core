// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "../../../src/perps/CfdEngineAccountLens.sol";
import {CfdEngineLens} from "../../../src/perps/CfdEngineLens.sol";
import {CfdEngineProtocolLens} from "../../../src/perps/CfdEngineProtocolLens.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {PerpsPublicLens} from "../../../src/perps/PerpsPublicLens.sol";
import {DeferredEngineViewTypes} from "../../../src/perps/interfaces/DeferredEngineViewTypes.sol";
import {PerpsViewTypes} from "../../../src/perps/interfaces/PerpsViewTypes.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MockInvariantVault} from "./mocks/MockInvariantVault.sol";
import {Test} from "forge-std/Test.sol";

abstract contract BasePerpInvariantTest is Test {

    MockUSDC internal usdc;
    CfdEngine internal engine;
    CfdEngineAccountLens internal engineAccountLens;
    CfdEngineLens internal engineLens;
    CfdEngineProtocolLens internal engineProtocolLens;
    MarginClearinghouse internal clearinghouse;
    MockInvariantVault internal vault;
    OrderRouter internal router;
    PerpsPublicLens internal publicLens;

    uint256 internal constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 internal constant CAP_PRICE = 2e8;

    function setUp() public virtual {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        vault = new MockInvariantVault(address(usdc), address(engine));
        router = new OrderRouter(
            address(engine),
            address(vault),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );

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

    function _orderRecord(
        uint64 orderId
    ) internal view returns (OrderRouter.OrderRecord memory record) {
        return router.getOrderRecord(orderId);
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
        bytes32 accountId
    ) internal view returns (uint256) {
        return clearinghouse.getAccountUsdcBuckets(accountId).freeSettlementUsdc;
    }

    function _terminalReachableUsdc(
        bytes32 accountId
    ) internal view returns (uint256) {
        return clearinghouse.getAccountUsdcBuckets(accountId).settlementBalanceUsdc;
    }

    function _publicPosition(
        bytes32 accountId
    ) internal view returns (PerpsViewTypes.PositionView memory viewData) {
        return publicLens.getPosition(accountId);
    }

    function _publicProtocolStatus(
    ) internal view returns (PerpsViewTypes.ProtocolStatusView memory viewData) {
        return publicLens.getProtocolStatus();
    }

    function _deferredPayoutStatus(
        bytes32 accountId,
        address keeper
    ) internal view returns (DeferredEngineViewTypes.DeferredPayoutStatus memory status) {
        uint256 deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);
        uint256 deferredClearerBountyUsdc = engine.deferredClearerBountyUsdc(keeper);
        bool anyLiquidity = vault.totalAssets() > 0;

        status.deferredTraderPayoutUsdc = deferredPayoutUsdc;
        status.traderPayoutClaimableNow = deferredPayoutUsdc > 0 && anyLiquidity;
        status.deferredClearerBountyUsdc = deferredClearerBountyUsdc;
        status.liquidationBountyClaimableNow = deferredClearerBountyUsdc > 0 && anyLiquidity;
    }

}
