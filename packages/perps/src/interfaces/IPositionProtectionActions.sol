// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

/// @notice Trader and keeper actions implemented by the router-discoverable position-protection book.
interface IPositionProtectionActions {

    /// @notice Arms one OCO protection against the caller's existing full position.
    /// @dev At least one trigger must be enabled. The caller must have no other protection or ordinary pending order.
    ///      Creation reserves both protection bounties and validates trigger geometry against the cached fresh mark.
    /// @param params Direction-aware take-profit and stop-loss trigger prices.
    /// @return protectionId Newly assigned protection identifier.
    function createPositionProtection(
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external returns (uint64 protectionId);

    /// @notice Atomically replaces the trigger prices of the caller's staged or armed protection.
    /// @dev Replacement retains the protection id and its snapshotted bounty reserve. Triggered protection is binding
    ///      and cannot be replaced. Parent execution binds pending-open protection to the actual resulting side and
    ///      full size; threshold crossing at that execution tick does not prevent arming.
    /// @param protectionId Pending-open or armed protection owned by the caller.
    /// @param params Replacement take-profit and stop-loss trigger prices.
    function replacePositionProtection(
        uint64 protectionId,
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external;

    /// @notice Cancels the caller's protection before it triggers and releases its unpaid bounty reserve.
    /// @dev A `PendingOpen` cancellation detaches protection but does not cancel its already-committed parent open.
    /// @param protectionId Pending-open or armed protection owned by the caller.
    function cancelPositionProtection(
        uint64 protectionId
    ) external;

    /// @notice Permissionlessly evaluates an armed protection and queues its full-position market close when met.
    /// @dev The generated close joins the ordinary global FIFO tail and inherits normal oracle timing and expiry.
    /// @param protectionId Armed protection to evaluate.
    /// @param pythUpdateData Pyth update blobs used for the neutral trigger mark.
    /// @return linkedOrderId Newly committed ordinary close order identifier.
    function triggerPositionProtection(
        uint64 protectionId,
        bytes[] calldata pythUpdateData
    ) external payable returns (uint64 linkedOrderId);

    /// @notice Commits an opening order and stages TP/SL protection in the same transaction.
    /// @dev The protection becomes `Armed` atomically if the parent open executes. Parent failure terminally fails the
    ///      protection and releases its protection bounties. A fill that has crossed a staged threshold still arms the
    ///      protection; only a valid later-block publication may trigger it. This is for a flat account with no orders.
    ///      The parent is a fresh public V2 intent and must satisfy the same bounded-request policy as `commitOrder`.
    /// @param request Complete caller-authored opening intent and execution bounds.
    /// @param params Take-profit and stop-loss trigger prices staged for the resulting position.
    /// @return parentOrderId Newly committed opening-order identifier.
    /// @return protectionId Newly staged protection identifier.
    function commitOpenOrderWithProtection(
        OrderV2Types.OrderRequest calldata request,
        PositionProtectionTypes.PositionProtectionParams calldata params
    ) external returns (uint64 parentOrderId, uint64 protectionId);

}
