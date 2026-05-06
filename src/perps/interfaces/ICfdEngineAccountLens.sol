// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {AccountLensViewTypes} from "./AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "./ICfdEngineTypes.sol";

interface ICfdEngineAccountLens {

    /// @dev Legacy detailed account lens kept for internal tooling, tests, and migration.
    ///      Product-facing consumers should prefer `IPerpsTraderViews` via `PerpsPublicLens`.
    function getAccountCollateralView(
        address account
    ) external view returns (ICfdEngineTypes.AccountCollateralView memory viewData);

    function getWithdrawableUsdc(
        address account
    ) external view returns (uint256 withdrawableUsdc);

    function getAccountLedgerView(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerView memory viewData);

    function getAccountLedgerSnapshot(
        address account
    ) external view returns (AccountLensViewTypes.AccountLedgerSnapshot memory snapshot);

}
