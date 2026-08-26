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
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

    function positionEntryCostUsdcAtoms(
        address account
    ) external view returns (uint256);

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256);

}

/// @notice Minimal canonical clearinghouse surface used by the independent terminal-NAV reference model.
interface ITerminalNavBruteForceClearinghouse {

    function pnlPledgeUsdc(
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
    error TerminalNavBruteForceModel__OrphanPnlPledge(address account, uint256 pnlPledgeUsdc);
    error TerminalNavBruteForceModel__MarkPriceAboveCap(uint256 markPrice, uint256 capPrice);
    error TerminalNavBruteForceModel__SignedValueOverflow(uint256 magnitude);

    struct AccountState {
        address account;
        uint256 size;
        uint256 lots;
        uint256 entryCostUsdcAtoms;
        uint256 maxProfitUsdc;
        uint256 pnlPledgeUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 collectibleCapUsdcAtoms;
        uint256 effectiveCapUsdcAtoms;
        CfdTypes.Side side;
        bool active;
    }

    struct SideTotals {
        uint256 size;
        uint256 entryCostUsdcAtoms;
        uint256 maxProfitUsdc;
        uint256 pnlPledgeUsdc;
    }

    struct PortfolioTotals {
        uint256 activePositionCount;
        uint256 totalLots;
        uint256 totalEntryCostUsdcAtoms;
        uint256 totalEffectiveCapUsdcAtoms;
        uint256 totalTraderClaimsUsdc;
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
            totals.totalTraderClaimsUsdc += state.traderClaimBalanceUsdc;
            if (!state.active) {
                continue;
            }

            totals.activePositionCount++;
            totals.totalLots += state.lots;
            totals.totalEntryCostUsdcAtoms += state.entryCostUsdcAtoms;
            totals.totalEffectiveCapUsdcAtoms += state.effectiveCapUsdcAtoms;

            SideTotals memory sideTotals = state.side == CfdTypes.Side.LONG ? totals.long : totals.short;
            sideTotals.size += state.size;
            sideTotals.entryCostUsdcAtoms += state.entryCostUsdcAtoms;
            sideTotals.maxProfitUsdc += state.maxProfitUsdc;
            sideTotals.pnlPledgeUsdc += state.pnlPledgeUsdc;
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
    ) internal pure returns (int256 terminalLpPriceDeltaUsdc) {
        if (markPrice > capPrice) {
            revert TerminalNavBruteForceModel__MarkPriceAboveCap(markPrice, capPrice);
        }
        for (uint256 i = 0; i < states.length; ++i) {
            terminalLpPriceDeltaUsdc += accountDeltaAt(states[i], markPrice);
        }
    }

    /// @notice Evaluates `min(account LP price PnL, pledge + same-account claim)` without affine encoding.
    /// @dev Positive values collectible by LPs are capped. Negative values owed by LPs remain uncapped.
    function accountDeltaAt(
        AccountState memory state,
        uint256 markPrice
    ) internal pure returns (int256 terminalLpPriceDeltaUsdc) {
        if (!state.active) {
            return 0;
        }

        uint256 exitValueUsdcAtoms = state.lots * markPrice;
        uint256 positiveValue;
        uint256 negativeValue;
        if (state.side == CfdTypes.Side.LONG) {
            if (exitValueUsdcAtoms >= state.entryCostUsdcAtoms) {
                positiveValue = exitValueUsdcAtoms - state.entryCostUsdcAtoms;
            } else {
                negativeValue = state.entryCostUsdcAtoms - exitValueUsdcAtoms;
            }
        } else if (state.entryCostUsdcAtoms >= exitValueUsdcAtoms) {
            positiveValue = state.entryCostUsdcAtoms - exitValueUsdcAtoms;
        } else {
            negativeValue = exitValueUsdcAtoms - state.entryCostUsdcAtoms;
        }

        if (negativeValue != 0) {
            return -_toInt256(negativeValue);
        }
        uint256 collectibleValue =
            positiveValue < state.collectibleCapUsdcAtoms ? positiveValue : state.collectibleCapUsdcAtoms;
        return _toInt256(collectibleValue);
    }

    /// @notice First integer price at or above the account's exact entry-cost crossing.
    function breakEvenBoundary(
        AccountState memory state
    ) internal pure returns (uint256) {
        if (!state.active) {
            return 0;
        }
        return _ceilDiv(state.entryCostUsdcAtoms, state.lots);
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
            ? state.lots * capPrice - state.entryCostUsdcAtoms
            : state.entryCostUsdcAtoms;
        if (state.effectiveCapUsdcAtoms >= maximumCollectible) {
            return (false, 0);
        }

        if (state.side == CfdTypes.Side.LONG) {
            boundary = _ceilDiv(state.entryCostUsdcAtoms + state.effectiveCapUsdcAtoms, state.lots);
        } else {
            boundary = _ceilDiv(state.entryCostUsdcAtoms - state.effectiveCapUsdcAtoms, state.lots);
        }
        hasTransition = true;
    }

    function _loadAccount(
        ITerminalNavBruteForceEngine engine,
        ITerminalNavBruteForceClearinghouse clearinghouse,
        address account,
        uint256 capPrice
    ) private view returns (AccountState memory state) {
        (uint256 size,,, uint256 maxProfitUsdc, CfdTypes.Side side,,) = engine.positions(account);
        uint256 pnlPledgeUsdc = clearinghouse.pnlPledgeUsdc(account);
        uint256 traderClaimBalanceUsdc = engine.traderClaimBalanceUsdc(account);
        uint256 entryCostUsdcAtoms = engine.positionEntryCostUsdcAtoms(account);

        state.account = account;
        state.size = size;
        state.entryCostUsdcAtoms = entryCostUsdcAtoms;
        state.maxProfitUsdc = maxProfitUsdc;
        state.pnlPledgeUsdc = pnlPledgeUsdc;
        state.traderClaimBalanceUsdc = traderClaimBalanceUsdc;
        state.side = side;

        if (size == 0) {
            if (entryCostUsdcAtoms != 0) {
                revert TerminalNavBruteForceModel__InvalidEntryCost(account, entryCostUsdcAtoms, 0);
            }
            if (pnlPledgeUsdc != 0) {
                revert TerminalNavBruteForceModel__OrphanPnlPledge(account, pnlPledgeUsdc);
            }
            return state;
        }
        if (size % CfdTypes.SIZE_QUANTUM != 0) {
            revert TerminalNavBruteForceModel__InvalidPositionSize(account, size);
        }
        state.active = true;
        state.lots = size / CfdTypes.SIZE_QUANTUM;
        uint256 maximumEntryCost = state.lots * capPrice;
        if (entryCostUsdcAtoms > maximumEntryCost) {
            revert TerminalNavBruteForceModel__InvalidEntryCost(account, entryCostUsdcAtoms, maximumEntryCost);
        }

        state.collectibleCapUsdcAtoms = pnlPledgeUsdc + traderClaimBalanceUsdc;
        uint256 maximumCollectible =
            side == CfdTypes.Side.LONG ? maximumEntryCost - entryCostUsdcAtoms : entryCostUsdcAtoms;
        state.effectiveCapUsdcAtoms =
            state.collectibleCapUsdcAtoms < maximumCollectible ? state.collectibleCapUsdcAtoms : maximumCollectible;
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
