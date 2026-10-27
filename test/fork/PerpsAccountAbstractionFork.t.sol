// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../packages/perps/test/perps/BasePerpTest.sol";
import {LegacyOrderRouterHarness} from "../../packages/perps/test/utils/LegacyOrderRouterHarness.sol";
import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEntryPointV08Compatibility, PletherVerifyingPaymaster} from "@plether/perps-aa/PletherVerifyingPaymaster.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {ArbitrumForkSupport} from "@plether/test-utils/ArbitrumForkSupport.sol";
import {Vm} from "forge-std/Vm.sol";

interface IPerpsForkAccountFactory {

    function createAccount(
        address owner,
        uint256 salt
    ) external returns (address);
    function getAddress(
        address owner,
        uint256 salt
    ) external view returns (address);

}

interface IPerpsForkAccount {

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }
    function owner() external view returns (address);
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external;
    function executeBatch(
        Call[] calldata calls
    ) external;

}

/// @notice Real deployed EntryPoint/SimpleAccount -> current paymaster and perps -> keeper settlement -> withdrawal.
/// @dev Pinned Arbitrum Sepolia AA bytecode, locally deployed production perps, MockSettlementToken/MockPyth, test-only ArbSys.
///      Every trader action is owner- and sponsor-signed and submitted through real handleOps. Pranks are confined
///      to the independent keeper and shared LP/bootstrap setup. Zero carry/VPI isolate cross-contract settlement;
///      oracle authenticity and carry are separate lanes.
contract PerpsAccountAbstractionForkTest is BasePerpTest {

    uint256 private constant SOURCE_RPC_BLOCK = 319_094_449;
    address private constant ENTRY_POINT = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    address private constant ACCOUNT_FACTORY = 0x13E9ed32155810FDbd067D4522C492D6f68E5944;
    address private constant ACCOUNT_IMPLEMENTATION = 0x28426d752372D68d34340bd94390950DcE3C9ec3;
    bytes32 private constant ACCOUNT_CODE_HASH = 0x41ee894da413cc99e8dec0a1784470eceb736845ad1591e06ff0ecdf0aca26c9;
    bytes32 private constant POLICY_ID = 0x8dd77324b94da492342191f762a32cdf99e828a7f24d77c8ed5ace90cf4f5ae3;
    bytes32 private constant USER_OPERATION_EVENT =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 private constant USER_OPERATION_REVERT_REASON =
        keccak256("UserOperationRevertReason(bytes32,address,uint256,bytes)");
    uint256 private constant OWNER_KEY = 0xA11CE4337;
    uint256 private constant SPONSOR_KEY = 0xB0B7677;
    uint256 private constant ACCOUNT_SALT = 0x5045525053414133;
    uint256 private constant DEPOSIT = 5000e6;
    uint256 private constant SIZE = 10_000e18;
    uint128 private constant MAX_FEE_PER_GAS = 10 gwei;
    uint128 private constant PAYMASTER_GAS_LIMIT = 100_000;
    uint128 private constant MAX_SPONSORED_COST = 0.05 ether;
    address private constant KEEPER = address(0xB0172);
    address payable private constant BENEFICIARY = payable(address(0xBEEF4337));

    IEntryPoint private entryPoint;
    PletherVerifyingPaymaster private paymaster;
    address private account;
    address private accountOwner;

    function setUp() public override {
        vm.createSelectFork(vm.envString("ARBITRUM_SEPOLIA_RPC_URL"), SOURCE_RPC_BLOCK);
        assertEq(block.chainid, 421_614);
        assertEq(ENTRY_POINT.codehash, 0xe3f30f78ae55058acdefea00952c8e44f2263215cf720fe1b27b6f148add0278);
        assertEq(ACCOUNT_FACTORY.codehash, 0xa2e635152a61e180383c7afc045620b7461ef6f43ba27d592262513106b991b7);
        assertEq(ACCOUNT_IMPLEMENTATION.codehash, 0x689a90eff03926a12aedad2fc6d4fdbcbdd9ffac86e7d0d70ce6355961305c74);
        ArbitrumForkSupport.install();
        super.setUp();

        entryPoint = IEntryPoint(ENTRY_POINT);
        paymaster = new PletherVerifyingPaymaster(
            entryPoint,
            address(this),
            vm.addr(SPONSOR_KEY),
            MAX_SPONSORED_COST,
            POLICY_ID,
            ACCOUNT_CODE_HASH,
            ACCOUNT_FACTORY,
            ACCOUNT_IMPLEMENTATION
        );
        paymaster.unpause();
        vm.deal(address(this), 1 ether);
        paymaster.deposit{value: 1 ether}();
        accountOwner = vm.addr(OWNER_KEY);
        account = IPerpsForkAccountFactory(ACCOUNT_FACTORY).getAddress(accountOwner, ACCOUNT_SALT);
        assertEq(account.code.length, 0, "account starts counterfactual");
        assertEq(accountOwner.balance, 0, "owner has no ETH to subsidize operations");
        assertEq(account.balance, 0);
        settlementToken.mint(account, DEPOSIT);
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 0;
        return params;
    }

    /// @dev Retain shared fixture wiring while deploying exact production Router, without the legacy test entrypoint.
    function _deployLegacyOrderRouter(
        address engine_,
        address lens_,
        address pool_,
        address oracle_
    ) internal override returns (LegacyOrderRouterHarness deployedRouter) {
        policyEvaluator = new CfdOrderPolicyEvaluator();
        orderExecutionSidecar = new OrderRouterExecutionSidecar();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook book = new OrderLifecycleBook(predicted, engine_, address(clearinghouse), pool_);
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predicted);
        OrderRouter productionRouter = new OrderRouter(
            engine_,
            lens_,
            pool_,
            oracle_,
            address(keeperSidecar),
            address(policyEvaluator),
            address(orderExecutionSidecar),
            address(book)
        );
        assertEq(address(productionRouter), predicted);
        deployedRouter = LegacyOrderRouterHarness(address(productionRouter));
    }

    function testFork_SponsoredPerpsLifecycleSettlesToTheSmartAccount() public {
        uint256 poolBefore = settlementToken.balanceOf(address(pool));
        OrderV3Types.OrderRequest memory opening = _request(false);
        _submit(_depositAndCommit(opening), true);
        assertEq(router.lifecycleBook().pendingIntent(1).account, account);
        assertEq(clearinghouse.balanceAssets(account), DEPOSIT);
        assertEq(clearinghouse.getOrderReservation(1).remainingAmountAssets, 2000e6);
        assertEq(settlementToken.balanceOf(account), 0);
        assertEq(router.pendingOrderCounts(accountOwner), 0);
        assertEq(clearinghouse.balanceAssets(accountOwner), 0);

        OrderV3Types.OrderReceipt memory opened = _execute(1, 120_000_000);
        assertEq(opened.account, account);
        assertEq(opened.economics.executionNotionalAssets, 12_000e6);
        assertEq(opened.economics.executionFeeAssets, 4_800_000);
        assertEq(opened.bounty.bountyPaidAssets, 200_000);
        assertEq(opened.economics.postPositionSize, SIZE);
        assertEq(clearinghouse.balanceAssets(account), 4995e6);
        _assertReservationsResolved(1);

        OrderV3Types.OrderRequest memory closing = _request(true);
        _submit(
            abi.encodeCall(
                IPerpsForkAccount.execute, (address(router), 0, abi.encodeCall(OrderRouter.commitOrder, (closing)))
            ),
            true
        );
        assertEq(router.lifecycleBook().pendingIntent(2).account, account);
        OrderV3Types.OrderReceipt memory closed = _execute(2, 110_000_000);
        assertEq(closed.account, account);
        assertEq(closed.economics.realizedPnlAssets, 1000e6, "10k tokens gain ten cents each");
        assertEq(closed.economics.executionFeeAssets, 4_400_000);
        assertEq(closed.bounty.bountyPaidAssets, 0);
        assertEq(closed.economics.postPositionSize, 0);
        assertEq(engine.traderClaimBalanceAssets(account), 0);
        _assertReservationsResolved(2);

        // 5,000 deposit + 1,000 profit - 4.80 open fee - 4.40 close fee - 0.20 open bounty.
        uint256 expectedPayout = 5_990_600_000;
        assertEq(clearinghouse.balanceAssets(account), expectedPayout);
        assertEq(settlementToken.balanceOf(address(pool)), poolBefore - 1000e6);
        assertEq(clearinghouse.balanceAssets(PROTOCOL_TREASURY_ACCOUNT), 9_200_000);
        assertEq(clearinghouse.balanceAssets(KEEPER), 200_000);

        _submit(
            abi.encodeCall(
                IPerpsForkAccount.execute,
                (address(clearinghouse), 0, abi.encodeCall(MarginClearinghouse.withdraw, (account, expectedPayout)))
            ),
            true
        );
        assertEq(entryPoint.getNonce(account, 0), 3);
        assertEq(
            settlementToken.balanceOf(account),
            expectedPayout,
            "settlement leaves the clearinghouse through the real account"
        );
        assertEq(settlementToken.balanceOf(accountOwner), 0, "signer never becomes the settlement recipient");
        assertEq(clearinghouse.balanceAssets(account), 0);
        assertEq(settlementToken.balanceOf(address(clearinghouse)), 9_400_000, "only treasury and keeper claims remain");
        assertEq(router.pendingOrderCounts(account), 0);
        (uint256 accountSize,,,,,,) = engine.positions(account);
        (uint256 ownerSize,,,,,,) = engine.positions(accountOwner);
        assertEq(accountSize, 0);
        assertEq(ownerSize, 0);
        assertEq(
            settlementToken.balanceOf(account) + settlementToken.balanceOf(address(pool))
                + settlementToken.balanceOf(address(clearinghouse)),
            poolBefore + DEPOSIT
        );
    }

    function testFork_InvalidPerpsCommitRollsBackDepositAndCanRetryWithNextNonce() public {
        OrderV3Types.OrderRequest memory invalid = _request(false);
        invalid.sizeDelta += 1;
        uint256 poolBefore = settlementToken.balanceOf(address(pool));
        Vm.Log[] memory logs = _submit(_depositAndCommit(invalid), false);
        _assertPerpsRevert(
            logs,
            abi.encodeWithSignature(
                "ExecuteError(uint256,bytes)",
                uint256(2),
                abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__InvalidSizeQuantum.selector)
            )
        );
        assertEq(entryPoint.getNonce(account, 0), 1, "failed account execution consumes the validated nonce");
        assertEq(settlementToken.balanceOf(account), DEPOSIT, "preceding token transfer rolled back");
        assertEq(settlementToken.allowance(account, address(clearinghouse)), 0, "preceding approval rolled back");
        assertEq(clearinghouse.balanceAssets(account), 0);
        assertEq(settlementToken.balanceOf(address(clearinghouse)), 0);
        assertEq(settlementToken.balanceOf(address(pool)), poolBefore);
        assertEq(router.nextCommitId(), 1);
        assertEq(router.pendingOrderCounts(account), 0);
        assertEq(clearinghouse.getAccountReservationSummary(account).activeCommittedOrderMarginAssets, 0);
        assertEq(clearinghouse.totalBountyReservationsAssets(account), 0);

        // The same deposit and valid order must work through EntryPoint, not an owner-prank shortcut.
        _submit(_depositAndCommit(_request(false)), true);
        assertEq(entryPoint.getNonce(account, 0), 2);
        OrderV3Types.OrderReceipt memory receipt = _execute(1, 120_000_000);
        assertEq(receipt.account, account);
        assertEq(receipt.economics.postPositionSize, SIZE);
        assertEq(clearinghouse.balanceAssets(account), 4995e6);
        _assertReservationsResolved(1);
    }

    function _request(
        bool close
    ) private view returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = keccak256(abi.encode("sponsored-perps-fork", account, router.nextCommitId()));
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = SIZE;
        request.marginDelta = close ? 0 : 2000e6;
        request.targetPrice = close ? 130_000_000 : 100_000_000;
        request.isClose = close;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: uint64(vm.getBlockTimestamp() + 60),
            executionWindowSeconds: 60,
            allowedExecutionModes: 1,
            expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyAssets: 200_000,
            maxExecutionNotionalAssets: 20_000e6,
            maxGrossAccountDebitAssets: 5000e6,
            maxActionChargeAssets: 20e6,
            maxExplicitFeesAssets: 20e6,
            maxPostPositionSize: SIZE,
            minPostSettlementBalanceAssets: 0,
            minPostPositionEquityAssets: 0,
            maxPostLeverageBps: 100_000
        });
    }

    function _depositAndCommit(
        OrderV3Types.OrderRequest memory request
    ) private view returns (bytes memory) {
        IPerpsForkAccount.Call[] memory calls = new IPerpsForkAccount.Call[](3);
        calls[0] = IPerpsForkAccount.Call(
            address(settlementToken), 0, abi.encodeCall(IERC20.approve, (address(clearinghouse), DEPOSIT))
        );
        calls[1] = IPerpsForkAccount.Call(
            address(clearinghouse), 0, abi.encodeCall(MarginClearinghouse.deposit, (account, DEPOSIT))
        );
        calls[2] = IPerpsForkAccount.Call(address(router), 0, abi.encodeCall(OrderRouter.commitOrder, (request)));
        return abi.encodeCall(IPerpsForkAccount.executeBatch, (calls));
    }

    function _execute(
        uint64 id,
        uint256 price
    ) private returns (OrderV3Types.OrderReceipt memory receipt) {
        // Cheatcode clocks must be read through Vm: Solidity may cache block.timestamp/number
        // across two executions inside the same test transaction.
        uint256 publishTime = vm.getBlockTimestamp() + 1;
        vm.warp(publishTime);
        vm.roll(vm.getBlockNumber() + 1);
        baseMockPyth.setAllUniquePrices(_basePythFeedIds(), int64(uint64(price)), 0, -8, publishTime, publishTime - 1);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(price);
        _startRecordingLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, data);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Executed));
        receipt = _verifiedReceipt(router.lifecycleBook(), id);
        assertEq(receipt.executor, KEEPER);
        assertEq(receipt.executionPrice, price);
    }

    function _assertReservationsResolved(
        uint64 id
    ) private view {
        IMarginClearinghouse.BountyReservation memory bounty =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        assertEq(uint8(bounty.state), uint8(IMarginClearinghouse.BountyReservationState.Settled));
        assertEq(bounty.amountAssets, 0);
        assertEq(clearinghouse.getOrderReservation(id).remainingAmountAssets, 0);
        assertEq(clearinghouse.getAccountReservationSummary(account).activeCommittedOrderMarginAssets, 0);
        assertEq(clearinghouse.totalBountyReservationsAssets(account), 0);
    }

    function _submit(
        bytes memory callData,
        bool expectedSuccess
    ) private returns (Vm.Log[] memory logs) {
        // Submit strictly inside the signed validity window; the deployed EntryPoint rejects its lower boundary.
        uint48 validAfter = uint48(vm.getBlockTimestamp() - 1);
        uint48 validUntil = validAfter + 120;
        PackedUserOperation memory op = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, 0),
            initCode: account.code.length == 0
                ? abi.encodePacked(
                    ACCOUNT_FACTORY,
                    abi.encodeCall(IPerpsForkAccountFactory.createAccount, (accountOwner, ACCOUNT_SALT))
                )
                : bytes(""),
            callData: callData,
            accountGasLimits: bytes32((uint256(450_000) << 128) | uint256(3_000_000)),
            preVerificationGas: 80_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(MAX_FEE_PER_GAS)),
            paymasterAndData: _envelope(validUntil, validAfter, new bytes(65)),
            signature: bytes("")
        });
        (uint8 sponsorV, bytes32 sponsorR, bytes32 sponsorS) = vm.sign(SPONSOR_KEY, paymaster.getSponsorshipHash(op));
        op.paymasterAndData = _envelope(validUntil, validAfter, abi.encodePacked(sponsorR, sponsorS, sponsorV));
        bytes32 opHash = IEntryPointV08Compatibility(ENTRY_POINT).getUserOpHash(op);
        (uint8 ownerV, bytes32 ownerR, bytes32 ownerS) = vm.sign(OWNER_KEY, opHash);
        op.signature = abi.encodePacked(ownerR, ownerS, ownerV);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        uint256 depositBefore = paymaster.getDeposit();
        uint256 beneficiaryBefore = BENEFICIARY.balance;
        vm.recordLogs();
        entryPoint.handleOps(ops, BENEFICIARY);
        logs = vm.getRecordedLogs();
        uint256 cost = _operationCost(logs, opHash, op.nonce, expectedSuccess);
        assertEq(depositBefore - paymaster.getDeposit(), cost, "real EntryPoint charges the sponsor");
        assertEq(BENEFICIARY.balance - beneficiaryBefore, cost);
        assertEq(entryPoint.getNonce(account, 0), op.nonce + 1);
        assertEq(account.codehash, ACCOUNT_CODE_HASH);
        assertEq(IPerpsForkAccount(account).owner(), accountOwner);
        assertEq(account.balance, 0, "smart account pays no ETH");
        assertEq(accountOwner.balance, 0, "signing owner pays no ETH");
    }

    function _envelope(
        uint48 until,
        uint48 after_,
        bytes memory signature
    ) private view returns (bytes memory) {
        return abi.encodePacked(
            address(paymaster),
            PAYMASTER_GAS_LIMIT,
            uint128(0),
            until,
            after_,
            MAX_SPONSORED_COST,
            POLICY_ID,
            ACCOUNT_CODE_HASH,
            signature
        );
    }

    function _operationCost(
        Vm.Log[] memory logs,
        bytes32 hash,
        uint256 nonce,
        bool expectedSuccess
    ) private view returns (uint256 cost) {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory item = logs[i];
            if (
                item.emitter == ENTRY_POINT && item.topics.length == 4 && item.topics[0] == USER_OPERATION_EVENT
                    && item.topics[1] == hash && item.topics[2] == bytes32(uint256(uint160(account)))
                    && item.topics[3] == bytes32(uint256(uint160(address(paymaster))))
            ) {
                (uint256 recordedNonce, bool success, uint256 gasCost, uint256 gasUsed) =
                    abi.decode(item.data, (uint256, bool, uint256, uint256));
                assertEq(recordedNonce, nonce);
                assertEq(success, expectedSuccess, "perps call outcome appears in the canonical AA receipt");
                assertGt(gasCost, 0);
                assertGt(gasUsed, 0);
                cost = gasCost;
                ++matches;
            }
        }
        assertEq(matches, 1, "exactly one canonical UserOperationEvent");
    }

    function _assertPerpsRevert(
        Vm.Log[] memory logs,
        bytes memory expected
    ) private view {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory item = logs[i];
            if (
                item.emitter == ENTRY_POINT && item.topics.length == 3 && item.topics[0] == USER_OPERATION_REVERT_REASON
                    && item.topics[2] == bytes32(uint256(uint160(account)))
            ) {
                (uint256 nonce, bytes memory reason) = abi.decode(item.data, (uint256, bytes));
                assertEq(nonce, 0);
                assertEq(reason, expected, "failure is the real perps validation at batch call 2");
                ++matches;
            }
        }
        assertEq(matches, 1);
    }

}
