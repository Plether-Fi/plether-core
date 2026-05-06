// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IOrderRouter} from "./IOrderRouter.sol";

/// @dev Backwards-compatible interface import path. Canonical router ABI declarations live in `IOrderRouter`.
interface IOrderRouterErrors is IOrderRouter {}
