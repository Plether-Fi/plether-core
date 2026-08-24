// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Shared take-profit and stop-loss protection types for the delayed perps router.
library PositionProtectionTypes {

    /// @notice Lifecycle state of one full-position OCO protection record.
    enum PositionProtectionStatus {
        /// @notice No protection was assigned to the queried id.
        None,
        /// @notice Protection is attached to a pending open and cannot trigger until that open executes.
        /// @dev A successful fill arms the protection even if its fill tick crossed a staged threshold; triggering still
        ///      requires a valid later-block oracle publication.
        PendingOpen,
        /// @notice Protection is active against the account's current position.
        Armed,
        /// @notice A trigger created one linked full-position close in the ordinary FIFO queue.
        Triggered,
        /// @notice The linked close executed successfully.
        Executed,
        /// @notice The parent open or linked close reached a terminal failure.
        Failed,
        /// @notice The owner cancelled the protection before it triggered.
        Cancelled,
        /// @notice Liquidation terminally removed the protection and any linked close.
        Liquidated
    }

    /// @notice The OCO leg that activated a protection.
    enum PositionProtectionTriggerLeg {
        /// @notice No leg has triggered.
        None,
        /// @notice The take-profit threshold triggered.
        TakeProfit,
        /// @notice The stop-loss threshold triggered.
        StopLoss
    }

    /// @notice Trader-supplied OCO thresholds.
    /// @dev Prices use 8 decimals. Zero disables the corresponding leg; both legs cannot be zero.
    /// @param takeProfitTriggerPrice Direction-aware take-profit trigger, or zero to disable take profit.
    /// @param stopLossTriggerPrice Direction-aware stop-loss trigger, or zero to disable stop loss.
    struct PositionProtectionParams {
        uint256 takeProfitTriggerPrice;
        uint256 stopLossTriggerPrice;
    }

    /// @notice Complete retained view of one position-protection record.
    /// @dev Prices use 8 decimals, `size` uses 18 decimals, and bounty fields use 6-decimal USDC.
    /// @param protectionId Monotonically increasing protection identifier.
    /// @param parentOrderId Opening order that must execute before protection arms, or zero for an existing position.
    /// @param linkedOrderId Full-position FIFO close created by the trigger, or zero before triggering.
    /// @param account Trader account that owns and funds the protection.
    /// @param side Protected position direction snapshotted when protection arms.
    /// @param size Protected full position size snapshotted when protection arms.
    /// @param takeProfitTriggerPrice Direction-aware take-profit trigger, or zero when disabled.
    /// @param stopLossTriggerPrice Direction-aware stop-loss trigger, or zero when disabled.
    /// @param triggerBountyUsdc Current unpaid trigger bounty; zero after trigger, cancellation, or terminal cleanup.
    /// @param executionBountyUsdc Current unpaid linked-close bounty; zero once transferred to ordinary order accounting
    ///        or released during cancellation or terminal cleanup.
    /// @param armedAt Timestamp at which the protection most recently became armed.
    /// @param armedBlock Block number at which the protection most recently became armed.
    /// @param triggerMarkPrice Neutral oracle mark that activated the protection, or zero before triggering.
    /// @param triggerPublishTime Oracle publish time associated with `triggerMarkPrice`, or zero before triggering.
    /// @param triggeredLeg OCO leg that activated the protection.
    /// @param status Current retained lifecycle status.
    struct PositionProtectionView {
        uint64 protectionId;
        uint64 parentOrderId;
        uint64 linkedOrderId;
        address account;
        CfdTypes.Side side;
        uint256 size;
        uint256 takeProfitTriggerPrice;
        uint256 stopLossTriggerPrice;
        uint256 triggerBountyUsdc;
        uint256 executionBountyUsdc;
        uint64 armedAt;
        uint64 armedBlock;
        uint256 triggerMarkPrice;
        uint64 triggerPublishTime;
        PositionProtectionTriggerLeg triggeredLeg;
        PositionProtectionStatus status;
    }

}
