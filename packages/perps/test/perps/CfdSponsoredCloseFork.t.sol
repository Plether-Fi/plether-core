// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {Test} from "forge-std/Test.sol";

interface ISponsoredSimpleAccount {

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }
    function owner() external view returns (address);
    function executeBatch(
        Call[] calldata calls
    ) external;

}

/// @dev Requires a real RPC fork; never sends a transaction to the public network.
contract CfdSponsoredCloseForkTest is Test {

    CfdEngine constant ENGINE = CfdEngine(address(bytes20(hex"afece93321be41aa73474457e2f47cf7b2fb738f")));
    OrderRouter constant ROUTER = OrderRouter(address(bytes20(hex"6215d36fcbd610ca1525252eebcbfd8b223a6072")));
    address constant ACCOUNT = address(bytes20(hex"8aff8f1a58934f31ed97b750dd4bd13478f893df"));
    address constant TOKEN = address(bytes20(hex"f7cbfcc74f2d9eb6fa7dc11941b3bef9fd7f8eb8"));
    address constant HOUSE = address(bytes20(hex"fa6e677ec1062757c1194d411a5e61e1e9644499"));
    CfdClosePreview lens;

    function setUp() public {
        string memory url = vm.envOr("SPONSORED_CLOSE_FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 421_614);
        assertEq(ACCOUNT.codehash, 0x41ee894da413cc99e8dec0a1784470eceb736845ad1591e06ff0ecdf0aca26c9);
        lens = new CfdClosePreview();
    }

    function _request(
        bool isPartial
    ) internal view returns (OrderV2Types.OrderRequest memory r) {
        (uint256 size,,,, CfdTypes.Side side,,) = ENGINE.positions(ACCOUNT);
        require(size > 0, "Fork fixture position no longer live");
        r.clientOrderId = keccak256(abi.encode("sponsored-fork", isPartial, block.number));
        r.side = side;
        r.sizeDelta = isPartial ? size / 2 / CfdTypes.SIZE_QUANTUM * CfdTypes.SIZE_QUANTUM : size;
        r.targetPrice = side == CfdTypes.Side.LONG ? type(uint256).max : 1;
        r.isClose = true;
        r.bounds.validUntil = uint64(block.timestamp + ROUTER.maxOrderAge());
        r.bounds.expectedConfigHash = ROUTER.lifecycleBook().currentExecutionConfigHash();
        r.bounds.allowedExecutionModes = 1;
        r.bounds.maxExecutionBountyUsdc = 200_000;
        r.bounds.maxExecutionNotionalUsdc = type(uint256).max;
        r.bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        r.bounds.maxActionChargeUsdc = type(uint256).max;
        r.bounds.maxExplicitFeesUsdc = type(uint256).max;
        r.bounds.maxPostPositionSize = type(uint256).max;
        r.bounds.maxPostLeverageBps = type(uint32).max;
    }

    function _calls(
        OrderV2Types.OrderRequest memory r,
        uint256 amount
    ) internal view returns (ISponsoredSimpleAccount.Call[] memory c) {
        c = new ISponsoredSimpleAccount.Call[](5);
        c[0] = ISponsoredSimpleAccount.Call(
            address(lens), 0, abi.encodeCall(CfdClosePreview.validateSponsoredClose, (address(ENGINE), r, amount))
        );
        c[1] = ISponsoredSimpleAccount.Call(TOKEN, 0, abi.encodeWithSignature("mint(address,uint256)", ACCOUNT, amount));
        c[2] = ISponsoredSimpleAccount.Call(TOKEN, 0, abi.encodeCall(IERC20.approve, (HOUSE, amount)));
        c[3] = ISponsoredSimpleAccount.Call(HOUSE, 0, abi.encodeWithSignature("depositMargin(uint256)", amount));
        c[4] = ISponsoredSimpleAccount.Call(address(ROUTER), 0, abi.encodeCall(OrderRouter.commitOrder, (r)));
    }

    function _commit(
        bool isPartial
    ) internal {
        OrderV2Types.OrderRequest memory r = _request(isPartial);
        uint256 free = IMarginClearinghouse(HOUSE).getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc;
        require(free < 200_000, "Fork fixture no longer needs assistance");
        uint256 amount = 200_000 - free;
        uint256 price = ENGINE.lastMarkPrice();
        if (isPartial) {
            price = r.side == CfdTypes.Side.LONG ? price - price / 10 : price + price / 10;
        }
        CfdClosePreview.SponsoredClosePreview memory preview =
            lens.previewSponsoredClose(address(ENGINE), ACCOUNT, r, address(ROUTER), price, uint64(block.timestamp));
        assertEq(preview.subsidyUsdc, amount);
        address owner = ISponsoredSimpleAccount(ACCOUNT).owner();
        vm.prank(owner);
        ISponsoredSimpleAccount(ACCOUNT).executeBatch(_calls(r, amount));
        assertGt(ROUTER.lifecycleBook().clientIntent(ACCOUNT, r.clientOrderId).orderId, 0);
        CfdTypes.Order memory order = CfdTypes.Order(
            ACCOUNT, r.sizeDelta, 0, r.targetPrice, uint64(block.timestamp), uint64(block.number), 0, r.side, true
        );
        OrderV2Types.ExecutionAssessment memory actual = ICfdOrderPolicyEvaluator(
                address(bytes20(hex"43c93d3028fcd4c1f578a50639750b8fbfdee799"))
            )
            .assessOrder(
                address(ENGINE),
                order,
                address(ROUTER),
                price,
                IHousePool(ENGINE.pool()).totalAssets(),
                uint64(block.timestamp),
                r.bounds,
                200_000
            );
        assertEq(
            keccak256(abi.encode(actual)),
            keccak256(abi.encode(preview.assessment)),
            "funded preview equals deployed commitment assessment"
        );
        uint256 supply = IERC20(TOKEN).totalSupply();
        vm.expectRevert(
            abi.encodeWithSignature(
                "ExecuteError(uint256,bytes)",
                0,
                abi.encodeWithSelector(CfdClosePreview.CfdClosePreview__SponsoredIntentInvalid.selector)
            )
        );
        vm.prank(owner);
        ISponsoredSimpleAccount(ACCOUNT).executeBatch(_calls(r, amount));
        assertEq(IERC20(TOKEN).totalSupply(), supply);
    }

    function testFork_DeployedAccountFullCloseCommitAndReplay() public {
        _commit(false);
    }

    function testFork_DeployedAccountPartialCloseCommitAndReplay() public {
        _commit(true);
    }

    function testFork_DeployedAccountRollsBackMintOnCommitFailure() public {
        OrderV2Types.OrderRequest memory r = _request(false);
        uint256 free = IMarginClearinghouse(HOUSE).getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc;
        uint256 supply = IERC20(TOKEN).totalSupply();
        vm.mockCallRevert(
            address(ROUTER),
            abi.encodeCall(OrderRouter.commitOrder, (r)),
            abi.encodeWithSignature("Error(string)", "commit failed")
        );
        address owner = ISponsoredSimpleAccount(ACCOUNT).owner();
        vm.expectRevert();
        vm.prank(owner);
        ISponsoredSimpleAccount(ACCOUNT).executeBatch(_calls(r, 200_000 - free));
        assertEq(IERC20(TOKEN).totalSupply(), supply);
        assertEq(IMarginClearinghouse(HOUSE).getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, free);
    }

}
