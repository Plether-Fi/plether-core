// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPerpsLPActions} from "@plether/perps/interfaces/IPerpsLPActions.sol";
import {IPerpsLPViews} from "@plether/perps/interfaces/IPerpsLPViews.sol";

/// @notice Logical aggregate of tranche-vault action hooks and product-facing LP read selectors.
/// @dev The live action and read selectors are split between HousePool and PerpsPublicLens respectively; consumers
///      should not assume one deployed contract implements this complete composite interface.
interface IPerpsLP is IPerpsLPActions, IPerpsLPViews {}
