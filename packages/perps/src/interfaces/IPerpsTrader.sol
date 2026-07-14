// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPerpsTraderActions} from "@plether/perps/interfaces/IPerpsTraderActions.sol";
import {IPerpsTraderViews} from "@plether/perps/interfaces/IPerpsTraderViews.sol";

/// @notice Combined trader-facing surface for the simplified perps product API.
interface IPerpsTrader is IPerpsTraderActions, IPerpsTraderViews {}
