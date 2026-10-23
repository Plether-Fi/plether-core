// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

/// @notice Trader and keeper actions implemented by the router-discoverable position-protection book.
interface IPositionProtectionActions {

    /// @notice Arms one OCO protection against the caller's existing full position.
    /// @dev At least one trigger must be enabled. The caller must have no other protection or ordinary pending order.
    ///      Creation reserves the protection-trigger bounty and validates trigger geometry against the accepted fresh basket.
    ///      Existing-position creation remains available in degraded mode, subject to the same post-lock risk checks.
    ///      Router pause blocks creation and replacement; cancellation, triggering, and retry remain available.
    /// @param params Direction-aware trigger prices and financial ceilings for generated closes.
    /// @return protectionId Newly assigned protection identifier.
    function createPositionProtection(
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external returns (uint64 protectionId);

    /// @notice Atomically replaces the trigger prices and close limits of the caller's staged or armed protection.
    /// @dev Replacement retains the protection id and its snapshotted trigger-bounty reserve. Triggered and latched
    ///      protection are binding and cannot be replaced. Parent execution binds pending-open protection to the
    ///      resulting side and full size; threshold crossing at that execution tick does not prevent arming.
    /// @param protectionId Pending-open or armed protection owned by the caller.
    /// @param params Replacement trigger prices and close financial ceilings.
    function replacePositionProtection(
        uint64 protectionId,
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external;

    /// @notice Lets the owner change close limits after a failed attempt relatches, before a fresh retry.
    /// @dev The trigger and any terminal attempts remain recorded. A live child cannot be changed.
    function amendLatchedPositionProtectionCloseLimits(
        uint64 protectionId,
        PositionProtectionTypes.CloseFinancialLimits calldata limits
    ) external;

    /// @notice Cancels the caller's protection before it triggers and releases its unpaid bounty reserve.
    /// @dev A `PendingOpen` cancellation detaches protection but does not cancel its already-committed parent open.
    /// @param protectionId Pending-open or armed protection owned by the caller.
    function cancelPositionProtection(
        uint64 protectionId
    ) external;

    /// @notice Atomically cancels the caller's armed protection and commits a bounded full-position close.
    /// @dev Releases the unused trigger bounty without checkpointing carry before ordinary close admission, which
    ///      collects and bounds all commitment carry. Any commitment failure rolls back
    ///      cancellation and refund. Available during frozen markets and Router pause; execution still follows FIFO
    ///      and the supplied bounds. Only a fresh client id is accepted. Once queued, the close is an ordinary order:
    ///      its later failure or expiry does not restore protection. Pending-open, triggered and latched records reject.
    /// @param protectionId Armed protection owned by the caller and matching the current full position.
    /// @param request Caller-authored full close with matching side, current nonzero config hash, and financial bounds.
    /// @return orderId Newly committed ordinary close identifier.
    function cancelPositionProtectionAndCommitClose(
        uint64 protectionId,
        OrderV3Types.OrderRequest calldata request
    ) external returns (uint64 orderId);

    /// @notice Permissionlessly evaluates an armed protection and queues its full-position market close when met.
    /// @dev The generated close joins the ordinary global FIFO tail and inherits normal oracle timing and expiry.
    /// @param protectionId Armed protection to evaluate.
    /// @param pythUpdateData Pyth update blobs used for the neutral trigger mark.
    /// @return linkedOrderId Newly committed ordinary close order identifier.
    function triggerPositionProtection(
        uint64 protectionId,
        bytes[] calldata pythUpdateData
    ) external payable returns (uint64 linkedOrderId);

    /// @notice Permissionlessly queues a fresh full-position close for an already-latched protection.
    /// @dev The original trigger is not re-evaluated. The fresh zero-bounty child receives a new order id, commit
    ///      clock, expiry, and oracle settlement window at the FIFO tail.
    ///      This safety action remains available while new protection commits are paused.
    /// @param protectionId Latched protection whose latest close attempt is already terminal.
    /// @return linkedOrderId Newly committed ordinary close-attempt identifier.
    function retryPositionProtectionClose(
        uint64 protectionId
    ) external returns (uint64 linkedOrderId);

    /// @notice Commits an opening order and stages TP/SL protection in the same transaction.
    /// @dev The protection becomes `Armed` atomically if the parent open executes. Parent failure terminally fails the
    ///      protection and releases its unpaid trigger bounty. A fill that has crossed a staged threshold still arms the
    ///      protection; only a valid later-block publication may trigger it. This is for a flat account with no orders.
    ///      The parent is a fresh public V3 intent and must satisfy the same bounded-request policy as `commitOrder`.
    /// @param request Complete caller-authored opening intent and execution bounds.
    /// @param params Trigger prices and close financial ceilings staged for the resulting position.
    /// @return parentOrderId Newly committed opening-order identifier.
    /// @return protectionId Newly staged protection identifier.
    function commitOpenOrderWithProtection(
        OrderV3Types.OrderRequest calldata request,
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external returns (uint64 parentOrderId, uint64 protectionId);

}
