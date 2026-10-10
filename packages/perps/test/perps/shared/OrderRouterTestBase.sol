// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";

import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";

import {IPyth, PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

abstract contract OrderRouterTestBase is BasePerpTest {

    using stdStorage for StdStorage;

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();

        uint256 seedAmount = 1000e6;
        usdc.mint(address(this), seedAmount * 2);
        usdc.approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();

        _fundJunior(bob, 1_000_000 * 1e6);

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(alice, 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();
    }

    function _maxRequestableJuniorAssets(
        address owner
    ) internal view returns (uint256 assets) {
        uint256 ownerShares = juniorVault.maxRequestRedeem(owner);
        uint256 ownerAssets = juniorVault.estimateRedeemAssets(ownerShares);
        (,,, uint256 maxJuniorWithdrawUsdc) = pool.getPendingTrancheState();
        assets = ownerAssets < maxJuniorWithdrawUsdc ? ownerAssets : maxJuniorWithdrawUsdc;
    }

    function _settleJuniorWithdrawal(
        address owner,
        uint256 assets
    ) internal returns (uint256 claimedAssets) {
        uint256 shares = juniorVault.estimateWithdrawShares(assets);
        vm.prank(owner);
        uint256 requestId = juniorVault.requestRedeem(shares, owner, owner);

        vm.warp(pool.lpEpochStart(requestId));
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
        pool.settleLpEpoch(0, 0);

        uint256 claimableShares = juniorVault.claimableRedeemRequest(requestId, owner);
        vm.prank(owner);
        claimedAssets = juniorVault.claimRedeem(requestId, claimableShares, owner, owner);
    }

}

abstract contract OrderRouterPythTestBase is BasePerpTest {

    using stdStorage for StdStorage;

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _fundSetupJuniorWithoutMarkUpdate(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        uint256 requestId = juniorVault.requestDeposit(amount, lp, lp);
        vm.stopPrank();

        vm.warp(pool.lpEpochStart(requestId));
        _settleLpEpochForTest();

        uint256 claimableAssets = juniorVault.claimableDepositRequest(requestId, lp);
        vm.prank(lp);
        juniorVault.claimDeposit(requestId, claimableAssets, lp, lp);
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();
        mockPyth.setSynchronizeLegacyUniquePrices(true);

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        engine.setTerminalNavBook(address(new TerminalNavBookV2(address(engine), uint32(engine.CAP_PRICE()))));
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

        engineLens = new CfdEngineLens(address(engine));
        pletherOracle = new PletherOracle(
            address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        router = _deployLegacyOrderRouter(address(engine), address(engineLens), address(pool), address(pletherOracle));
        _syncRouterAdmin();
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();

        uint256 seedAmount = 1000e6;
        usdc.mint(address(this), seedAmount * 2);
        usdc.approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();

        _fundSetupJuniorWithoutMarkUpdate(bob, 1_000_000 * 1e6);

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(alice, 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();

        vm.warp(1);
    }

    function _forcePnlPledgeForMarginDrain(
        address account,
        uint256 nextPledgeUsdc
    ) internal {
        // These tests model a protocol-authorized post-commit margin mutation. Keep the V2 terminal commitment in
        // lockstep with the deliberately forced clearinghouse state so the fixture does not model torn accounting.
        stdstore.target(address(clearinghouse)).sig("pnlPledgeUsdc(address)").with_key(account)
            .checked_write(nextPledgeUsdc);

        ITerminalNavBookV2 book = engine.terminalNavBook();
        (uint256 size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "margin-drain fixture requires a live position");

        bytes32 oldCurveHash = book.curveHashOf(account);
        vm.prank(address(engine));
        book.syncFromEngine(account, oldCurveHash);
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    function _setDegradedModeForTest() internal {
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
    }

    function _assertAboveCapPreviewPolicy(
        address healingShortTrader,
        address crossingShortTrader,
        uint256 healingSize
    ) internal {
        CfdEngineLens previewLens = new CfdEngineLens(address(engine));
        ICfdEngineTypes.OpenPreview memory preview = previewLens.previewOpen(
            crossingShortTrader, CfdTypes.Side.SHORT, 580_000e18, 20_000e6, 1e8, uint64(block.timestamp)
        );
        assertTrue(preview.valid, "Crossing balance may end exactly at the cap");

        preview = previewLens.previewOpen(
            crossingShortTrader, CfdTypes.Side.SHORT, 590_000e18, 20_000e6, 1e8, uint64(block.timestamp)
        );
        assertFalse(
            preview.valid,
            "A smaller absolute skew must still be rejected after crossing into a new above-cap imbalance"
        );
        assertEq(
            uint8(preview.invalidReason),
            uint8(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH),
            "The order-side cap should reject an above-cap crossing overshoot"
        );

        preview = previewLens.previewOpen(
            crossingShortTrader, CfdTypes.Side.SHORT, 600_000e18, 20_000e6, 1e8, uint64(block.timestamp)
        );
        assertFalse(preview.valid, "An above-cap order with unchanged absolute skew should remain invalid");
        assertEq(
            uint8(preview.invalidReason),
            uint8(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH),
            "The strict reduction boundary should reject equal absolute skew"
        );

        preview = previewLens.previewOpen(
            healingShortTrader, CfdTypes.Side.SHORT, healingSize, 1000e6, 1e8, uint64(block.timestamp)
        );
        assertTrue(preview.valid, "Preview should admit an incremental skew reduction above the cap");
    }

}

contract BasketPriceHarness {

    IPyth internal localPyth;
    bytes32[] internal localPythFeedIds;
    uint256[] internal localQuantities;
    uint256[] internal localBasePrices;
    bool[] internal localInversions;

    constructor(
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    ) {
        if (
            _feedIds.length == 0 || _feedIds.length != _quantities.length || _feedIds.length != _basePrices.length
                || _feedIds.length != _inversions.length
        ) {
            revert IPletherOracle.PletherOracle__ArrayLengthMismatch(
                _feedIds.length, _quantities.length, _basePrices.length, _inversions.length
            );
        }
        localPyth = IPyth(_pyth);
        localPythFeedIds = _feedIds;
        localQuantities = _quantities;
        localBasePrices = _basePrices;
        localInversions = _inversions;
    }

    function computeBasketPrice(
        uint256 maxStaleness,
        uint256 maxPublishTimeDivergence
    ) external view returns (uint256, uint256) {
        uint256 minPublishTime = type(uint256).max;
        uint256 maxPublishTime;
        uint256 basketPrice;

        for (uint256 i = 0; i < localPythFeedIds.length; i++) {
            PythStructs.Price memory p = localPyth.getPriceUnsafe(localPythFeedIds[i]);
            if (p.publishTime > block.timestamp || block.timestamp - p.publishTime > maxStaleness) {
                revert IPletherOracle.PletherOracle__StalePrice(
                    IPletherOracle.PriceMode.OrderExecution,
                    localPythFeedIds[i],
                    p.publishTime,
                    maxStaleness,
                    block.timestamp
                );
            }

            uint256 norm =
                localInversions[i] ? _localInvertPythPrice(p.price, p.expo) : _localNormalizePythPrice(p.price, p.expo);
            basketPrice += (norm * localQuantities[i])
                / (localBasePrices[i] * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE);

            if (p.publishTime < minPublishTime) {
                minPublishTime = p.publishTime;
            }
            if (p.publishTime > maxPublishTime) {
                maxPublishTime = p.publishTime;
            }
        }

        if (maxPublishTime > minPublishTime + maxPublishTimeDivergence) {
            revert IPletherOracle.PletherOracle__PublishTimeDivergence(
                IPletherOracle.PriceMode.OrderExecution, minPublishTime, maxPublishTime, maxPublishTimeDivergence
            );
        }
        if (basketPrice == 0) {
            revert IPletherOracle.PletherOracle__ZeroBasketPrice();
        }

        return (basketPrice, minPublishTime);
    }

    function _localInvertPythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256 normalizedPrice) {
        if (price <= 0) {
            revert IPletherOracle.PletherOracle__InvalidPrice(bytes32(0), price);
        }
        uint256 positivePrice = uint256(uint64(price));
        uint256 scaledPrecision = 10 ** uint256(uint32(26 - expo));
        uint256 scaledInverse = (scaledPrecision + (positivePrice / 2)) / positivePrice;
        return scaledInverse / 1e18;
    }

    function _localNormalizePythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256 normalizedPrice) {
        if (price <= 0) {
            revert IPletherOracle.PletherOracle__InvalidPrice(bytes32(0), price);
        }

        uint256 rawPrice = uint256(uint64(price));
        if (expo == -8) {
            return rawPrice;
        }
        if (expo > -8) {
            return rawPrice * (10 ** uint256(uint32(expo + 8)));
        }
        return rawPrice / (10 ** uint256(uint32(-8 - expo)));
    }

}

contract NormalizePythHarness {

    function normalizePythPrice(
        int64 price,
        int32 expo
    ) external pure returns (uint256) {
        if (price <= 0) {
            revert IPletherOracle.PletherOracle__InvalidPrice(bytes32(0), price);
        }

        uint256 rawPrice = uint256(uint64(price));
        if (expo == -8) {
            return rawPrice;
        }
        if (expo > -8) {
            return rawPrice * (10 ** uint256(uint32(expo + 8)));
        }
        return rawPrice / (10 ** uint256(uint32(-8 - expo)));
    }

}
