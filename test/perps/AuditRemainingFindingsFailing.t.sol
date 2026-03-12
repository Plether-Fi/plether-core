// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AuditRemainingFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);

    function test_H1_UserCanAddMarginWithoutChangingSize() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 5_000e6, 1e8);

        (, uint256 marginBefore,,,,,,) = engine.positions(accountId);
        vm.prank(alice);
        engine.addMargin(accountId, 500e6);

        (, uint256 margin,,,,,,) = engine.positions(accountId);
        assertEq(margin, marginBefore + 500e6, "User should be able to add margin without changing size");
    }

    function test_M1_ExecutionFeesAreProtocolRevenue() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);

        uint256 equityBefore = pool.seniorPrincipal() + pool.juniorPrincipal();

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 1e8);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 equityAfter = pool.seniorPrincipal() + pool.juniorPrincipal();
        assertEq(equityAfter, equityBefore, "Execution fees should not increase LP equity");
        assertEq(engine.accumulatedFeesUsdc(), 120e6, "Execution fees should accrue to protocol fees");
    }

}

contract AuditRemainingFindingsFailing_MevDrift is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _fundJunior(address(this), _initialJuniorDeposit());
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    function test_H2_CrossBlockPublishAfterCommitMustRevert() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1001);

        vm.warp(1001);
        bytes[] memory empty;

        vm.expectRevert();
        router.executeOrder(1, empty);
    }

}
