// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";

import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";

import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {Test} from "forge-std/Test.sol";

import {VpiMockUSDC6} from "../../shared/CfdEngineTestBase.sol";

contract VpiChunkingTest is Test {

    VpiMockUSDC6 usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    uint256 constant DEPTH = 5_000_000 * 1e6;

    function getAccountReservations(
        address
    ) external pure returns (IOrderRouterAccounting.AccountReservationView memory reservation) {
        return reservation;
    }

    function _configureBroadSeniorCapacity() internal {
        IHousePool.PoolConfig memory config = IHousePool.PoolConfig({
            seniorRateBps: pool.seniorRateBps(),
            markStalenessLimit: pool.markStalenessLimit(),
            seniorFrozenLpFeeBps: pool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: pool.juniorFrozenLpFeeBps(),
            maxSeniorExposureUsdc: type(uint256).max - 1,
            maxSeniorShareBps: 9999
        });
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        pool.finalizePoolConfig();
    }

    function setUp() public {
        usdc = new VpiMockUSDC6();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
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

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 50);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        TerminalNavBookV2 terminalBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));
        TrancheVault seniorVault =
            new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "seniorUSDC", 0, address(0));
        juniorVault =
            new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC", 0, address(0));
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.setEngine(address(engine));
        _configureBroadSeniorCapacity();
        vm.warp(1_709_532_000);

        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        usdc.mint(address(this), 10_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        uint256 requestId = juniorVault.requestDeposit(5_000_000 * 1e6, address(this), address(this));
        vm.warp(pool.lpEpochStart(requestId));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.settleLpEpoch(0, 0);
        uint256 claimableAssets = juniorVault.claimableDepositRequest(requestId, address(this));
        juniorVault.claimDeposit(requestId, claimableAssets, address(this), address(this));
    }

    function _deposit(
        address account,
        uint256 amount
    ) internal {
        address user = account;
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();
    }

    function _open(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
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

    function getMarginReservationIds(
        address
    ) external pure returns (uint64[] memory) {
        return new uint64[](0);
    }

    function syncMarginQueue(
        address
    ) external pure {}

    function _close(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrderTyped(
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
            depth,
            uint64(block.timestamp)
        );
    }

    // round-trip skew healing must not create net positive VPI without price movement.
    function test_MM_RoundTripSkewHealing_DoesNotCreatePositiveNetRebate() public {
        address shortSkewerAccount = address(0x51);
        _deposit(shortSkewerAccount, 500_000 * 1e6);
        _open(shortSkewerAccount, CfdTypes.Side.SHORT, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        address mmAccount = address(0x111);
        _deposit(mmAccount, 500_000 * 1e6);
        _open(mmAccount, CfdTypes.Side.LONG, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        (,,,,,, int256 vpiAfterOpen) = engine.positions(mmAccount);
        assertLe(vpiAfterOpen, 0, "MM should not pay positive VPI when healing skew on open");

        address longFlipperAccount = address(0x52);
        _deposit(longFlipperAccount, 500_000 * 1e6);
        _open(longFlipperAccount, CfdTypes.Side.LONG, 1_000_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        (uint256 mmSize,,,,,,) = engine.positions(mmAccount);
        _close(mmAccount, CfdTypes.Side.LONG, mmSize, 1e8, DEPTH);
        uint256 mmUsdcAfter = clearinghouse.balanceUsdc(mmAccount);

        uint256 totalDeposited = 500_000 * 1e6;
        uint256 approxExecFees = (500_000 * 1e6 * 4 / 10_000) * 2;
        uint256 breakeven = totalDeposited - approxExecFees;

        assertLe(
            mmUsdcAfter,
            breakeven,
            "Round-trip skew healing should not create positive net VPI beyond the trader's fee-adjusted breakeven"
        );
    }

    // linear VPI chunking bounded error
    function test_PartialClose_LinearChunking_BoundedError() public {
        address skewerAccount = address(0x52);
        _deposit(skewerAccount, 500_000 * 1e6);
        _open(skewerAccount, CfdTypes.Side.SHORT, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        address aliceAccount = address(0xA1);
        _deposit(aliceAccount, 500_000 * 1e6);
        _open(aliceAccount, CfdTypes.Side.LONG, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 aliceBefore = clearinghouse.balanceUsdc(aliceAccount);
        _close(aliceAccount, CfdTypes.Side.LONG, 400_000 * 1e18, 1e8, DEPTH);
        uint256 aliceAfter = clearinghouse.balanceUsdc(aliceAccount);
        int256 aliceNet = int256(aliceAfter) - int256(aliceBefore);

        _close(skewerAccount, CfdTypes.Side.SHORT, 500_000 * 1e18, 1e8, DEPTH);
        _open(skewerAccount, CfdTypes.Side.SHORT, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        address bobAccount = address(0xB1);
        _deposit(bobAccount, 500_000 * 1e6);
        _open(bobAccount, CfdTypes.Side.LONG, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 bobBefore = clearinghouse.balanceUsdc(bobAccount);
        _close(bobAccount, CfdTypes.Side.LONG, 200_000 * 1e18, 1e8, DEPTH);
        _close(bobAccount, CfdTypes.Side.LONG, 200_000 * 1e18, 1e8, DEPTH);
        uint256 bobAfter = clearinghouse.balanceUsdc(bobAccount);
        int256 bobNet = int256(bobAfter) - int256(bobBefore);

        int256 diff = aliceNet > bobNet ? aliceNet - bobNet : bobNet - aliceNet;
        uint256 tolerance = 5 * 1e6;

        assertLe(uint256(diff), tolerance, "Linear chunking error must stay within bounded tolerance");
    }

}
