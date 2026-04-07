// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPerpsTraderActions} from "./IPerpsTraderActions.sol";
import {IPerpsTraderViews} from "./IPerpsTraderViews.sol";

/// @notice Combined trader-facing surface for the simplified perps product API.
interface IPerpsTrader is IPerpsTraderActions, IPerpsTraderViews {}
