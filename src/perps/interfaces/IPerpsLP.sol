// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPerpsLPActions} from "./IPerpsLPActions.sol";
import {IPerpsLPViews} from "./IPerpsLPViews.sol";

/// @notice Combined LP-facing surface for the simplified perps product API.
interface IPerpsLP is IPerpsLPActions, IPerpsLPViews {}
