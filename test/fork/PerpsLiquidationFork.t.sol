// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../packages/perps/test/perps/BasePerpTest.sol";
import {LegacyOrderRouterHarness} from "../../packages/perps/test/utils/LegacyOrderRouterHarness.sol";
import {ArbitrumSepoliaReleaseOracle} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPyth} from "@plether/shared/interfaces/IPyth.sol";
import {ArbitrumForkSupport} from "@plether/test-utils/ArbitrumForkSupport.sol";

/// @notice Real signed September/October FX ticks drive a normal V3 position from healthy to liquidatable.
/// @dev Local collateral and pool bootstrap come from BasePerpTest; the traded prices, Pyth code, storage and signed
///      payloads are untouched. Ten days of carry accrue naturally between the recorded ticks.
contract PerpsLiquidationForkTest is BasePerpTest {

    address internal constant REAL_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    address internal constant TRADER = address(0xA11CE);
    address internal constant KEEPER = address(0xCEEE);
    uint256 internal constant POSITION_SIZE = 100_000e18;

    // Known outputs of the six signed feeds in the committed fixtures, at the inherited 2000 bps confidence policy.
    // SHORT entry is shifted up; liquidation is shifted down. These constants are independent of runtime previews.
    uint256 internal constant OPEN_MARK = 97_667_164;
    uint256 internal constant OPEN_PRICE = 97_667_890;
    uint256 internal constant LIQUIDATION_MARK = 96_458_521;
    uint256 internal constant LIQUIDATION_PRICE = 96_458_009;
    uint256 internal constant PRICE_LOSS_ASSETS = 1_209_881_000;
    uint256 internal constant LIQUIDATION_CHARGE_ASSETS = 96_458_009;
    uint256 internal constant KEEPER_BOUNTY_ASSETS = 48_229_004;
    // floor(100468.845046 settlement tokens * 5% annual rate * 0.1002 utilization * 879494 / 31536000) = 14.037682 settlement tokens.
    // Utilization is floored to 1002 bps against the fixed 1,002,000-token pool; indexed rounding gives the same atoms.
    uint256 internal constant CARRY_ASSETS = 14_037_682;
    uint256 internal constant ETH_SURPLUS = 1 gwei;

    string internal openingFixture;
    string internal liquidationFixture;
    bytes32[] internal ids;

    function setUp() public override {
        openingFixture = vm.readFile("test/fixtures/oracle-sync/arbitrum-sepolia.json");
        liquidationFixture = vm.readFile("test/fixtures/oracle-sync/friday-opening.json");
        uint256 forkNumber = vm.parseJsonUint(openingFixture, ".forkBlockNumber");
        vm.createSelectFork(vm.envString("ARB_SEPOLIA_RPC_URL"), forkNumber);
        ArbitrumForkSupport.install();
        assertEq(block.chainid, 421_614);
        vm.roll(forkNumber + 1);
        assertEq(blockhash(forkNumber), vm.parseJsonBytes32(openingFixture, ".forkBlockHash"));
        vm.roll(forkNumber);
        assertEq(vm.getBlockTimestamp(), vm.parseJsonUint(openingFixture, ".forkTimestamp"));
        assertEq(vm.parseJsonAddress(openingFixture, ".pyth"), REAL_PYTH);
        assertEq(vm.parseJsonAddress(liquidationFixture, ".pyth"), REAL_PYTH);
        assertGt(REAL_PYTH.code.length, 0);
        ids = vm.parseJsonBytes32Array(openingFixture, ".feedIds");
        assertEq(ids.length, 6);
        assertEq(abi.encode(ids), abi.encode(vm.parseJsonBytes32Array(liquidationFixture, ".feedIds")));
        _assertStoredTimes(vm.parseJsonUintArray(openingFixture, ".initialStoredPublishTimes"));

        vm.warp(SETUP_TIMESTAMP);
        super.setUp();
        pletherOracle = new ArbitrumSepoliaReleaseOracle(
            address(engine),
            address(pool),
            REAL_PYTH,
            ids,
            vm.parseJsonUintArray(openingFixture, ".quantities"),
            vm.parseJsonUintArray(openingFixture, ".basePrices"),
            abi.decode(vm.parseJson(openingFixture, ".inversions"), (bool[]))
        );
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig(address(pletherOracle)));
        vm.warp(vm.parseJsonUint(openingFixture, ".forkTimestamp"));
        assertGe(vm.getBlockTimestamp(), routerAdmin.oracleConfigActivationTime());
        routerAdmin.finalizeOracleConfig();
        assertEq(pletherOracle.adverseConfidenceMultiplierBps(), 2000, "rotation retains the active policy");
        _assertStoredTimes(vm.parseJsonUintArray(openingFixture, ".initialStoredPublishTimes"));
        vm.deal(KEEPER, 10 ether);
        _fundTrader(TRADER, 10_000e6);
        _openSignedPosition();
    }

    function test_RealSignedHealthyLiquidationRevertsAndRollsBack() public {
        assertFalse(engineLens.previewLiquidation(TRADER, OPEN_MARK - 726).liquidatable);
        bytes[] memory data = _data(openingFixture);
        uint256 fee = pletherOracle.getUpdateFee(data);
        assertEq(fee, 0, "this pinned Pyth testnet deployment charges zero update fee");
        (bool accepted,,) = pletherOracle.getAcceptedBasketMark();
        assertFalse(accepted, "historical order resolution must not create a live accepted basket");
        bytes32 beforeState = _stateDigest();

        vm.prank(KEEPER);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation{value: fee + ETH_SURPLUS}(TRADER, data);

        assertEq(_stateDigest(), beforeState, "solvent rejection must roll back pricing, custody, fees and position");
        _assertStoredTimes(vm.parseJsonUintArray(openingFixture, ".publishTimes"));
    }

    function test_RealSignedLiquidationPaysKeeperAndSettlesPosition() public {
        IMarginClearinghouse.PnlIsolationBuckets memory beforeBuckets = clearinghouse.getPnlIsolationBuckets(TRADER);
        assertEq(beforeBuckets.freeSettlementAssets, 0, "free cash was withdrawn normally");
        assertEq(beforeBuckets.actionReserveAssets, 0);
        assertEq(beforeBuckets.orderMarginAssets, 0);
        assertGt(beforeBuckets.pnlPledgeAssets, PRICE_LOSS_ASSETS, "signed move leaves positive price equity");
        assertGt(beforeBuckets.liquidationReserveAssets, LIQUIDATION_CHARGE_ASSETS);
        uint256 poolCashBefore = settlementToken.balanceOf(address(pool));
        uint256 clearingCashBefore = settlementToken.balanceOf(address(clearinghouse));
        uint256 keeperCreditBefore = clearinghouse.balanceAssets(KEEPER);
        uint256 treasuryCreditBefore = clearinghouse.balanceAssets(PROTOCOL_TREASURY_ACCOUNT);
        uint256 traderWalletBefore = settlementToken.balanceOf(TRADER);
        uint256 keeperWalletBefore = settlementToken.balanceOf(KEEPER);

        vm.warp(vm.parseJsonUint(liquidationFixture, ".executionTimestamp"));
        vm.roll(vm.parseJsonUint(liquidationFixture, ".executionBlock"));
        assertFalse(pletherOracle.isOracleFrozen(), "October tick must execute through live signed pricing");
        assertFalse(engine.isFadWindow(), "liquidation must not depend on the weekend margin threshold");
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(TRADER, LIQUIDATION_PRICE);
        assertTrue(preview.liquidatable);
        assertEq(preview.pnlAssets, -int256(PRICE_LOSS_ASSETS));
        assertEq(preview.equityAssets, int256(beforeBuckets.pnlPledgeAssets - PRICE_LOSS_ASSETS - CARRY_ASSETS));
        assertGt(preview.equityAssets, 0);
        assertLt(preview.equityAssets, 1000e6, "authentic loss crosses ordinary maintenance");

        bytes[] memory data = _data(liquidationFixture);
        uint256 fee = pletherOracle.getUpdateFee(data);
        assertEq(fee, 0, "this pinned Pyth testnet deployment charges zero update fee");
        uint256 pythEthBefore = REAL_PYTH.balance;
        uint256 keeperEthBefore = KEEPER.balance;
        vm.expectCall(
            REAL_PYTH,
            fee,
            abi.encodeCall(
                IPyth.parsePriceFeedUpdates,
                (data, ids, uint64(vm.getBlockTimestamp() - 15), uint64(vm.getBlockTimestamp()))
            ),
            1
        );
        vm.expectEmit(true, false, false, true, address(engine));
        emit ICfdEngineTypes.CarryRealized(TRADER, CARRY_ASSETS, 0, CARRY_ASSETS, 0);
        vm.expectEmit(true, false, false, true, address(engine));
        emit ICfdEngineTypes.PositionLiquidated(
            TRADER, CfdTypes.Side.SHORT, POSITION_SIZE, LIQUIDATION_PRICE, KEEPER_BOUNTY_ASSETS
        );
        vm.prank(KEEPER);
        router.executeLiquidation{value: fee + ETH_SURPLUS}(TRADER, data);

        assertEq(REAL_PYTH.balance - pythEthBefore, fee, "one live parse receives the exact quoted Pyth fee");
        assertEq(keeperEthBefore - KEEPER.balance, fee, "the full overpayment is returned to the keeper");
        assertEq(address(pletherOracle).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(clearinghouse.balanceAssets(KEEPER) - keeperCreditBefore, KEEPER_BOUNTY_ASSETS);
        assertEq(settlementToken.balanceOf(KEEPER), keeperWalletBefore, "bounty is credited inside the clearinghouse");
        assertEq(
            clearinghouse.balanceAssets(PROTOCOL_TREASURY_ACCOUNT),
            treasuryCreditBefore,
            "zero liquidation treasury share preserves the opening execution fee already credited"
        );

        uint256 expectedPoolGain = PRICE_LOSS_ASSETS + CARRY_ASSETS + LIQUIDATION_CHARGE_ASSETS - KEEPER_BOUNTY_ASSETS;
        assertEq(settlementToken.balanceOf(address(pool)) - poolCashBefore, expectedPoolGain);
        assertEq(clearingCashBefore - settlementToken.balanceOf(address(clearinghouse)), expectedPoolGain);
        IMarginClearinghouse.PnlIsolationBuckets memory afterBuckets = clearinghouse.getPnlIsolationBuckets(TRADER);
        assertEq(afterBuckets.totalLockedAssets, 0, "all position reserves are released");
        assertEq(
            afterBuckets.settlementBalanceAssets,
            beforeBuckets.settlementBalanceAssets - PRICE_LOSS_ASSETS - CARRY_ASSETS - LIQUIDATION_CHARGE_ASSETS,
            "residual remains owned by the trader after price loss, accrued carry and liquidation charge"
        );
        assertEq(afterBuckets.freeSettlementAssets, afterBuckets.settlementBalanceAssets);
        assertEq(
            settlementToken.balanceOf(TRADER),
            traderWalletBefore,
            "liquidation does not move the trader's withdrawn cash"
        );
        (uint256 size, uint256 margin,,,,,) = engine.positions(TRADER);
        assertEq(size, 0);
        assertEq(margin, 0);
        assertEq(engine.positionEntryCostAssetAtoms(TRADER), 0);
        assertEq(engine.unsettledCarryAssets(TRADER), 0);
        (uint256 borrowBase, uint256 carryIndex, uint64 carryTime) = engine.positionCarryState(TRADER);
        assertEq(borrowBase, 0);
        assertEq(carryIndex, 0);
        assertEq(carryTime, 0);
        assertEq(engine.traderClaimBalanceAssets(TRADER), 0);
        ICfdEngineTypes.TerminalNavSnapshot memory nav = engine.terminalNavSnapshot();
        assertFalse(nav.hasOpenPositions);
        assertEq(nav.maxDirectionalLiabilityAssets, 0);
        assertFalse(engine.degradedMode());
        _assertTerminalCurveMatchesEngine(TRADER);
        _assertTerminalNavSnapshotMatchesBook();

        (bool accepted, uint256 mark, uint64 publishTime) = pletherOracle.getAcceptedBasketMark();
        assertTrue(accepted);
        assertEq(mark, LIQUIDATION_MARK);
        assertEq(publishTime, 1_790_970_892);
        assertEq(engine.lastMarkPrice(), LIQUIDATION_MARK, "engine caches the neutral signed mark");
        assertEq(engine.lastMarkTime(), publishTime);
        assertEq(
            abi.encode(pletherOracle.getAcceptedFeedPublishTimes()),
            abi.encode(vm.parseJsonUintArray(liquidationFixture, ".publishTimes"))
        );
        _assertStoredTimes(vm.parseJsonUintArray(openingFixture, ".publishTimes"));

        uint256 residual = afterBuckets.freeSettlementAssets;
        assertGt(residual, 0);
        vm.prank(TRADER);
        clearinghouse.withdraw(TRADER, residual);
        assertEq(
            settlementToken.balanceOf(TRADER) - traderWalletBefore,
            residual,
            "settled residual is actually withdrawable"
        );
        assertEq(clearinghouse.balanceAssets(TRADER), 0);
    }

    function _openSignedPosition() internal {
        vm.warp(vm.parseJsonUint(openingFixture, ".commitTimestamp"));
        OrderV3Types.OrderRequest memory request = OrderV3Types.OrderRequest({
            clientOrderId: keccak256("real-signed-liquidation-open"),
            side: CfdTypes.Side.SHORT,
            sizeDelta: POSITION_SIZE,
            marginDelta: 2000e6,
            targetPrice: CAP_PRICE,
            isClose: false,
            bounds: OrderV3Types.ExecutionBounds({
                submitBy: uint64(vm.getBlockTimestamp()),
                executionWindowSeconds: uint32(router.maxExecutionWindowSeconds()),
                allowedExecutionModes: 7,
                expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
                maxExecutionBountyAssets: type(uint256).max,
                maxExecutionNotionalAssets: type(uint256).max,
                maxGrossAccountDebitAssets: type(uint256).max,
                maxActionChargeAssets: type(uint256).max,
                maxExplicitFeesAssets: type(uint256).max,
                maxPostPositionSize: POSITION_SIZE,
                minPostSettlementBalanceAssets: 0,
                minPostPositionEquityAssets: 0,
                maxPostLeverageBps: type(uint32).max
            })
        });
        vm.prank(TRADER);
        uint64 id = OrderRouter(payable(address(router))).commitOrder(request);
        vm.warp(vm.parseJsonUint(openingFixture, ".executionTimestamp"));
        vm.roll(block.number + 1);
        bytes[] memory data = _data(openingFixture);
        uint256 fee = pletherOracle.getOrderExecutionFee(data);
        vm.recordLogs();
        vm.prank(KEEPER);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch{value: fee}(id, data);
        assertEq(result.terminalCount, 1);
        OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), id);
        assertEq(uint256(receipt.status), uint256(OrderV3Types.LifecycleStatus.Executed));
        assertEq(receipt.account, TRADER);
        assertEq(receipt.executionPrice, OPEN_PRICE);
        assertEq(receipt.oraclePublishTime, 1_790_091_398);
        (uint256 size,, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(TRADER);
        assertEq(size, POSITION_SIZE);
        assertEq(entryPrice, OPEN_PRICE);
        assertEq(uint256(side), uint256(CfdTypes.Side.SHORT));
        assertEq(engine.lastMarkPrice(), OPEN_MARK);
        _assertStoredTimes(vm.parseJsonUintArray(openingFixture, ".publishTimes"));
        uint256 freeCash = clearinghouse.getAccountAssetBuckets(TRADER).freeSettlementAssets;
        assertGt(freeCash, 7000e6);
        uint256 walletBefore = settlementToken.balanceOf(TRADER);
        vm.prank(TRADER);
        clearinghouse.withdraw(TRADER, freeCash);
        assertEq(settlementToken.balanceOf(TRADER) - walletBefore, freeCash);
        assertEq(clearinghouse.getAccountAssetBuckets(TRADER).freeSettlementAssets, 0);
    }

    function _stateDigest() internal view returns (bytes32) {
        (uint256 size, uint256 margin, uint256 entry, uint256 maxProfit, CfdTypes.Side side, uint64 time, int256 vpi) =
            engine.positions(TRADER);
        (bool accepted, uint256 mark, uint64 publishTime) = pletherOracle.getAcceptedBasketMark();
        (uint256 borrowBase, uint256 carryIndex, uint64 carryTime) = engine.positionCarryState(TRADER);
        return keccak256(
            abi.encode(
                size,
                margin,
                entry,
                maxProfit,
                side,
                time,
                vpi,
                borrowBase,
                carryIndex,
                carryTime,
                engine.unsettledCarryAssets(TRADER),
                engine.positionEntryCostAssetAtoms(TRADER),
                clearinghouse.getPnlIsolationBuckets(TRADER),
                clearinghouse.balanceAssets(KEEPER),
                engineProtocolLens.getProtocolAccountingSnapshot(),
                engine.terminalNavSnapshot(),
                accepted,
                mark,
                publishTime,
                pletherOracle.getAcceptedFeedPublishTimes(),
                settlementToken.balanceOf(address(pool)),
                settlementToken.balanceOf(address(clearinghouse)),
                REAL_PYTH.balance,
                KEEPER.balance,
                address(router).balance,
                address(pletherOracle).balance
            )
        );
    }

    function _data(
        string memory fixture
    ) internal view returns (bytes[] memory) {
        return abi.decode(vm.parseJson(fixture, ".updateData"), (bytes[]));
    }

    function _assertStoredTimes(
        uint256[] memory expected
    ) internal view {
        assertEq(expected.length, ids.length);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(IPyth(REAL_PYTH).getPriceUnsafe(ids[i]).publishTime, expected[i]);
        }
    }

    /// @dev Base keeps its legacy static type for old unit tests; this suite deploys the production router bytecode.
    function _deployLegacyOrderRouter(
        address engine_,
        address engineLens_,
        address pool_,
        address oracle_
    ) internal override returns (LegacyOrderRouterHarness deployedRouter) {
        policyEvaluator = new CfdOrderPolicyEvaluator();
        orderExecutionSidecar = new OrderRouterExecutionSidecar();
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, engine_, address(clearinghouse), pool_);
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        OrderRouter productionRouter = new OrderRouter(
            engine_,
            engineLens_,
            pool_,
            oracle_,
            address(keeperSidecar),
            address(policyEvaluator),
            address(orderExecutionSidecar),
            address(lifecycleBook)
        );
        assertEq(address(productionRouter), predictedRouter);
        deployedRouter = LegacyOrderRouterHarness(payable(address(productionRouter)));
    }

}
