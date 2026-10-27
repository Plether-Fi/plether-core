// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../shared/SourceBoundBountyFixture.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

interface INativeSimpleFactory {

    function createAccount(
        address owner,
        uint256 salt
    ) external returns (address);

}

interface INativeSimpleAccount {

    function owner() external view returns (address);
    function execute(
        address dest,
        uint256 value,
        bytes calldata data
    ) external;

}

/// @dev Real pinned SimpleAccount v0.8 code, fresh local perps stack, MockSettlementToken and MockPyth.
/// No public-chain transaction, UserOperation, EntryPoint, paymaster, bundler or protocol API is used.
contract NativeCloseFallbackTest is SourceBoundBountyFixture {

    address constant FACTORY = 0x13E9ed32155810FDbd067D4522C492D6f68E5944;
    address constant IMPLEMENTATION = 0x28426d752372D68d34340bd94390950DcE3C9ec3;
    address constant OWNER = address(0xA11CE);
    uint256 constant SOURCE_RPC_BLOCK = 319_094_449;
    INativeSimpleAccount private account;

    function setUp() public override {
        string memory rpc = vm.envString("NATIVE_CLOSE_FORK_RPC_URL");
        vm.createSelectFork(rpc, SOURCE_RPC_BLOCK);
        assertEq(block.chainid, 421_614);
        emit log_named_uint("SimpleAccount source fork RPC block", SOURCE_RPC_BLOCK);
        assertEq(FACTORY.codehash, 0xa2e635152a61e180383c7afc045620b7461ef6f43ba27d592262513106b991b7);
        assertEq(IMPLEMENTATION.codehash, 0x689a90eff03926a12aedad2fc6d4fdbcbdd9ffac86e7d0d70ce6355961305c74);
        // Account creation is fixture setup through the real factory's EntryPoint SenderCreator.
        // The exercised outage paths below require only the existing account's owner.
        vm.prank(0x449ED7C3e6Fee6a97311d4b55475DF59C44AdD33);
        account = INativeSimpleAccount(INativeSimpleFactory(FACTORY).createAccount(OWNER, 114));
        assertEq(address(account).codehash, 0x41ee894da413cc99e8dec0a1784470eceb736845ad1591e06ff0ecdf0aca26c9);
        assertEq(account.owner(), OWNER);
        super.setUp();
        _fundTrader(address(account), 1000e6);
        _ownerCommit(false, BOUNTY_SIZE, 250e6);
        _bountyExecute(1, BOUNTY_PRICE, OWNER, OrderV3Types.LifecycleStatus.Executed);
        uint256 free = clearinghouse.getFreeBuyingPowerAssets(address(account));
        vm.prank(OWNER);
        account.execute(
            address(clearinghouse), 0, abi.encodeWithSignature("withdraw(address,uint256)", address(account), free)
        );
        // Withdrawn wallet cash is not needed for either commitment or execution.
        settlementToken.burn(address(account), settlementToken.balanceOf(address(account)));
        assertEq(clearinghouse.getFreeBuyingPowerAssets(address(account)), 0);
        assertEq(settlementToken.balanceOf(OWNER), 0);
    }

    function _ownerCommit(
        bool close,
        uint256 size,
        uint256 margin
    ) private returns (uint64 id) {
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, close, size, margin);
        id = router.nextCommitId();
        vm.prank(OWNER);
        account.execute(address(router), 0, abi.encodeCall(OrderRouter.commitOrder, (request)));
        assertEq(router.lifecycleBook().pendingIntent(id).account, address(account));
        assertEq(router.pendingOrderCounts(OWNER), 0, "owner never becomes the trader");
    }

    function testFork_OwnerClosesSameAccountWithoutSponsorOrAssets() public {
        uint64 id = _ownerCommit(true, BOUNTY_SIZE / 2, 0);
        OrderV3Types.OrderReceipt memory receipt =
            _bountyExecute(id, BOUNTY_PRICE, OWNER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(receipt.account, address(account));
        assertEq(receipt.bountyAssets, 0);
        assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None));
        id = _ownerCommit(true, BOUNTY_SIZE / 2, 0);
        receipt = _bountyExecute(id, BOUNTY_PRICE, OWNER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(receipt.economics.postPositionSize, 0);
        assertEq(router.pendingOrderCounts(address(account)), 0);
        (uint256 ownerSize,,,,,,) = engine.positions(OWNER);
        assertEq(ownerSize, 0);
    }

    function testFork_ExpiredOwnerCommitCleansWithoutOracleAndCanRetry() public {
        uint64 id = _ownerCommit(true, BOUNTY_SIZE, 0);
        _bountyExpire(id, OWNER);
        assertEq(clearinghouse.getFreeBuyingPowerAssets(address(account)), 0);
        id = _ownerCommit(true, BOUNTY_SIZE, 0);
        _bountyExecute(id, BOUNTY_PRICE, OWNER, OrderV3Types.LifecycleStatus.Executed);
    }

    function testFork_ForeignOwnerCannotCommitForAccount() public {
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        vm.prank(BOUNTY_OTHER);
        vm.expectRevert();
        account.execute(address(router), 0, abi.encodeCall(OrderRouter.commitOrder, (request)));
        assertEq(router.pendingOrderCounts(address(account)), 0);
    }

}
