// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPerpsLPActions} from "@plether/perps/interfaces/IPerpsLPActions.sol";
import {IPerpsLPViews} from "@plether/perps/interfaces/IPerpsLPViews.sol";

/// @notice Combined LP-facing surface for the simplified perps product API.
interface IPerpsLP is IPerpsLPActions, IPerpsLPViews {}
