// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;
import {ILegacyCloseRouter, LegacyCloseTypes} from "../fixtures/LegacyCloseV2.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Original deployed-bytecode regressions. No state overrides, candidate substitution, or broadcast.
contract HistoricalCloseRegressionTest is Test {

    CfdEngine constant ENGINE = CfdEngine(address(bytes20(hex"afece93321be41aa73474457e2f47cf7b2fb738f")));
    OrderRouter constant ROUTER = OrderRouter(address(bytes20(hex"6215d36fcbd610ca1525252eebcbfd8b223a6072")));
    IMarginClearinghouse constant HOUSE =
        IMarginClearinghouse(address(bytes20(hex"fa6e677ec1062757c1194d411a5e61e1e9644499")));
    CfdEngineLens constant LENS = CfdEngineLens(address(bytes20(hex"8fe702213241482d6e94327f9e70195ad183d1ad")));

    function _fork(
        uint256 height
    ) private {
        string memory url = vm.envOr("CLOSE_REGRESSION_ARCHIVE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, height);
        assertEq(block.chainid, 421_614);
        // Hashes from the committed v1.2.3 release manifest, not candidate compiler templates.
        assertEq(address(ENGINE).codehash, 0xa4ef32f28b3910d745635f4d505e598f800ce88458b5cf782a71fb2d1e196531);
        assertEq(address(HOUSE).codehash, 0xa1f76d1de6089acb98609339e71c6377df4b43c66b6a04dcc17e0b3aa2070fa0);
        assertEq(address(ROUTER).codehash, 0x83d90e23e637a5b8bde65cecbec864b66ea2dbfaa685917bbd4bcd8c1b292fcc);
        assertEq(address(ENGINE.planner()).codehash, 0xb8e4c5bc9333062b739c958b993fadfee3f4fc7e455e6f10d8a65b44a646fa09);
        assertEq(address(LENS).codehash, 0x59db0a0c2fbd9e189b8e3a40635cb397583378db26602ff9428bc709780beddd);
    }

    function _checkHistoricalLayout(
        address account
    ) private view {
        // From LegacyCloseV2.storage-layout.json, compiled from the pinned v1.2.3 source and OZ dependency.
        uint256 positionWord = uint256(vm.load(address(ENGINE), keccak256(abi.encode(account, uint256(35)))));
        (uint256 size, uint256 margin,,,,,) = ENGINE.positions(account);
        assertEq(uint256(uint112(positionWord)) * CfdTypes.SIZE_QUANTUM, size);
        assertEq(positionWord >> 112, ENGINE.positionEntryCostUsdcAtoms(account));
        assertEq(
            uint256(vm.load(address(HOUSE), keccak256(abi.encode(account, uint256(2))))), HOUSE.balanceUsdc(account)
        );
        assertEq(uint256(vm.load(address(HOUSE), keccak256(abi.encode(account, uint256(3))))), margin);
    }

    function testFork_Block309041940_InsufficientFreeBounty() public {
        _fork(309_041_940);
        address account = address(bytes20(hex"8aff8f1a58934f31ed97b750dd4bd13478f893df"));
        _checkHistoricalLayout(account);
        assertEq(HOUSE.getAccountUsdcBuckets(account).freeSettlementUsdc, 2000);
        (uint256 size,,,, CfdTypes.Side side,,) = ENGINE.positions(account);
        assertEq(size, 15_725_600e18);
        LegacyCloseTypes.OrderRequest memory request;
        request.clientOrderId = keccak256("historical-free-bounty-failure");
        request.side = side;
        request.sizeDelta = size;
        request.isClose = true;
        request.targetPrice = side == CfdTypes.Side.LONG ? type(uint256).max : 1;
        request.bounds.validUntil = uint64(block.timestamp + ROUTER.maxOrderAge());
        request.bounds.expectedConfigHash = ROUTER.lifecycleBook().currentExecutionConfigHash();
        request.bounds.allowedExecutionModes = 7;
        request.bounds.maxExecutionBountyUsdc = type(uint256).max;
        request.bounds.maxExecutionNotionalUsdc = type(uint256).max;
        request.bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        request.bounds.maxActionChargeUsdc = type(uint256).max;
        request.bounds.maxExplicitFeesUsdc = type(uint256).max;
        request.bounds.maxPostPositionSize = type(uint256).max;
        request.bounds.maxPostLeverageBps = type(uint32).max;
        vm.expectPartialRevert(ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        vm.prank(account);
        ILegacyCloseRouter(address(ROUTER)).commitOrder(request);
    }

    function testFork_Block309758933_ZeroFreeReductionRejected() public {
        _fork(309_758_933);
        address account = address(bytes20(hex"c220fef1493f4b94deed0eacbda4e08c5989ea2f"));
        _checkHistoricalLayout(account);
        assertEq(HOUSE.getAccountUsdcBuckets(account).freeSettlementUsdc, 0);
        (uint256 size, uint256 margin,,,,,) = ENGINE.positions(account);
        assertEq(size, 42_326_500e18);
        assertEq(margin, 138_534_490_401);
        ICfdEngineTypes.ClosePreview memory preview = LENS.previewClose(account, 10_000e18, 98_182_413);
        assertFalse(preview.valid);
        assertEq(uint8(preview.invalidReason), 3);
    }

}
