// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "../../src/perps/OrderRouterAdmin.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RejectingRefundReceiver {

    bool internal acceptEth;

    receive() external payable {
        if (!acceptEth) {
            revert();
        }
    }

    function setAcceptEth(
        bool acceptEth_
    ) external {
        acceptEth = acceptEth_;
    }

    function refreshMark(
        OrderRouter router,
        bytes[] calldata updateData
    ) external payable {
        router.updateMarkPrice{value: msg.value}(updateData);
    }

}

contract AuditExecutionPathFindingsFailing_EthRefundFallback is BasePerpTest {

    MockPyth internal mockPyth;
    RejectingRefundReceiver internal refundReceiver;

    bytes32 internal constant FEED_A = bytes32(uint256(1));
    bytes32 internal constant FEED_B = bytes32(uint256(2));

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        mockPyth = new MockPyth();

        bytes32[] memory feedIds = new bytes32[](2);
        uint256[] memory weights = new uint256[](2);
        uint256[] memory bases = new uint256[](2);
        bool[] memory inversions = new bool[](2);

        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        bases[0] = 1e8;
        bases[1] = 1e8;

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            inversions
        );
        _syncRouterAdmin();
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();

        refundReceiver = new RejectingRefundReceiver();
        vm.deal(address(refundReceiver), 1 ether);
    }

    function test_H1_FallbackRefundMustFundRouterAdminClaimBalance() public {
        uint256 publishTime = block.timestamp;
        uint256 pythFee = 0.01 ether;
        uint256 overpay = 0.05 ether;

        mockPyth.setFee(pythFee);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), publishTime);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), publishTime);

        refundReceiver.setAcceptEth(false);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";

        refundReceiver.refreshMark{value: pythFee + overpay}(router, updateData);

        assertEq(routerAdmin.claimableEth(address(refundReceiver)), overpay, "failed refund should become claimable");
        assertEq(
            address(routerAdmin).balance,
            overpay,
            "fallback accounting must move the stranded ETH into OrderRouterAdmin"
        );
    }

}

contract AuditExecutionPathFindingsFailing_CommitPrefilterFeeParity is BasePerpTest {

    function test_H2_CommitPrefilterMustRejectFeeDrainedOpen() public {
        address trader = address(0xE113);
        address account = trader;
        uint256 sizeDelta = 100_000e18;
        uint256 marginDelta = 1500e6;

        _fundTrader(trader, 2000e6);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );

        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "preview should include executionFeeBps when checking exact-threshold initial margin"
        );
        assertEq(
            uint256(failureCategory),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable),
            "execution-fee invalid opens should be blocked at commit time"
        );

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderRouter.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN)
            )
        );
        router.commitOrder(CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8, false);
    }

}
