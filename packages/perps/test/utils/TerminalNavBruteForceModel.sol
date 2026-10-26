// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Minimal canonical Engine surface used by the independent terminal-NAV reference model.
/// @dev This interface deliberately excludes every TerminalNavBook selector and every derived account lens.
interface ITerminalNavBruteForceEngine {

    function CAP_PRICE() external view returns (uint256);

    function positions(
        address account
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitAssets,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

    function positionEntryCostAssetAtoms(
        address account
    ) external view returns (uint256);

    function traderClaimBalanceAssets(
        address account
    ) external view returns (uint256);

}

/// @notice Minimal canonical clearinghouse surface used by the independent terminal-NAV reference model.
interface ITerminalNavBruteForceClearinghouse {

    function pnlPledgeAssets(
        address account
    ) external view returns (uint256);

}

/// @title Independent brute-force terminal NAV reference model
/// @notice Reconstructs account-capped LP price PnL directly from canonical Engine and clearinghouse state.
/// @dev The model intentionally does not import or consume TerminalNavBook records, hashes, radix nodes, or helpers.
///      It uses direct per-account payoff evaluation, a representation independent of the production radix index.
library TerminalNavBruteForceModel {

    error TerminalNavBruteForceModel__DuplicateAccount(address account);
    error TerminalNavBruteForceModel__InvalidPositionSize(address account, uint256 size);
    error TerminalNavBruteForceModel__InvalidEntryCost(address account, uint256 entryCost, uint256 maximumEntryCost);
    error TerminalNavBruteForceModel__OrphanPnlPledge(address account, uint256 pnlPledgeAssets);
    error TerminalNavBruteForceModel__MarkPriceAboveCap(uint256 markPrice, uint256 capPrice);
    error TerminalNavBruteForceModel__SignedValueOverflow(uint256 magnitude);

    struct AccountState {
        address account;
        uint256 size;
        uint256 lots;
        uint256 entryCostAssetAtoms;
        uint256 maxProfitAssets;
        uint256 pnlPledgeAssets;
        uint256 traderClaimBalanceAssets;
        uint256 collectibleCapAssetAtoms;
        uint256 effectiveCapAssetAtoms;
        CfdTypes.Side side;
        bool active;
    }

    struct SideTotals {
        uint256 size;
        uint256 entryCostAssetAtoms;
        uint256 maxProfitAssets;
        uint256 pnlPledgeAssets;
    }

    struct PortfolioTotals {
        uint256 activePositionCount;
        uint256 totalLots;
        uint256 totalEntryCostAssetAtoms;
        uint256 totalEffectiveCapAssetAtoms;
        uint256 totalTraderClaimsAssets;
        SideTotals long;
        SideTotals short;
    }

    /// @notice Loads one exhaustive account domain from canonical state without consulting the NAV book.
    /// @dev Duplicate accounts are rejected because brute-force enumeration must count every canonical account once.
    function loadPortfolio(
        ITerminalNavBruteForceEngine engine,
        ITerminalNavBruteForceClearinghouse clearinghouse,
        address[] memory accounts
    ) internal view returns (AccountState[] memory states, PortfolioTotals memory totals) {
        uint256 capPrice = engine.CAP_PRICE();
        states = new AccountState[](accounts.length);

        for (uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];
            for (uint256 j = 0; j < i; ++j) {
                if (accounts[j] == account) {
                    revert TerminalNavBruteForceModel__DuplicateAccount(account);
                }
            }

            AccountState memory state = _loadAccount(engine, clearinghouse, account, capPrice);
            states[i] = state;
            totals.totalTraderClaimsAssets += state.traderClaimBalanceAssets;
            if (!state.active) {
                continue;
            }

            totals.activePositionCount++;
            totals.totalLots += state.lots;
            totals.totalEntryCostAssetAtoms += state.entryCostAssetAtoms;
            totals.totalEffectiveCapAssetAtoms += state.effectiveCapAssetAtoms;

            SideTotals memory sideTotals = state.side == CfdTypes.Side.LONG ? totals.long : totals.short;
            sideTotals.size += state.size;
            sideTotals.entryCostAssetAtoms += state.entryCostAssetAtoms;
            sideTotals.maxProfitAssets += state.maxProfitAssets;
            sideTotals.pnlPledgeAssets += state.pnlPledgeAssets;
            if (state.side == CfdTypes.Side.LONG) {
                totals.long = sideTotals;
            } else {
                totals.short = sideTotals;
            }
        }
    }

    /// @notice Directly sums every account payoff at one mark in O(number of supplied accounts).
    function aggregateDeltaAt(
        AccountState[] memory states,
        uint256 markPrice,
        uint256 capPrice
    ) internal pure returns (int256 terminalLpPriceDeltaAssets) {
        if (markPrice > capPrice) {
            revert TerminalNavBruteForceModel__MarkPriceAboveCap(markPrice, capPrice);
        }
        for (uint256 i = 0; i < states.length; ++i) {
            terminalLpPriceDeltaAssets += accountDeltaAt(states[i], markPrice);
        }
    }

    /// @notice Evaluates exact-basis terminal price PnL with the supplied collectible cap, without affine encoding.
    /// @dev Positive values collectible by LPs are capped. Negative values owed by LPs remain uncapped.
    function accountDeltaAt(
        AccountState memory state,
        uint256 markPrice
    ) internal pure returns (int256 terminalLpPriceDeltaAssets) {
        if (!state.active) {
            return 0;
        }

        uint256 exitValueAssetAtoms = state.lots * markPrice;
        uint256 positiveValue;
        uint256 negativeValue;
        if (state.side == CfdTypes.Side.LONG) {
            if (exitValueAssetAtoms >= state.entryCostAssetAtoms) {
                positiveValue = exitValueAssetAtoms - state.entryCostAssetAtoms;
            } else {
                negativeValue = state.entryCostAssetAtoms - exitValueAssetAtoms;
            }
        } else if (state.entryCostAssetAtoms >= exitValueAssetAtoms) {
            positiveValue = state.entryCostAssetAtoms - exitValueAssetAtoms;
        } else {
            negativeValue = exitValueAssetAtoms - state.entryCostAssetAtoms;
        }

        if (negativeValue != 0) {
            return -_toInt256(negativeValue);
        }
        uint256 collectibleValue =
            positiveValue < state.collectibleCapAssetAtoms ? positiveValue : state.collectibleCapAssetAtoms;
        return _toInt256(collectibleValue);
    }

    /// @notice First integer price at or above the account's exact entry-cost crossing.
    function breakEvenBoundary(
        AccountState memory state
    ) internal pure returns (uint256) {
        if (!state.active) {
            return 0;
        }
        return _ceilDiv(state.entryCostAssetAtoms, state.lots);
    }

    /// @notice Returns the account-local collectible-cap transition when it lies strictly inside the raw payoff.
    function capTransitionBoundary(
        AccountState memory state,
        uint256 capPrice
    ) internal pure returns (bool hasTransition, uint256 boundary) {
        if (!state.active) {
            return (false, 0);
        }

        uint256 maximumCollectible = state.side == CfdTypes.Side.LONG
            ? state.lots * capPrice - state.entryCostAssetAtoms
            : state.entryCostAssetAtoms;
        if (state.effectiveCapAssetAtoms >= maximumCollectible) {
            return (false, 0);
        }

        if (state.side == CfdTypes.Side.LONG) {
            boundary = _ceilDiv(state.entryCostAssetAtoms + state.effectiveCapAssetAtoms, state.lots);
        } else {
            boundary = _ceilDiv(state.entryCostAssetAtoms - state.effectiveCapAssetAtoms, state.lots);
        }
        hasTransition = true;
    }

    function _loadAccount(
        ITerminalNavBruteForceEngine engine,
        ITerminalNavBruteForceClearinghouse clearinghouse,
        address account,
        uint256 capPrice
    ) private view returns (AccountState memory state) {
        (uint256 size,,, uint256 maxProfitAssets, CfdTypes.Side side,,) = engine.positions(account);
        uint256 pnlPledgeAssets = clearinghouse.pnlPledgeAssets(account);
        uint256 traderClaimBalanceAssets = engine.traderClaimBalanceAssets(account);
        uint256 entryCostAssetAtoms = engine.positionEntryCostAssetAtoms(account);

        state.account = account;
        state.size = size;
        state.entryCostAssetAtoms = entryCostAssetAtoms;
        state.maxProfitAssets = maxProfitAssets;
        state.pnlPledgeAssets = pnlPledgeAssets;
        state.traderClaimBalanceAssets = traderClaimBalanceAssets;
        state.side = side;

        if (size == 0) {
            if (entryCostAssetAtoms != 0) {
                revert TerminalNavBruteForceModel__InvalidEntryCost(account, entryCostAssetAtoms, 0);
            }
            if (pnlPledgeAssets != 0) {
                revert TerminalNavBruteForceModel__OrphanPnlPledge(account, pnlPledgeAssets);
            }
            return state;
        }
        if (size % CfdTypes.SIZE_QUANTUM != 0) {
            revert TerminalNavBruteForceModel__InvalidPositionSize(account, size);
        }
        state.active = true;
        state.lots = size / CfdTypes.SIZE_QUANTUM;
        uint256 maximumEntryCost = state.lots * capPrice;
        if (entryCostAssetAtoms > maximumEntryCost) {
            revert TerminalNavBruteForceModel__InvalidEntryCost(account, entryCostAssetAtoms, maximumEntryCost);
        }

        state.collectibleCapAssetAtoms = pnlPledgeAssets + traderClaimBalanceAssets;
        uint256 maximumCollectible =
            side == CfdTypes.Side.LONG ? maximumEntryCost - entryCostAssetAtoms : entryCostAssetAtoms;
        state.effectiveCapAssetAtoms =
            state.collectibleCapAssetAtoms < maximumCollectible ? state.collectibleCapAssetAtoms : maximumCollectible;
    }

    function _ceilDiv(
        uint256 numerator,
        uint256 denominator
    ) private pure returns (uint256) {
        return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
    }

    function _toInt256(
        uint256 magnitude
    ) private pure returns (int256 signedValue) {
        if (magnitude > uint256(type(int256).max)) {
            revert TerminalNavBruteForceModel__SignedValueOverflow(magnitude);
        }
        signedValue = int256(magnitude);
    }

}
