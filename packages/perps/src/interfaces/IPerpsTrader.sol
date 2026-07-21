// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPerpsTraderActions} from "@plether/perps/interfaces/IPerpsTraderActions.sol";
import {IPerpsTraderViews} from "@plether/perps/interfaces/IPerpsTraderViews.sol";

/// @notice Logical aggregate of delayed-order trader actions and compact product-facing reads.
/// @dev The live action and read selectors are split between OrderRouter and PerpsPublicLens respectively; consumers
///      should not assume one deployed contract implements this complete composite interface.
interface IPerpsTrader is IPerpsTraderActions, IPerpsTraderViews {}
