#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0
"""Reference arithmetic and empirical analysis for the Plether Perps white paper.

The integer accounting helpers mirror the stage ordering and floor/ceiling rules
used by the Solidity libraries named in each docstring. The empirical analysis
uses ECB daily reference rates as a reproducible research proxy. It is not an
execution-price replay and must not be used to infer production liquidation
behavior.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import statistics
import urllib.request
from dataclasses import asdict, dataclass
from fractions import Fraction
from html import escape
from pathlib import Path
from typing import Iterable, Literal, Sequence


Side = Literal["LONG", "SHORT"]
SettlementPriority = Literal["liquidations_first", "scheduled_closes_first"]
AccountOrder = Literal["fifo", "reverse"]

WAD = 10**18
USDC = 10**6
PRICE = 10**8
SIZE = 10**18
USDC_TO_TOKEN_SCALE = 10**20
SECONDS_PER_YEAR = 31_536_000
UTILIZATION_BPS = 10_000

CAP_PRICE_8 = 2 * PRICE

ECB_START_DATE = "2016-01-01"
ECB_END_DATE = "2026-06-30"
ECB_DATA_URL = (
    "https://data-api.ecb.europa.eu/service/data/EXR/"
    "D.USD+JPY+GBP+CAD+SEK+CHF.EUR.SP00.A"
    f"?startPeriod={ECB_START_DATE}&endPeriod={ECB_END_DATE}&format=csvdata"
)
EXPECTED_ECB_SHA256 = "45a8b4e376c3f518c6687335ba849d087cb34906e1bfa6217e0305e0223b4eca"

BASKET_WEIGHTS = {
    "EUR": 0.576,
    "JPY": 0.136,
    "GBP": 0.119,
    "CAD": 0.091,
    "SEK": 0.042,
    "CHF": 0.036,
}

BASKET_BASE_USD = {
    "EUR": 1.1750,
    "JPY": 0.00638,
    "GBP": 1.3448,
    "CAD": 0.7288,
    "SEK": 0.1086,
    "CHF": 1.2610,
}


@dataclass(frozen=True)
class SolvencyState:
    physical_assets_usdc: int
    max_liability_usdc: int
    trader_claims_usdc: int
    withdrawal_reserved_usdc: int
    free_withdrawable_usdc: int
    effective_assets_usdc: int


@dataclass(frozen=True)
class WaterfallState:
    senior_principal_usdc: int
    junior_principal_usdc: int
    senior_high_water_mark_usdc: int


@dataclass(frozen=True)
class CloseSettlementResult:
    """Python form of CfdEngineSettlementLib.CloseSettlementResult."""

    seized_usdc: int
    shortfall_usdc: int
    collected_exec_fee_usdc: int
    retained_exec_fee_usdc: int
    bad_debt_usdc: int


@dataclass(frozen=True)
class ClaimConsumptionResult:
    """Existing trader-claim allocation against a close-loss shortfall."""

    consumed_usdc: int
    remaining_usdc: int
    fee_recovered_usdc: int
    bad_debt_usdc: int


@dataclass(frozen=True)
class FreshPayoutResult:
    """Cash-priority routing for one new positive settlement."""

    available_cash_usdc: int
    immediate_payout_usdc: int
    claim_created_usdc: int


@dataclass(frozen=True)
class LiquidationState:
    """Python form of LiquidationAccountingLib.LiquidationState."""

    equity_usdc: int
    reachable_collateral_usdc: int
    maintenance_margin_usdc: int
    keeper_bounty_usdc: int


@dataclass(frozen=True)
class LiquidationSettlementResult:
    """Terminal retention, seizure, payout, and debt after keeper bounty."""

    residual_usdc: int
    settlement_retained_usdc: int
    settlement_seized_usdc: int
    fresh_trader_payout_usdc: int
    bad_debt_usdc: int


@dataclass(frozen=True)
class SolvencyPreview:
    effective_assets_after_usdc: int
    max_liability_after_usdc: int
    triggers_degraded_mode: bool
    post_op_degraded_mode: bool


@dataclass(frozen=True)
class BasketObservation:
    date: dt.date
    basket: float
    eur_usd: float
    jpy_usd: float
    gbp_usd: float
    cad_usd: float
    sek_usd: float
    chf_usd: float


@dataclass
class ReplayPosition:
    account_id: int
    side: Side
    entry_date: dt.date
    scheduled_exit_date: dt.date
    entry_price_8: int
    size_18: int
    margin_usdc: int
    max_profit_usdc: int
    borrow_base_usdc: int
    accrued_carry_usdc: int = 0


@dataclass
class ReplayClaim:
    account_id: int
    created_date: dt.date
    amount_usdc: int


def clamp_price(price_8: int, cap_price_8: int = CAP_PRICE_8) -> int:
    return min(price_8, cap_price_8)


def calculate_pnl(
    size_18: int,
    entry_price_8: int,
    current_price_8: int,
    side: Side,
    cap_price_8: int = CAP_PRICE_8,
) -> tuple[bool, int]:
    """Mirror CfdMath.calculatePnL.

    Returns (is_profit, absolute_pnl_usdc_6). Equality is classified as a
    zero-valued profit for a nonzero position, matching Solidity.
    """

    if size_18 == 0:
        return False, 0
    price_8 = clamp_price(current_price_8, cap_price_8)
    if side == "LONG":
        is_profit = price_8 <= entry_price_8
    elif side == "SHORT":
        is_profit = price_8 >= entry_price_8
    else:
        raise ValueError(f"unknown side: {side}")
    price_diff_8 = abs(price_8 - entry_price_8)
    return is_profit, size_18 * price_diff_8 // USDC_TO_TOKEN_SCALE


def calculate_max_profit(
    size_18: int,
    entry_price_8: int,
    side: Side,
    cap_price_8: int = CAP_PRICE_8,
) -> int:
    """Mirror CfdMath.calculateMaxProfit."""

    if size_18 == 0:
        return 0
    if side == "LONG":
        max_price_diff_8 = entry_price_8
    elif side == "SHORT":
        max_price_diff_8 = max(cap_price_8 - entry_price_8, 0)
    else:
        raise ValueError(f"unknown side: {side}")
    return size_18 * max_price_diff_8 // USDC_TO_TOKEN_SCALE


def weighted_entry_price(
    current_size_18: int,
    current_entry_price_8: int,
    size_delta_18: int,
    execution_price_8: int,
) -> int:
    """Mirror OpenAccountingLib's floor-rounded weighted entry price."""

    if current_size_18 == 0:
        return execution_price_8
    new_size = current_size_18 + size_delta_18
    if new_size == 0:
        return execution_price_8
    return (
        current_size_18 * current_entry_price_8
        + size_delta_18 * execution_price_8
    ) // new_size


def conservatively_realized_carry(
    accrued_carry_usdc_6: int,
    signed_price_pnl_usdc_6: int,
    nonfee_lp_inflow_usdc_6: int,
) -> int:
    """Attribute only gross value actually recovered toward assessed carry.

    Positive price PnL can offset carry before a fresh trader payout. Nonfee LP
    cash inflow first covers negative price PnL. The unified signed expression
    matches both branches and prevents a nonnegative PnL classification from
    crediting uncollected carry after a collateral shortfall.
    """

    gross_recovery = max(
        signed_price_pnl_usdc_6 + nonfee_lp_inflow_usdc_6,
        0,
    )
    return min(accrued_carry_usdc_6, gross_recovery)


def aggregate_claims_serviceable(
    claims: Sequence[ReplayClaim],
    current_date: dt.date,
    physical_cash_usdc_6: int,
    aggregate_claim_usdc_6: int,
) -> bool:
    """Whether all outstanding claims may settle at this observation.

    The research replay deliberately requires a strictly later observation than
    creation even if later same-fix book flows replenish cash.
    """

    return (
        aggregate_claim_usdc_6 > 0
        and physical_cash_usdc_6 >= aggregate_claim_usdc_6
        and all(claim.created_date < current_date for claim in claims)
    )


def _mul_div_ceil(a: int, b: int, denominator: int) -> int:
    if denominator <= 0:
        raise ValueError("denominator must be positive")
    product = a * b
    return (product + denominator - 1) // denominator


def conservative_mtm_liability(
    max_profit_usdc_6: int,
    side: Side,
    price_8: int,
    cap_price_8: int = CAP_PRICE_8,
) -> int:
    """Mirror CfdMath.conservativeMtmLiability, including upward rounding."""

    if max_profit_usdc_6 == 0 or cap_price_8 == 0:
        return 0
    price_8 = clamp_price(price_8, cap_price_8)
    if side == "LONG":
        return _mul_div_ceil(max_profit_usdc_6, cap_price_8 - price_8, cap_price_8)
    if side == "SHORT":
        return _mul_div_ceil(max_profit_usdc_6, price_8, cap_price_8)
    raise ValueError(f"unknown side: {side}")


def max_liability(long_max_profit_usdc_6: int, short_max_profit_usdc_6: int) -> int:
    """Mirror SolvencyAccountingLib.getMaxLiability."""

    return max(long_max_profit_usdc_6, short_max_profit_usdc_6)


def skew_cost(
    skew_usdc_6: int,
    depth_usdc_6: int,
    vpi_factor_wad: int,
) -> int:
    """Mirror CfdMath.getSkewCost with the same intermediate floors."""

    if depth_usdc_6 == 0 or skew_usdc_6 == 0:
        return 0
    skew_wad = skew_usdc_6 * 10**12
    depth_wad = depth_usdc_6 * 10**12
    squared_skew_over_depth_wad = skew_wad * skew_wad // depth_wad
    cost_wad = vpi_factor_wad * squared_skew_over_depth_wad // WAD // 2
    return cost_wad // 10**12


def calculate_vpi(
    pre_skew_usdc_6: int,
    post_skew_usdc_6: int,
    depth_usdc_6: int,
    vpi_factor_wad: int,
) -> int:
    """Mirror CfdMath.calculateVPI. Positive charges; negative rebates."""

    return skew_cost(post_skew_usdc_6, depth_usdc_6, vpi_factor_wad) - skew_cost(
        pre_skew_usdc_6, depth_usdc_6, vpi_factor_wad
    )


def compute_borrow_base(max_profit_usdc_6: int, margin_usdc_6: int) -> int:
    """Mirror PositionRiskAccountingLib.computeBorrowBaseUsdc."""

    return max(max_profit_usdc_6 - margin_usdc_6, 0)


def compute_borrow_utilization_bps(
    borrow_base_usdc_6: int,
    pool_assets_usdc_6: int,
) -> int:
    """Mirror PositionRiskAccountingLib.computeBorrowUtilizationBps."""

    if borrow_base_usdc_6 == 0:
        return 0
    if pool_assets_usdc_6 == 0:
        return UTILIZATION_BPS
    return min(borrow_base_usdc_6 * UTILIZATION_BPS // pool_assets_usdc_6, UTILIZATION_BPS)


def compute_utilized_carry_rate_bps(base_carry_bps: int, utilization_bps: int) -> int:
    """Mirror PositionRiskAccountingLib.computeUtilizedCarryRateBps."""

    return base_carry_bps * min(utilization_bps, UTILIZATION_BPS) // UTILIZATION_BPS


def compute_carry_index_increment(carry_rate_bps: int, elapsed_seconds: int) -> int:
    """Mirror PositionRiskAccountingLib.computeCarryIndexIncrement."""

    if carry_rate_bps == 0 or elapsed_seconds == 0:
        return 0
    return carry_rate_bps * WAD * elapsed_seconds // (SECONDS_PER_YEAR * 10_000)


def compute_current_carry_index(
    stored_index: int,
    previous_timestamp: int,
    current_timestamp: int,
    side_borrow_base_usdc_6: int,
    pool_assets_usdc_6: int,
    base_carry_bps: int,
) -> int:
    """Mirror PositionRiskAccountingLib.computeCurrentCarryIndex."""

    if (
        current_timestamp <= previous_timestamp
        or side_borrow_base_usdc_6 == 0
        or base_carry_bps == 0
    ):
        return stored_index
    utilization_bps = compute_borrow_utilization_bps(
        side_borrow_base_usdc_6, pool_assets_usdc_6
    )
    if utilization_bps == 0:
        return stored_index
    increment = (
        base_carry_bps
        * utilization_bps
        * WAD
        * (current_timestamp - previous_timestamp)
        // (SECONDS_PER_YEAR * UTILIZATION_BPS * 10_000)
    )
    return stored_index + increment


def compute_indexed_carry(borrow_base_usdc_6: int, carry_index_delta: int) -> int:
    """Mirror PositionRiskAccountingLib.computeIndexedCarryUsdc."""

    if borrow_base_usdc_6 == 0 or carry_index_delta == 0:
        return 0
    return borrow_base_usdc_6 * carry_index_delta // WAD


def build_solvency_state(
    physical_assets_usdc_6: int,
    max_liability_usdc_6: int,
    trader_claims_usdc_6: int,
) -> SolvencyState:
    """Mirror the base state in SolvencyAccountingLib.buildSolvencyState."""

    reserved = max_liability_usdc_6 + trader_claims_usdc_6
    return SolvencyState(
        physical_assets_usdc=physical_assets_usdc_6,
        max_liability_usdc=max_liability_usdc_6,
        trader_claims_usdc=trader_claims_usdc_6,
        withdrawal_reserved_usdc=reserved,
        free_withdrawable_usdc=max(physical_assets_usdc_6 - reserved, 0),
        effective_assets_usdc=max(physical_assets_usdc_6 - trader_claims_usdc_6, 0),
    )


def close_settlement_result(
    available_usdc_6: int,
    owed_usdc_6: int,
    execution_fee_usdc_6: int,
    frozen_spread_usdc_6: int,
) -> CloseSettlementResult:
    """Mirror CfdEngineSettlementLib.closeSettlementResult.

    Execution fee has first priority within seized collateral, base loss has
    second priority, and frozen spread is junior. Frozen-spread shortfall is
    excluded from bad debt.
    """

    seized = min(available_usdc_6, owed_usdc_6)
    shortfall = owed_usdc_6 - seized
    total_charges = execution_fee_usdc_6 + frozen_spread_usdc_6
    retained_charges = max(total_charges - owed_usdc_6, 0)
    retained_execution_fee = min(execution_fee_usdc_6, retained_charges)
    retained_after_execution_fee = retained_charges - retained_execution_fee
    retained_frozen_spread = min(
        frozen_spread_usdc_6, retained_after_execution_fee
    )

    fee_embedded = execution_fee_usdc_6 - retained_execution_fee
    collected_execution_fee = min(fee_embedded, seized)
    spread_embedded = frozen_spread_usdc_6 - retained_frozen_spread
    base_owed = owed_usdc_6 - fee_embedded - spread_embedded
    seized_after_execution_fee = seized - collected_execution_fee
    collected_base = min(base_owed, seized_after_execution_fee)
    bad_debt = base_owed - collected_base
    return CloseSettlementResult(
        seized_usdc=seized,
        shortfall_usdc=shortfall,
        collected_exec_fee_usdc=collected_execution_fee,
        retained_exec_fee_usdc=retained_execution_fee,
        bad_debt_usdc=bad_debt,
    )


def plan_close_claim_consumption(
    trader_claim_balance_usdc_6: int,
    loss_result: CloseSettlementResult,
    execution_fee_usdc_6: int,
) -> ClaimConsumptionResult:
    """Mirror CfdEnginePlanLib._planCloseTraderClaimConsumption."""

    if trader_claim_balance_usdc_6 == 0 or loss_result.shortfall_usdc == 0:
        return ClaimConsumptionResult(
            consumed_usdc=0,
            remaining_usdc=trader_claim_balance_usdc_6,
            fee_recovered_usdc=0,
            bad_debt_usdc=loss_result.bad_debt_usdc,
        )

    consumed = min(trader_claim_balance_usdc_6, loss_result.shortfall_usdc)
    remaining = trader_claim_balance_usdc_6 - consumed
    uncollected_execution_fee = (
        execution_fee_usdc_6
        - loss_result.retained_exec_fee_usdc
        - loss_result.collected_exec_fee_usdc
    )
    fee_recovered = min(consumed, uncollected_execution_fee)
    recovery_remaining = consumed - fee_recovered
    bad_debt_recovered = min(recovery_remaining, loss_result.bad_debt_usdc)
    return ClaimConsumptionResult(
        consumed_usdc=consumed,
        remaining_usdc=remaining,
        fee_recovered_usdc=fee_recovered,
        bad_debt_usdc=loss_result.bad_debt_usdc - bad_debt_recovered,
    )


def reserve_fresh_payout(
    physical_assets_usdc_6: int,
    aggregate_trader_claims_usdc_6: int,
    fresh_payout_usdc_6: int,
) -> FreshPayoutResult:
    """Mirror CashPriorityLib reservation plus all-or-nothing fresh routing."""

    available = max(
        physical_assets_usdc_6 - aggregate_trader_claims_usdc_6, 0
    )
    immediate = (
        fresh_payout_usdc_6
        if fresh_payout_usdc_6 > 0 and available >= fresh_payout_usdc_6
        else 0
    )
    return FreshPayoutResult(
        available_cash_usdc=available,
        immediate_payout_usdc=immediate,
        claim_created_usdc=fresh_payout_usdc_6 - immediate,
    )


def build_liquidation_state(
    size_18: int,
    oracle_price_8: int,
    reachable_collateral_usdc_6: int,
    equity_usdc_6: int,
    maintenance_margin_bps: int,
    minimum_bounty_usdc_6: int,
    bounty_bps: int,
) -> LiquidationState:
    """Mirror LiquidationAccountingLib.buildLiquidationState."""

    notional = size_18 * oracle_price_8 // USDC_TO_TOKEN_SCALE
    maintenance = notional * maintenance_margin_bps // 10_000
    bounty = max(notional * bounty_bps // 10_000, minimum_bounty_usdc_6)
    bounty = min(bounty, reachable_collateral_usdc_6)
    return LiquidationState(
        equity_usdc=equity_usdc_6,
        reachable_collateral_usdc=reachable_collateral_usdc_6,
        maintenance_margin_usdc=maintenance,
        keeper_bounty_usdc=bounty,
    )


def liquidation_settlement_for_state(
    state: LiquidationState,
) -> LiquidationSettlementResult:
    """Mirror planLiquidationResidual for a single reachable balance.

    The returned debt follows the planner's keeper-subsidy adjustment: bounty
    above nonnegative equity is not recognized as trading bad debt.
    """

    residual = state.equity_usdc - state.keeper_bounty_usdc
    reachable_after_bounty = max(
        state.reachable_collateral_usdc - state.keeper_bounty_usdc, 0
    )
    if residual >= 0:
        retained = min(reachable_after_bounty, residual)
        return LiquidationSettlementResult(
            residual_usdc=residual,
            settlement_retained_usdc=retained,
            settlement_seized_usdc=reachable_after_bounty - retained,
            fresh_trader_payout_usdc=residual - retained,
            bad_debt_usdc=0,
        )

    raw_bad_debt = -residual
    if state.equity_usdc >= 0:
        keeper_subsidy = max(state.keeper_bounty_usdc - state.equity_usdc, 0)
        raw_bad_debt = max(raw_bad_debt - keeper_subsidy, 0)
    return LiquidationSettlementResult(
        residual_usdc=residual,
        settlement_retained_usdc=0,
        settlement_seized_usdc=reachable_after_bounty,
        fresh_trader_payout_usdc=0,
        bad_debt_usdc=raw_bad_debt,
    )


def preview_post_op_solvency(
    current_state: SolvencyState,
    physical_assets_delta_usdc_6: int,
    max_liability_after_usdc_6: int,
    trader_claim_delta_usdc_6: int,
    pending_pool_payout_usdc_6: int,
    already_degraded: bool,
) -> SolvencyPreview:
    """Mirror SolvencyAccountingLib.previewPostOpSolvency."""

    physical_after = max(
        current_state.physical_assets_usdc + physical_assets_delta_usdc_6, 0
    )
    claims_after = max(
        current_state.trader_claims_usdc + trader_claim_delta_usdc_6, 0
    )
    effective_after = max(
        physical_after - claims_after - pending_pool_payout_usdc_6, 0
    )
    post_degraded = effective_after < max_liability_after_usdc_6
    return SolvencyPreview(
        effective_assets_after_usdc=effective_after,
        max_liability_after_usdc=max_liability_after_usdc_6,
        triggers_degraded_mode=not already_degraded and post_degraded,
        post_op_degraded_mode=post_degraded,
    )


def calculate_senior_coupon(
    senior_principal_usdc_6: int,
    senior_rate_bps: int,
    elapsed_seconds: int,
) -> int:
    """Mirror HousePoolWaterfallAccountingLib.calculateSeniorCoupon."""

    if senior_principal_usdc_6 == 0 or elapsed_seconds == 0:
        return 0
    return (
        senior_principal_usdc_6
        * senior_rate_bps
        * elapsed_seconds
        // (10_000 * SECONDS_PER_YEAR)
    )


def pay_senior_coupon(
    state: WaterfallState,
    senior_rate_bps: int,
    elapsed_seconds: int,
) -> tuple[WaterfallState, int]:
    """Mirror HousePoolWaterfallAccountingLib.paySeniorCoupon."""

    due = calculate_senior_coupon(
        state.senior_principal_usdc, senior_rate_bps, elapsed_seconds
    )
    paid = min(due, state.junior_principal_usdc)
    if paid == 0:
        return state, 0

    senior = state.senior_principal_usdc
    junior = state.junior_principal_usdc - paid
    high_water = state.senior_high_water_mark_usdc
    remaining = paid
    if senior < high_water:
        restored = min(remaining, high_water - senior)
        senior += restored
        remaining -= restored
    if remaining:
        senior += remaining
        high_water += remaining
    return WaterfallState(senior, junior, high_water), paid


def distribute_revenue(state: WaterfallState, revenue_usdc_6: int) -> WaterfallState:
    """Mirror HousePoolWaterfallAccountingLib.distributeRevenue."""

    senior = state.senior_principal_usdc
    junior = state.junior_principal_usdc
    high_water = state.senior_high_water_mark_usdc
    remaining = revenue_usdc_6
    if remaining and senior < high_water:
        restored = min(remaining, high_water - senior)
        senior += restored
        remaining -= restored
    if senior > high_water:
        high_water = senior
    junior += remaining
    return WaterfallState(senior, junior, high_water)


def absorb_loss(state: WaterfallState, loss_usdc_6: int) -> WaterfallState:
    """Mirror HousePoolWaterfallAccountingLib.absorbLoss."""

    junior_loss = min(loss_usdc_6, state.junior_principal_usdc)
    junior = state.junior_principal_usdc - junior_loss
    senior_loss = loss_usdc_6 - junior_loss
    senior = max(state.senior_principal_usdc - senior_loss, 0)
    return WaterfallState(senior, junior, state.senior_high_water_mark_usdc)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_ecb_data(destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        ECB_DATA_URL,
        headers={"User-Agent": "Plether bounded-perps research model/1.0"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        destination.write_bytes(response.read())


def load_ecb_basket(csv_path: Path) -> list[BasketObservation]:
    """Construct Plether's normalized linear basket from ECB EUR reference rates.

    ECB observations quote units of each currency per EUR. USD value per unit of
    a non-EUR component is therefore (USD per EUR) / (component units per EUR).
    """

    by_date: dict[str, dict[str, float]] = {}
    with csv_path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            by_date.setdefault(row["TIME_PERIOD"], {})[row["CURRENCY"]] = float(
                row["OBS_VALUE"]
            )

    required = {"USD", "JPY", "GBP", "CAD", "SEK", "CHF"}
    observations: list[BasketObservation] = []
    for date_text, rates in sorted(by_date.items()):
        if not required.issubset(rates):
            continue
        usd_per_eur = rates["USD"]
        usd_prices = {
            "EUR": usd_per_eur,
            "JPY": usd_per_eur / rates["JPY"],
            "GBP": usd_per_eur / rates["GBP"],
            "CAD": usd_per_eur / rates["CAD"],
            "SEK": usd_per_eur / rates["SEK"],
            "CHF": usd_per_eur / rates["CHF"],
        }
        basket = sum(
            BASKET_WEIGHTS[currency]
            * usd_prices[currency]
            / BASKET_BASE_USD[currency]
            for currency in BASKET_WEIGHTS
        )
        observations.append(
            BasketObservation(
                date=dt.date.fromisoformat(date_text),
                basket=basket,
                eur_usd=usd_prices["EUR"],
                jpy_usd=usd_prices["JPY"],
                gbp_usd=usd_prices["GBP"],
                cad_usd=usd_prices["CAD"],
                sek_usd=usd_prices["SEK"],
                chf_usd=usd_prices["CHF"],
            )
        )
    if not observations:
        raise ValueError(f"no complete ECB observations found in {csv_path}")
    return observations


def _quantile_ceiling(values: Sequence[float], quantile: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.ceil(quantile * len(ordered)) - 1)
    return ordered[index]


def _intervals(
    observations: Sequence[BasketObservation],
) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for previous, current in zip(observations, observations[1:]):
        result.append(
            {
                "from": previous.date,
                "to": current.date,
                "calendar_days": (current.date - previous.date).days,
                "return": current.basket / previous.basket - 1,
                "from_basket": previous.basket,
                "to_basket": current.basket,
            }
        )
    return result


def _max_drawdown(
    observations: Sequence[BasketObservation],
) -> dict[str, object]:
    peak = observations[0]
    worst = {"return": 0.0, "from": peak.date, "to": peak.date}
    for observation in observations:
        if observation.basket > peak.basket:
            peak = observation
        drawdown = observation.basket / peak.basket - 1
        if drawdown < float(worst["return"]):
            worst = {
                "return": drawdown,
                "from": peak.date,
                "to": observation.date,
                "from_basket": peak.basket,
                "to_basket": observation.basket,
            }
    return worst


def _max_forward_reserve_utilization(
    observations: Sequence[BasketObservation],
    side: Side,
    cap: float = 2.0,
) -> dict[str, object]:
    if side == "LONG":
        future_extreme = observations[-1]
        best: dict[str, object] = {"reserve_utilization": 0.0}
        for entry in reversed(observations[:-1]):
            price_profit = entry.basket - future_extreme.basket
            reserve = entry.basket
            utilization = max(price_profit, 0.0) / reserve
            if utilization > float(best["reserve_utilization"]):
                best = {
                    "side": side,
                    "entry_date": entry.date,
                    "entry_price": entry.basket,
                    "exit_date": future_extreme.date,
                    "exit_price": future_extreme.basket,
                    "price_profit_per_unit": max(price_profit, 0.0),
                    "endpoint_reserve_per_unit": reserve,
                    "reserve_utilization": utilization,
                }
            if entry.basket < future_extreme.basket:
                future_extreme = entry
        return best

    future_extreme = observations[-1]
    best = {"reserve_utilization": 0.0}
    for entry in reversed(observations[:-1]):
        price_profit = future_extreme.basket - entry.basket
        reserve = cap - entry.basket
        utilization = max(price_profit, 0.0) / reserve
        if utilization > float(best["reserve_utilization"]):
            best = {
                "side": side,
                "entry_date": entry.date,
                "entry_price": entry.basket,
                "exit_date": future_extreme.date,
                "exit_price": future_extreme.basket,
                "price_profit_per_unit": max(price_profit, 0.0),
                "endpoint_reserve_per_unit": reserve,
                "reserve_utilization": utilization,
            }
        if entry.basket > future_extreme.basket:
            future_extreme = entry
    return best


def run_historical_replay(
    observations: Sequence[BasketObservation],
    *,
    cap: float = 2.0,
    momentum_share: float = 0.80,
    initial_pool_usd: float = 100_000_000,
    cohort_target_notional_usd: float = 90_000_000,
    holding_calendar_days: int = 63,
    signal_lookback_observations: int = 20,
    initial_margin_bps: int = 150,
    maintenance_margin_bps: int = 100,
    base_carry_bps: int = 500,
    senior_rate_bps: int = 800,
    execution_fee_bps: int = 4,
    bounty_bps: int = 10,
    minimum_bounty_usd: float = 1.0,
    max_skew_ratio: float = 0.40,
    settlement_priority: SettlementPriority = "liquidations_first",
    account_order: AccountOrder = "fifo",
) -> dict[str, object]:
    """Run a deterministic, stylized stateful replay over ECB observations.

    The replay uses exact integer kernels for capped PnL, carry, close
    collection, cash-priority claims, liquidation bounty, and tranche
    accounting after prices and parameter ratios have been quantized. It is
    deliberately not a transaction-level backtest: daily ECB fixes stand in
    for executable marks; VPI, confidence shifts, the frozen state, keeper
    latency, cross-account free collateral, and pending deposit epochs are held
    outside the replay.

    Each first observation of a calendar month opens a 63-calendar-day cohort.
    The side aligned with a 20-fix move known at the previous observation
    receives
    ``momentum_share`` of target entry notional; the other side receives the
    remainder. The next observation is the entry-price proxy. Admission scales
    the paired cohort on an integer 1e18 grid until the endpoint and final-skew
    predicates pass. Claims are serviced at the first strictly later
    observation on which aggregate claim liabilities are fully cash covered,
    assuming beneficiaries call immediately.
    """

    if not 0.5 <= momentum_share <= 1.0:
        raise ValueError("momentum_share must lie in [0.5, 1.0]")
    if cap <= max(observation.basket for observation in observations):
        raise ValueError("cap must exceed every replay basket observation")
    if signal_lookback_observations + 1 >= len(observations):
        raise ValueError("signal lookback exceeds observation count")
    if not 0 <= max_skew_ratio <= 1:
        raise ValueError("max_skew_ratio must lie in [0, 1]")
    if settlement_priority not in (
        "liquidations_first",
        "scheduled_closes_first",
    ):
        raise ValueError("unknown settlement_priority")
    if account_order not in ("fifo", "reverse"):
        raise ValueError("unknown account_order")

    cap_price_8 = round(cap * PRICE)
    momentum_fraction = Fraction(str(momentum_share))
    max_skew_fraction = Fraction(str(max_skew_ratio))

    cash = round(initial_pool_usd * USDC)
    initial_cash = cash
    treasury_fees = 0
    active: list[ReplayPosition] = []
    claims: list[ReplayClaim] = []
    next_account_id = 1
    long_liability = 0
    short_liability = 0
    claim_total = 0
    bad_debt = 0
    carry_assessed = 0
    carry_realized = 0
    keeper_bounties = 0
    immediate_payouts = 0
    claim_created_total = 0
    claim_settled_total = 0
    max_claims = 0
    claim_durations: list[int] = []
    liquidation_count = 0
    gap_liquidation_count = 0
    scheduled_close_count = 0
    forced_final_close_count = 0
    opened_positions = 0
    admitted_cohorts = 0
    scaled_cohorts = 0
    rejected_cohorts = 0
    capacity_bound_cohorts = 0
    skew_bound_cohorts = 0
    degraded_rejections = 0
    no_admissible_scale_rejections = 0
    target_notional_requested = 0
    admitted_notional = 0
    admitted_long_notional = 0
    admitted_short_notional = 0
    degraded = False
    degraded_triggers = 0
    degraded_clears = 0
    loss_events: list[int] = []
    junior_impairment_events = 0
    senior_impairment_events = 0
    senior_coupon_paid = 0
    waterfall = WaterfallState(
        initial_cash // 2,
        initial_cash - initial_cash // 2,
        initial_cash // 2,
    )
    minimum_senior = waterfall.senior_principal_usdc
    minimum_junior = waterfall.junior_principal_usdc
    conservative_waterfall = waterfall
    conservative_coupon_paid = 0
    conservative_minimum_senior = waterfall.senior_principal_usdc
    conservative_minimum_junior = waterfall.junior_principal_usdc
    conservative_senior_impairment_events = 0
    conservative_junior_impairment_events = 0
    conservative_maximum_mtm = 0
    conservative_minimum_distributable = initial_cash
    utilization_day_sum = 0.0
    aggregate_borrow_ratio_day_sum = 0.0
    long_borrow_utilization_day_sum = 0.0
    short_borrow_utilization_day_sum = 0.0
    elapsed_days_total = 0
    maximum_reserve_utilization = 0.0
    maximum_aggregate_borrow_ratio = 0.0
    maximum_long_borrow_utilization = 0.0
    maximum_short_borrow_utilization = 0.0
    maximum_post_admission_skew_ratio = 0.0
    admission_checks = 0
    monthly_key: tuple[int, int] | None = None
    current_interval_is_gap = False

    def economic_equity() -> int:
        return cash - claim_total

    def endpoint_envelope() -> int:
        return max(long_liability, short_liability)

    def side_open_interest(side: Side) -> int:
        return sum(
            position.size_18
            for position in active
            if position.side == side
        )

    def book_skew_usdc(price_8: int) -> int:
        long_notional = (
            side_open_interest("LONG") * price_8 // USDC_TO_TOKEN_SCALE
        )
        short_notional = (
            side_open_interest("SHORT") * price_8 // USDC_TO_TOKEN_SCALE
        )
        return abs(long_notional - short_notional)

    def checkpoint_coupons(elapsed_seconds: int) -> None:
        nonlocal waterfall, conservative_waterfall
        nonlocal senior_coupon_paid, conservative_coupon_paid
        nonlocal minimum_senior, minimum_junior
        nonlocal conservative_minimum_senior, conservative_minimum_junior
        waterfall, paid = pay_senior_coupon(
            waterfall,
            senior_rate_bps,
            elapsed_seconds,
        )
        senior_coupon_paid += paid
        conservative_waterfall, conservative_paid = pay_senior_coupon(
            conservative_waterfall,
            senior_rate_bps,
            elapsed_seconds,
        )
        conservative_coupon_paid += conservative_paid
        minimum_senior = min(
            minimum_senior,
            waterfall.senior_principal_usdc,
        )
        minimum_junior = min(
            minimum_junior,
            waterfall.junior_principal_usdc,
        )
        conservative_minimum_senior = min(
            conservative_minimum_senior,
            conservative_waterfall.senior_principal_usdc,
        )
        conservative_minimum_junior = min(
            conservative_minimum_junior,
            conservative_waterfall.junior_principal_usdc,
        )

    def apply_waterfall_change(before_equity: int) -> None:
        nonlocal waterfall
        nonlocal minimum_senior, minimum_junior
        nonlocal junior_impairment_events, senior_impairment_events
        after_equity = economic_equity()
        delta = after_equity - before_equity
        if delta > 0:
            waterfall = distribute_revenue(waterfall, delta)
        elif delta < 0:
            loss = -delta
            loss_events.append(loss)
            senior_before = waterfall.senior_principal_usdc
            junior_before = waterfall.junior_principal_usdc
            waterfall = absorb_loss(waterfall, loss)
            if waterfall.junior_principal_usdc < junior_before:
                junior_impairment_events += 1
            if waterfall.senior_principal_usdc < senior_before:
                senior_impairment_events += 1
        minimum_senior = min(minimum_senior, waterfall.senior_principal_usdc)
        minimum_junior = min(minimum_junior, waterfall.junior_principal_usdc)

    def reconcile_conservative_waterfall(price_8: int) -> None:
        """Apply one end-of-observation HousePool-style MtM shadow reconcile."""

        nonlocal conservative_waterfall
        nonlocal conservative_minimum_senior, conservative_minimum_junior
        nonlocal conservative_senior_impairment_events
        nonlocal conservative_junior_impairment_events
        nonlocal conservative_maximum_mtm
        nonlocal conservative_minimum_distributable

        mtm = conservative_mtm_liability(
            long_liability,
            "LONG",
            price_8,
            cap_price_8,
        ) + conservative_mtm_liability(
            short_liability,
            "SHORT",
            price_8,
            cap_price_8,
        )
        distributable = max(cash - claim_total - mtm, 0)
        conservative_maximum_mtm = max(conservative_maximum_mtm, mtm)
        conservative_minimum_distributable = min(
            conservative_minimum_distributable,
            distributable,
        )
        claimed = (
            conservative_waterfall.senior_principal_usdc
            + conservative_waterfall.junior_principal_usdc
        )
        if distributable > claimed:
            conservative_waterfall = distribute_revenue(
                conservative_waterfall,
                distributable - claimed,
            )
        elif claimed > distributable:
            senior_before = conservative_waterfall.senior_principal_usdc
            junior_before = conservative_waterfall.junior_principal_usdc
            conservative_waterfall = absorb_loss(
                conservative_waterfall,
                claimed - distributable,
            )
            if (
                conservative_waterfall.junior_principal_usdc
                < junior_before
            ):
                conservative_junior_impairment_events += 1
            if (
                conservative_waterfall.senior_principal_usdc
                < senior_before
            ):
                conservative_senior_impairment_events += 1
        conservative_minimum_senior = min(
            conservative_minimum_senior,
            conservative_waterfall.senior_principal_usdc,
        )
        conservative_minimum_junior = min(
            conservative_minimum_junior,
            conservative_waterfall.junior_principal_usdc,
        )

    def route_fresh_payout(
        account_id: int, date: dt.date, amount_usdc: int
    ) -> bool:
        nonlocal cash, claim_total, immediate_payouts
        nonlocal claim_created_total, max_claims
        route = reserve_fresh_payout(cash, claim_total, amount_usdc)
        if route.immediate_payout_usdc:
            cash -= route.immediate_payout_usdc
            immediate_payouts += route.immediate_payout_usdc
            return True
        if route.claim_created_usdc:
            claims.append(
                ReplayClaim(account_id, date, route.claim_created_usdc)
            )
            claim_total += route.claim_created_usdc
            claim_created_total += route.claim_created_usdc
            max_claims = max(max_claims, claim_total)
        return False

    def service_claims(date: dt.date) -> None:
        nonlocal cash, claim_total, claim_settled_total
        if not aggregate_claims_serviceable(
            claims,
            date,
            cash,
            claim_total,
        ):
            return
        cash -= claim_total
        claim_settled_total += claim_total
        claim_durations.extend(
            (date - claim.created_date).days for claim in claims
        )
        claims.clear()
        claim_total = 0

    def remove_position(position: ReplayPosition) -> None:
        nonlocal long_liability, short_liability
        if position.side == "LONG":
            long_liability -= position.max_profit_usdc
        else:
            short_liability -= position.max_profit_usdc
        active.remove(position)

    def price_pnl(position: ReplayPosition, price_8: int) -> int:
        is_profit, absolute = calculate_pnl(
            position.size_18,
            position.entry_price_8,
            price_8,
            position.side,
            cap_price_8,
        )
        return absolute if is_profit else -absolute

    def realize_carry_conservatively(
        position: ReplayPosition, pnl_usdc: int, lp_cash_inflow_usdc: int
    ) -> None:
        nonlocal carry_realized
        carry_realized += conservatively_realized_carry(
            position.accrued_carry_usdc,
            pnl_usdc,
            lp_cash_inflow_usdc,
        )

    def settle_liquidation(
        position: ReplayPosition, observation: BasketObservation
    ) -> None:
        nonlocal cash, bad_debt, keeper_bounties, liquidation_count
        nonlocal gap_liquidation_count
        price_8 = round(observation.basket * PRICE)
        pnl_usdc = price_pnl(position, price_8)
        equity = (
            position.margin_usdc
            + pnl_usdc
            - position.accrued_carry_usdc
        )
        state = build_liquidation_state(
            position.size_18,
            price_8,
            position.margin_usdc,
            equity,
            maintenance_margin_bps,
            round(minimum_bounty_usd * USDC),
            bounty_bps,
        )
        result = liquidation_settlement_for_state(state)
        before_equity = economic_equity()
        cash += result.settlement_seized_usdc
        if result.fresh_trader_payout_usdc:
            route_fresh_payout(
                position.account_id,
                observation.date,
                result.fresh_trader_payout_usdc,
            )
        bad_debt += result.bad_debt_usdc
        keeper_bounties += state.keeper_bounty_usdc
        realize_carry_conservatively(
            position, pnl_usdc, result.settlement_seized_usdc
        )
        remove_position(position)
        liquidation_count += 1
        if current_interval_is_gap:
            gap_liquidation_count += 1
        apply_waterfall_change(before_equity)

    def settle_voluntary_close(
        position: ReplayPosition,
        observation: BasketObservation,
        forced_final: bool,
    ) -> None:
        nonlocal cash, treasury_fees, bad_debt
        nonlocal scheduled_close_count, forced_final_close_count
        price_8 = round(observation.basket * PRICE)
        pnl_usdc = price_pnl(position, price_8)
        current_notional = (
            position.size_18 * price_8 // USDC_TO_TOKEN_SCALE
        )
        execution_fee = current_notional * execution_fee_bps // 10_000
        net_settlement = (
            pnl_usdc - execution_fee - position.accrued_carry_usdc
        )
        before_equity = economic_equity()
        lp_cash_inflow = 0
        if net_settlement > 0:
            immediate = route_fresh_payout(
                position.account_id, observation.date, net_settlement
            )
            if immediate:
                free_after_payout = max(cash - claim_total, 0)
                fee_top_up = min(execution_fee, free_after_payout)
                cash -= fee_top_up
                treasury_fees += fee_top_up
            realize_carry_conservatively(position, pnl_usdc, 0)
        elif net_settlement < 0:
            owed = -net_settlement
            loss_result = close_settlement_result(
                position.margin_usdc, owed, execution_fee, 0
            )
            recognized_fee = (
                loss_result.collected_exec_fee_usdc
                + loss_result.retained_exec_fee_usdc
            )
            uncredited_fee = (
                recognized_fee - loss_result.collected_exec_fee_usdc
            )
            pool_after_direct_fee = (
                cash
                + loss_result.seized_usdc
                - loss_result.collected_exec_fee_usdc
            )
            fee_top_up = min(
                uncredited_fee,
                max(pool_after_direct_fee - claim_total, 0),
            )
            cash += (
                loss_result.seized_usdc
                - loss_result.collected_exec_fee_usdc
                - fee_top_up
            )
            lp_cash_inflow = (
                loss_result.seized_usdc
                - loss_result.collected_exec_fee_usdc
                - fee_top_up
            )
            treasury_fees += (
                loss_result.collected_exec_fee_usdc + fee_top_up
            )
            bad_debt += loss_result.bad_debt_usdc
            realize_carry_conservatively(
                position, pnl_usdc, lp_cash_inflow
            )
        else:
            fee_top_up = min(execution_fee, max(cash - claim_total, 0))
            cash -= fee_top_up
            treasury_fees += fee_top_up
            realize_carry_conservatively(position, pnl_usdc, 0)

        remove_position(position)
        if forced_final:
            forced_final_close_count += 1
        else:
            scheduled_close_count += 1
        apply_waterfall_change(before_equity)

    def accrue_interval(elapsed_days: int) -> None:
        nonlocal carry_assessed
        if elapsed_days <= 0 or not active:
            return
        elapsed_seconds = elapsed_days * 86_400
        for side in ("LONG", "SHORT"):
            side_positions = [
                position for position in active if position.side == side
            ]
            side_borrow = sum(
                position.borrow_base_usdc for position in side_positions
            )
            index_increment = compute_current_carry_index(
                0,
                0,
                elapsed_seconds,
                side_borrow,
                max(cash, 0),
                base_carry_bps,
            )
            for position in side_positions:
                amount = compute_indexed_carry(
                    position.borrow_base_usdc, index_increment
                )
                position.accrued_carry_usdc += amount
                carry_assessed += amount

    def open_monthly_cohort(
        index: int, observation: BasketObservation
    ) -> None:
        nonlocal next_account_id, long_liability, short_liability
        nonlocal opened_positions, admitted_cohorts, scaled_cohorts
        nonlocal rejected_cohorts, target_notional_requested, admitted_notional
        nonlocal admitted_long_notional, admitted_short_notional
        nonlocal treasury_fees, maximum_post_admission_skew_ratio
        nonlocal admission_checks
        nonlocal capacity_bound_cohorts, skew_bound_cohorts
        nonlocal degraded_rejections, no_admissible_scale_rejections

        target_notional = round(cohort_target_notional_usd * USDC)
        target_notional_requested += target_notional
        if degraded:
            rejected_cohorts += 1
            degraded_rejections += 1
            return

        signal_end = observations[index - 1]
        signal_start = observations[
            index - 1 - signal_lookback_observations
        ]
        momentum_side: Side = (
            "SHORT" if signal_end.basket >= signal_start.basket else "LONG"
        )
        long_share = (
            momentum_fraction
            if momentum_side == "LONG"
            else 1 - momentum_fraction
        )
        short_share = 1 - long_share
        target_long_notional = (
            target_notional * long_share.numerator // long_share.denominator
        )
        target_short_notional = target_notional - target_long_notional
        entry_price_8 = round(observation.basket * PRICE)
        effective_assets = max(cash - claim_total, 0)
        current_long_oi = side_open_interest("LONG")
        current_short_oi = side_open_interest("SHORT")
        max_skew_usdc = (
            max(cash, 0)
            * max_skew_fraction.numerator
            // max_skew_fraction.denominator
        )

        def candidate(
            scale_wad: int,
        ) -> list[tuple[Side, int, int, int, int]]:
            planned: list[tuple[Side, int, int, int, int]] = []
            for side, target_side_notional in (
                ("LONG", target_long_notional),
                ("SHORT", target_short_notional),
            ):
                notional = target_side_notional * scale_wad // WAD
                if notional == 0:
                    continue
                size = notional * USDC_TO_TOKEN_SCALE // entry_price_8
                if size == 0:
                    continue
                max_profit = calculate_max_profit(
                    size,
                    entry_price_8,
                    side,
                    cap_price_8,
                )
                margin = notional * initial_margin_bps // 10_000
                planned.append(
                    (side, notional, size, max_profit, margin)
                )
            return planned

        def candidate_liabilities(
            planned: Sequence[tuple[Side, int, int, int, int]],
        ) -> tuple[int, int]:
            added_long = sum(
                row[3] for row in planned if row[0] == "LONG"
            )
            added_short = sum(
                row[3] for row in planned if row[0] == "SHORT"
            )
            return (
                long_liability + added_long,
                short_liability + added_short,
            )

        def capacity_valid(scale_wad: int) -> bool:
            planned = candidate(scale_wad)
            post_long, post_short = candidate_liabilities(planned)
            return max(post_long, post_short) <= effective_assets

        def candidate_skew(scale_wad: int) -> int:
            planned = candidate(scale_wad)
            added_long_oi = sum(
                row[2] for row in planned if row[0] == "LONG"
            )
            added_short_oi = sum(
                row[2] for row in planned if row[0] == "SHORT"
            )
            long_notional = (
                (current_long_oi + added_long_oi)
                * entry_price_8
                // USDC_TO_TOKEN_SCALE
            )
            short_notional = (
                (current_short_oi + added_short_oi)
                * entry_price_8
                // USDC_TO_TOKEN_SCALE
            )
            return abs(long_notional - short_notional)

        low = 0
        high = WAD
        while low < high:
            middle = (low + high + 1) // 2
            if capacity_valid(middle):
                low = middle
            else:
                high = middle - 1
        capacity_scale = low

        if candidate_skew(capacity_scale) <= max_skew_usdc:
            scale_wad = capacity_scale
        else:
            left = 0
            right = capacity_scale
            while right - left > 3:
                third = (right - left) // 3
                first = left + third
                second = right - third
                if candidate_skew(first) <= candidate_skew(second):
                    right = second - 1
                else:
                    left = first + 1
            minimum_skew_scale = min(
                range(left, right + 1),
                key=candidate_skew,
            )
            if candidate_skew(minimum_skew_scale) > max_skew_usdc:
                scale_wad = 0
            else:
                low = minimum_skew_scale
                high = capacity_scale
                while low < high:
                    middle = (low + high + 1) // 2
                    if candidate_skew(middle) <= max_skew_usdc:
                        low = middle
                    else:
                        high = middle - 1
                scale_wad = low

        planned = candidate(scale_wad)
        if not planned:
            rejected_cohorts += 1
            no_admissible_scale_rejections += 1
            return
        if capacity_scale < WAD:
            capacity_bound_cohorts += 1
        if scale_wad < capacity_scale:
            skew_bound_cohorts += 1
        if scale_wad < WAD:
            scaled_cohorts += 1
        scheduled_exit = observation.date + dt.timedelta(
            days=holding_calendar_days
        )

        for side, notional, size, max_profit, margin in planned:
            position = ReplayPosition(
                account_id=next_account_id,
                side=side,
                entry_date=observation.date,
                scheduled_exit_date=scheduled_exit,
                entry_price_8=entry_price_8,
                size_18=size,
                margin_usdc=margin,
                max_profit_usdc=max_profit,
                borrow_base_usdc=compute_borrow_base(max_profit, margin),
            )
            next_account_id += 1
            active.append(position)
            if side == "LONG":
                long_liability += max_profit
            else:
                short_liability += max_profit
            opened_positions += 1
            admitted_notional += notional
            if side == "LONG":
                admitted_long_notional += notional
            else:
                admitted_short_notional += notional
            treasury_fees += notional * execution_fee_bps // 10_000

        admission_checks += 1
        if endpoint_envelope() > max(cash - claim_total, 0):
            raise AssertionError("post-rounding endpoint admission failed")
        post_skew = book_skew_usdc(entry_price_8)
        if post_skew > max_skew_usdc:
            raise AssertionError("post-rounding skew admission failed")
        post_skew_ratio = post_skew / cash if cash > 0 else 0.0
        maximum_post_admission_skew_ratio = max(
            maximum_post_admission_skew_ratio,
            post_skew_ratio,
        )
        admitted_cohorts += 1

    previous = observations[signal_lookback_observations]
    for index in range(signal_lookback_observations + 1, len(observations)):
        observation = observations[index]
        elapsed_days = (observation.date - previous.date).days
        current_interval_is_gap = elapsed_days >= 3
        if elapsed_days > 0:
            effective_assets = max(cash - claim_total, 0)
            reserve_utilization = (
                endpoint_envelope() / effective_assets
                if effective_assets
                else (1.0 if endpoint_envelope() else 0.0)
            )
            long_borrow = sum(
                position.borrow_base_usdc
                for position in active
                if position.side == "LONG"
            )
            short_borrow = sum(
                position.borrow_base_usdc
                for position in active
                if position.side == "SHORT"
            )
            total_borrow = long_borrow + short_borrow
            aggregate_borrow_ratio = (
                min(total_borrow / cash, 1.0)
                if cash > 0
                else float(bool(total_borrow))
            )
            long_borrow_utilization = (
                compute_borrow_utilization_bps(long_borrow, max(cash, 0))
                / UTILIZATION_BPS
            )
            short_borrow_utilization = (
                compute_borrow_utilization_bps(short_borrow, max(cash, 0))
                / UTILIZATION_BPS
            )
            utilization_day_sum += reserve_utilization * elapsed_days
            aggregate_borrow_ratio_day_sum += (
                aggregate_borrow_ratio * elapsed_days
            )
            long_borrow_utilization_day_sum += (
                long_borrow_utilization * elapsed_days
            )
            short_borrow_utilization_day_sum += (
                short_borrow_utilization * elapsed_days
            )
            elapsed_days_total += elapsed_days
            maximum_reserve_utilization = max(
                maximum_reserve_utilization, reserve_utilization
            )
            maximum_aggregate_borrow_ratio = max(
                maximum_aggregate_borrow_ratio,
                aggregate_borrow_ratio,
            )
            maximum_long_borrow_utilization = max(
                maximum_long_borrow_utilization,
                long_borrow_utilization,
            )
            maximum_short_borrow_utilization = max(
                maximum_short_borrow_utilization,
                short_borrow_utilization,
            )
            accrue_interval(elapsed_days)
            checkpoint_coupons(elapsed_days * 86_400)

        price_8 = round(observation.basket * PRICE)

        def ordered_active_positions() -> list[ReplayPosition]:
            return sorted(
                active,
                key=lambda position: position.account_id,
                reverse=account_order == "reverse",
            )

        def process_liquidations() -> None:
            for position in ordered_active_positions():
                pnl = price_pnl(position, price_8)
                equity = (
                    position.margin_usdc
                    + pnl
                    - position.accrued_carry_usdc
                )
                current_notional = (
                    position.size_18
                    * price_8
                    // USDC_TO_TOKEN_SCALE
                )
                maintenance = (
                    current_notional * maintenance_margin_bps // 10_000
                )
                if equity <= maintenance:
                    settle_liquidation(position, observation)

        def process_scheduled_closes() -> None:
            for position in ordered_active_positions():
                if observation.date >= position.scheduled_exit_date:
                    settle_voluntary_close(position, observation, False)

        if settlement_priority == "liquidations_first":
            process_liquidations()
            process_scheduled_closes()
        else:
            process_scheduled_closes()
            process_liquidations()

        service_claims(observation.date)
        effective = max(cash - claim_total, 0)
        post_degraded = effective < endpoint_envelope()
        if post_degraded and not degraded:
            degraded = True
            degraded_triggers += 1
        elif degraded and not post_degraded:
            # Explicit research assumption: owner clears at the next observed
            # solvent state. The protocol does not auto-clear this latch.
            degraded = False
            degraded_clears += 1

        key = (observation.date.year, observation.date.month)
        if (
            index < len(observations) - 1
            and key != monthly_key
        ):
            open_monthly_cohort(index, observation)
            monthly_key = key

        reconcile_conservative_waterfall(price_8)
        previous = observation

    final_observation = observations[-1]
    for position in sorted(
        active,
        key=lambda item: item.account_id,
        reverse=account_order == "reverse",
    ):
        settle_voluntary_close(position, final_observation, True)
    service_claims(final_observation.date)
    reconcile_conservative_waterfall(
        round(final_observation.basket * PRICE)
    )

    unresolved_claim_ages = [
        (final_observation.date - claim.created_date).days for claim in claims
    ]
    loss_usd = [amount / USDC for amount in loss_events]
    waterfall_sum = (
        waterfall.senior_principal_usdc + waterfall.junior_principal_usdc
    )
    conservative_waterfall_sum = (
        conservative_waterfall.senior_principal_usdc
        + conservative_waterfall.junior_principal_usdc
    )
    return {
        "assumptions": {
            "source_marks": "ECB daily information-only reference rates",
            "initial_pool_usd": initial_pool_usd,
            "initial_senior_share": 0.5,
            "cap": cap,
            "monthly_cohort_target_entry_notional_usd": (
                cohort_target_notional_usd
            ),
            "holding_calendar_days": holding_calendar_days,
            "signal_lookback_observations": signal_lookback_observations,
            "signal_execution_lag_observations": 1,
            "momentum_side_share": momentum_share,
            "initial_margin_bps": initial_margin_bps,
            "maintenance_margin_bps": maintenance_margin_bps,
            "base_carry_bps_at_full_utilization": base_carry_bps,
            "senior_rate_bps": senior_rate_bps,
            "execution_fee_bps": execution_fee_bps,
            "liquidation_bounty_bps": bounty_bps,
            "minimum_liquidation_bounty_usd": minimum_bounty_usd,
            "max_skew_ratio": max_skew_ratio,
            "cohort_admission": (
                "Paired SHORT/LONG allocations are scaled on an integer 1e18 "
                "grid until endpoint solvency and the final hard-skew ratio "
                "pass. The paired legs are assumed to be interleaved; this is "
                "not a transaction-level order/VPI simulation."
            ),
            "account_collateral_scope": (
                "Each position uses a unique synthetic account whose terminal "
                "reachable collateral is its posted position margin; no extra "
                "free or committed cross-margin collateral is supplied."
            ),
            "maintenance_calendar_policy": (
                "The replay holds maintenance at 1% and does not switch to the "
                "3% FAD basis around closure windows."
            ),
            "vpi_factor": 0,
            "oracle_confidence_adjustment": 0,
            "frozen_spread_bps": 0,
            "daily_settlement_priority": settlement_priority,
            "within_class_account_order": account_order,
            "end_of_sample_behavior": (
                "Every remaining position is forcibly full-closed at the last "
                "ECB observation in the configured within-class account order."
            ),
            "waterfall_cadence": (
                "The 8% senior coupon is checkpointed once per observed "
                "calendar interval. The realized-cash overlay applies each "
                "cash/claim transition; a separate shadow view reconciles once "
                "at each observation to cash minus claims minus conservative "
                "MtM. Production reconciliation occurs on protocol actions, "
                "not on an automatic daily clock."
            ),
            "claim_service_behavior": (
                "All beneficiaries call on the first strictly later ECB "
                "observation where physical cash covers aggregate claims."
            ),
            "degraded_clear_behavior": (
                "Owner clears the latch at the first observed genuinely "
                "restored state; clearing is not automatic in production."
            ),
        },
        "book": {
            "admitted_cohorts": admitted_cohorts,
            "scaled_cohorts": scaled_cohorts,
            "rejected_cohorts": rejected_cohorts,
            "capacity_bound_cohorts": capacity_bound_cohorts,
            "skew_bound_cohorts": skew_bound_cohorts,
            "degraded_rejections": degraded_rejections,
            "no_admissible_scale_rejections": (
                no_admissible_scale_rejections
            ),
            "post_admission_assertions": admission_checks,
            "opened_positions": opened_positions,
            "target_notional_requested_usd": (
                target_notional_requested / USDC
            ),
            "admitted_notional_usd": admitted_notional / USDC,
            "admitted_long_notional_usd": (
                admitted_long_notional / USDC
            ),
            "admitted_short_notional_usd": (
                admitted_short_notional / USDC
            ),
            "time_weighted_endpoint_reserve_utilization": (
                utilization_day_sum / elapsed_days_total
                if elapsed_days_total
                else 0
            ),
            "maximum_endpoint_reserve_utilization": (
                maximum_reserve_utilization
            ),
            "time_weighted_capped_aggregate_borrow_to_assets": (
                aggregate_borrow_ratio_day_sum / elapsed_days_total
                if elapsed_days_total
                else 0
            ),
            "maximum_capped_aggregate_borrow_to_assets": (
                maximum_aggregate_borrow_ratio
            ),
            "time_weighted_long_borrow_utilization": (
                long_borrow_utilization_day_sum / elapsed_days_total
                if elapsed_days_total
                else 0
            ),
            "time_weighted_short_borrow_utilization": (
                short_borrow_utilization_day_sum / elapsed_days_total
                if elapsed_days_total
                else 0
            ),
            "maximum_long_borrow_utilization": (
                maximum_long_borrow_utilization
            ),
            "maximum_short_borrow_utilization": (
                maximum_short_borrow_utilization
            ),
            "maximum_post_admission_skew_ratio": (
                maximum_post_admission_skew_ratio
            ),
        },
        "settlement": {
            "scheduled_closes": scheduled_close_count,
            "forced_final_closes": forced_final_close_count,
            "liquidations": liquidation_count,
            "liquidations_after_3_plus_day_gap": gap_liquidation_count,
            "immediate_payouts_usd": immediate_payouts / USDC,
            "bad_debt_usd": bad_debt / USDC,
            "keeper_bounties_usd": keeper_bounties / USDC,
            "execution_fees_credited_usd": treasury_fees / USDC,
        },
        "carry": {
            "assessed_usd": carry_assessed / USDC,
            "conservatively_realized_usd": carry_realized / USDC,
            "realization_ratio": (
                carry_realized / carry_assessed if carry_assessed else 0
            ),
        },
        "claims": {
            "created_count": len(claim_durations) + len(claims),
            "created_usd": claim_created_total / USDC,
            "settled_usd": claim_settled_total / USDC,
            "ending_usd": claim_total / USDC,
            "maximum_outstanding_usd": max_claims / USDC,
            "settled_duration_days_mean": (
                statistics.mean(claim_durations) if claim_durations else None
            ),
            "settled_duration_days_max": (
                max(claim_durations) if claim_durations else None
            ),
            "unresolved_count": len(claims),
            "unresolved_age_days_max": (
                max(unresolved_claim_ages) if unresolved_claim_ages else None
            ),
        },
        "tranches": {
            "valuation_basis": (
                "Realized HousePool cash minus trader claims only; this overlay "
                "does not subtract conservative MtM and is not production "
                "share-NAV reconciliation."
            ),
            "senior_coupon_transferred_usd": senior_coupon_paid / USDC,
            "ending_senior_principal_usd": (
                waterfall.senior_principal_usdc / USDC
            ),
            "ending_junior_principal_usd": (
                waterfall.junior_principal_usdc / USDC
            ),
            "ending_high_water_mark_usd": (
                waterfall.senior_high_water_mark_usdc / USDC
            ),
            "minimum_senior_principal_usd": minimum_senior / USDC,
            "minimum_junior_principal_usd": minimum_junior / USDC,
            "junior_impairment_events": junior_impairment_events,
            "senior_impairment_events": senior_impairment_events,
            "loss_event_count": len(loss_events),
            "loss_event_usd_median": (
                statistics.median(loss_usd) if loss_usd else 0
            ),
            "loss_event_usd_p95": (
                _quantile_ceiling(loss_usd, 0.95) if loss_usd else 0
            ),
            "loss_event_usd_maximum": max(loss_usd) if loss_usd else 0,
        },
        "daily_conservative_reconciliation": {
            "valuation_basis": (
                "Once per ECB observation after scheduled replay actions: "
                "max(cash - claims - conservative MtM, 0), with the 8% senior "
                "coupon checkpointed over each observed interval."
            ),
            "senior_coupon_transferred_usd": (
                conservative_coupon_paid / USDC
            ),
            "maximum_conservative_mtm_usd": (
                conservative_maximum_mtm / USDC
            ),
            "minimum_distributable_value_usd": (
                conservative_minimum_distributable / USDC
            ),
            "ending_senior_principal_usd": (
                conservative_waterfall.senior_principal_usdc / USDC
            ),
            "ending_junior_principal_usd": (
                conservative_waterfall.junior_principal_usdc / USDC
            ),
            "ending_high_water_mark_usd": (
                conservative_waterfall.senior_high_water_mark_usdc / USDC
            ),
            "minimum_senior_principal_usd": (
                conservative_minimum_senior / USDC
            ),
            "minimum_junior_principal_usd": (
                conservative_minimum_junior / USDC
            ),
            "junior_impairment_events": (
                conservative_junior_impairment_events
            ),
            "senior_impairment_events": (
                conservative_senior_impairment_events
            ),
            "ending_waterfall_principal_usd": (
                conservative_waterfall_sum / USDC
            ),
        },
        "ending_balance_sheet": {
            "physical_cash_usd": cash / USDC,
            "trader_claims_usd": claim_total / USDC,
            "lp_economic_equity_usd": economic_equity() / USDC,
            "waterfall_principal_usd": waterfall_sum / USDC,
            "daily_conservative_waterfall_principal_usd": (
                conservative_waterfall_sum / USDC
            ),
            "bad_debt_telemetry_usd": bad_debt / USDC,
        },
        "containment": {
            "degraded_mode_triggers": degraded_triggers,
            "assumed_owner_clears": degraded_clears,
            "ending_degraded": degraded,
        },
    }


def _serialize(value: object) -> object:
    if isinstance(value, dt.date):
        return value.isoformat()
    if hasattr(value, "__dataclass_fields__"):
        return {key: _serialize(item) for key, item in asdict(value).items()}
    if isinstance(value, dict):
        return {str(key): _serialize(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_serialize(item) for item in value]
    return value


def build_analysis(
    observations: Sequence[BasketObservation],
    raw_sha256: str,
) -> dict[str, object]:
    intervals = _intervals(observations)
    nonpublication_gaps = [
        interval for interval in intervals if int(interval["calendar_days"]) >= 3
    ]
    friday_monday = [
        interval
        for interval in intervals
        if interval["from"].weekday() == 4
        and interval["to"].weekday() == 0
        and interval["calendar_days"] == 3
    ]

    def interval_stats(items: Sequence[dict[str, object]]) -> dict[str, object]:
        absolute_returns = [abs(float(item["return"])) for item in items]
        maximum = max(items, key=lambda item: abs(float(item["return"])))
        return {
            "count": len(items),
            "mean_absolute_return": statistics.mean(absolute_returns),
            "median_absolute_return": statistics.median(absolute_returns),
            "p95_absolute_return": _quantile_ceiling(absolute_returns, 0.95),
            "p99_absolute_return": _quantile_ceiling(absolute_returns, 0.99),
            "maximum_absolute_return": abs(float(maximum["return"])),
            "maximum_interval": maximum,
        }

    margin_thresholds = {}
    for margin_bps in (100, 150, 300):
        threshold = margin_bps / 10_000
        margin_thresholds[str(margin_bps)] = {
            "all_observation_intervals": sum(
                abs(float(item["return"])) > threshold for item in intervals
            ),
            "nonpublication_gaps": sum(
                abs(float(item["return"])) > threshold
                for item in nonpublication_gaps
            ),
            "friday_monday_intervals": sum(
                abs(float(item["return"])) > threshold for item in friday_monday
            ),
        }

    cap_sensitivity = []
    pool_assets = 100_000_000
    long_size = 30_000_000
    short_size = 50_000_000
    entry = 1.0
    for cap in (1.10, 1.25, 1.50, 1.75, 2.00, 2.50, 3.00):
        long_liability = round(long_size * entry, 2)
        short_liability = round(short_size * max(cap - entry, 0.0), 2)
        liability = max(long_liability, short_liability)
        cap_sensitivity.append(
            {
                "cap": cap,
                "long_endpoint_liability_usd": long_liability,
                "short_endpoint_liability_usd": short_liability,
                "max_liability_usd": liability,
                "pool_reserve_utilization": liability / pool_assets,
            }
        )

    pool_6 = 100_000_000 * USDC
    long_borrow_6 = compute_borrow_base(40_000_000 * USDC, 4_000_000 * USDC)
    short_borrow_6 = compute_borrow_base(25_000_000 * USDC, 2_500_000 * USDC)
    long_util_bps = compute_borrow_utilization_bps(long_borrow_6, pool_6)
    short_util_bps = compute_borrow_utilization_bps(short_borrow_6, pool_6)
    long_index = compute_current_carry_index(
        0, 0, SECONDS_PER_YEAR, long_borrow_6, pool_6, 500
    )
    short_index = compute_current_carry_index(
        0, 0, SECONDS_PER_YEAR, short_borrow_6, pool_6, 500
    )

    waterfall_initial = WaterfallState(50_000_000 * USDC, 50_000_000 * USDC, 50_000_000 * USDC)
    historical_gap_loss_6 = round(
        interval_stats(friday_monday)["maximum_absolute_return"]
        * 100_000_000
        * USDC
    )
    waterfall_after_gap = absorb_loss(waterfall_initial, historical_gap_loss_6)
    waterfall_after_60m_stress = absorb_loss(waterfall_initial, 60_000_000 * USDC)

    replay_scenarios = {
        "balanced_50_50": run_historical_replay(
            observations, cap=2.0, momentum_share=0.50
        ),
        "momentum_80_20": run_historical_replay(
            observations, cap=2.0, momentum_share=0.80
        ),
        "momentum_100_0": run_historical_replay(
            observations, cap=2.0, momentum_share=1.00
        ),
    }

    def ordering_summary(
        priority: SettlementPriority,
        order: AccountOrder,
        result: dict[str, object],
    ) -> dict[str, object]:
        book = result["book"]  # type: ignore[index]
        settlement = result["settlement"]  # type: ignore[index]
        claims_result = result["claims"]  # type: ignore[index]
        tranches = result["tranches"]  # type: ignore[index]
        conservative = result["daily_conservative_reconciliation"]  # type: ignore[index]
        ending = result["ending_balance_sheet"]  # type: ignore[index]
        return {
            "settlement_priority": priority,
            "account_order": order,
            "admitted_notional_usd": book["admitted_notional_usd"],  # type: ignore[index]
            "liquidations": settlement["liquidations"],  # type: ignore[index]
            "scheduled_closes": settlement["scheduled_closes"],  # type: ignore[index]
            "bad_debt_usd": settlement["bad_debt_usd"],  # type: ignore[index]
            "maximum_claims_usd": claims_result["maximum_outstanding_usd"],  # type: ignore[index]
            "ending_lp_equity_usd": ending["lp_economic_equity_usd"],  # type: ignore[index]
            "cash_overlay_minimum_senior_usd": tranches["minimum_senior_principal_usd"],  # type: ignore[index]
            "daily_conservative_minimum_senior_usd": conservative["minimum_senior_principal_usd"],  # type: ignore[index]
        }

    ordering_sensitivity: list[dict[str, object]] = []
    for priority, order in (
        ("liquidations_first", "fifo"),
        ("scheduled_closes_first", "fifo"),
        ("liquidations_first", "reverse"),
        ("scheduled_closes_first", "reverse"),
    ):
        if priority == "liquidations_first" and order == "fifo":
            ordering_result = replay_scenarios["momentum_80_20"]
        else:
            ordering_result = run_historical_replay(
                observations,
                cap=2.0,
                momentum_share=0.80,
                settlement_priority=priority,
                account_order=order,
            )
        ordering_sensitivity.append(
            ordering_summary(priority, order, ordering_result)
        )

    replay_cap_sensitivity = [
        {
            "cap": replay_cap,
            "result": run_historical_replay(
                observations,
                cap=replay_cap,
                momentum_share=0.80,
            ),
        }
        for replay_cap in (1.25, 1.50, 2.00, 2.50, 3.00)
    ]

    claim_route = reserve_fresh_payout(
        18_000_000 * USDC,
        15_000_000 * USDC,
        5_000_000 * USDC,
    )
    underwater_close = close_settlement_result(
        300_000 * USDC,
        804_320 * USDC,
        4_320 * USDC,
        0,
    )
    liquidation_state = build_liquidation_state(
        2_000_000 * SIZE,
        PRICE,
        30_000 * USDC,
        15_000 * USDC,
        100,
        1 * USDC,
        10,
    )
    liquidation_result = liquidation_settlement_for_state(liquidation_state)
    frozen_close = close_settlement_result(
        5_000 * USDC,
        12_800 * USDC,
        800 * USDC,
        10_000 * USDC,
    )
    frozen_uncollected_fee = (
        800 * USDC
        - frozen_close.collected_exec_fee_usdc
        - frozen_close.retained_exec_fee_usdc
    )
    frozen_spread_waived = (
        frozen_close.shortfall_usdc
        - frozen_uncollected_fee
        - frozen_close.bad_debt_usdc
    )
    frozen_spread_paid = 10_000 * USDC - frozen_spread_waived

    values = [observation.basket for observation in observations]
    minimum = min(observations, key=lambda item: item.basket)
    maximum = max(observations, key=lambda item: item.basket)

    result = {
        "model_version": "1.3.0",
        "data": {
            "source": "ECB Data Portal, EXR daily reference rates",
            "url": ECB_DATA_URL,
            "raw_sha256": raw_sha256,
            "expected_sha256_at_publication": EXPECTED_ECB_SHA256,
            "start_date": observations[0].date,
            "end_date": observations[-1].date,
            "complete_observations": len(observations),
            "method": (
                "ECB currency-per-EUR rates are crossed through USD, then passed "
                "through Plether's normalized linear weights and deployment bases."
            ),
            "limitation": (
                "Daily information-only reference rates are a research proxy, not "
                "Pyth execution ticks or tradable weekend close/reopen prices."
            ),
        },
        "basket": {
            "weights": BASKET_WEIGHTS,
            "base_usd_prices": BASKET_BASE_USD,
            "mean": statistics.mean(values),
            "minimum": {"date": minimum.date, "value": minimum.basket},
            "maximum": {"date": maximum.date, "value": maximum.basket},
            "last": {
                "date": observations[-1].date,
                "value": observations[-1].basket,
            },
            "protocol_cap": 2.0,
            "observed_maximum_as_fraction_of_cap": maximum.basket / 2.0,
            "maximum_drawdown": _max_drawdown(observations),
            "max_forward_reserve_utilization": {
                "long": _max_forward_reserve_utilization(observations, "LONG"),
                "short": _max_forward_reserve_utilization(observations, "SHORT"),
            },
        },
        "intervals": {
            "all": interval_stats(intervals),
            "nonpublication_gaps_at_least_3_days": interval_stats(
                nonpublication_gaps
            ),
            "friday_to_monday": interval_stats(friday_monday),
            "move_threshold_counts": {
                "definition": (
                    "Count of absolute reference-rate changes greater than the "
                    "stated threshold; this is not a liquidation test and ignores "
                    "starting equity, intraday liquidation, fees, "
                    "carry, VPI, confidence adjustments, and other collateral."
                ),
                "counts": margin_thresholds,
            },
        },
        "stylized_cap_sensitivity": {
            "assumptions": {
                "pool_assets_usd": pool_assets,
                "entry_price": entry,
                "long_size_units": long_size,
                "short_size_units": short_size,
            },
            "results": cap_sensitivity,
        },
        "stylized_carry": {
            "assumptions": {
                "pool_assets_usd": 100_000_000,
                "base_carry_bps_at_full_utilization": 500,
                "long_max_profit_usd": 40_000_000,
                "long_margin_usd": 4_000_000,
                "short_max_profit_usd": 25_000_000,
                "short_margin_usd": 2_500_000,
            },
            "long": {
                "borrow_base_usd": long_borrow_6 / USDC,
                "utilization_bps": long_util_bps,
                "annualized_rate_bps": compute_utilized_carry_rate_bps(
                    500, long_util_bps
                ),
                "economic_annualized_rate_bps": (
                    500 * long_util_bps / UTILIZATION_BPS
                ),
                "one_year_carry_usd": compute_indexed_carry(
                    long_borrow_6, long_index
                )
                / USDC,
            },
            "short": {
                "borrow_base_usd": short_borrow_6 / USDC,
                "utilization_bps": short_util_bps,
                "annualized_rate_bps": compute_utilized_carry_rate_bps(
                    500, short_util_bps
                ),
                "economic_annualized_rate_bps": (
                    500 * short_util_bps / UTILIZATION_BPS
                ),
                "one_year_carry_usd": compute_indexed_carry(
                    short_borrow_6, short_index
                )
                / USDC,
            },
        },
        "stylized_waterfall": {
            "initial": waterfall_initial,
            "maximum_observed_friday_monday_price_pnl_stress_usd": (
                historical_gap_loss_6 / USDC
            ),
            "after_maximum_observed_friday_monday_stress": waterfall_after_gap,
            "after_60m_stress": waterfall_after_60m_stress,
            "qualification": (
                "Assumes a fully utilized one-sided book, instantaneous price-PnL "
                "settlement, no trader margin recovery, and no fees or carry."
            ),
        },
        "historical_replays": {
            "methodology": (
                "Deterministic monthly cohort replay using quantized prices, "
                "rational/integer admission scaling, and exact integer "
                "accounting kernels over daily ECB fixes. Signals are lagged "
                "one fix, the 40% final-skew wall is enforced on paired "
                "cohorts, and both a realized-cash waterfall overlay and a "
                "daily conservative-MtM reconcile shadow are reported. This "
                "is a stylized scenario model, not a Pyth tick or transaction "
                "replay."
            ),
            "scenarios": replay_scenarios,
            "cap_sensitivity_momentum_80_20": replay_cap_sensitivity,
            "ordering_sensitivity_momentum_80_20": ordering_sensitivity,
        },
        "fixed_examples": {
            "vpi": {
                "depth_usd": 100_000_000,
                "factor": 0.005,
                "pre_skew_usd": 10_000_000,
                "post_skew_usd": 30_000_000,
                "charge_usd": calculate_vpi(
                    10_000_000 * USDC,
                    30_000_000 * USDC,
                    100_000_000 * USDC,
                    5 * 10**15,
                )
                / USDC,
            },
            "solvency_boundary": build_solvency_state(
                60_000_000 * USDC, 55_000_000 * USDC, 5_000_000 * USDC
            ),
            "claim_creation": {
                "physical_assets_usd": 18_000_000,
                "preexisting_trader_claims_usd": 15_000_000,
                "new_profitable_close_usd": 5_000_000,
                "cash_available_after_claim_reservation_usd": (
                    claim_route.available_cash_usdc / USDC
                ),
                "immediate_payout_usd": (
                    claim_route.immediate_payout_usdc / USDC
                ),
                "claim_created_usd": claim_route.claim_created_usdc / USDC,
                "result": (
                    "The full 5m close credit becomes a new trader claim because "
                    "fresh payouts are all-or-nothing."
                ),
            },
            "underwater_full_close": {
                "closed_notional_usd": 10_800_000,
                "execution_fee_bps": 4,
                "base_price_loss_usd": 800_000,
                "execution_fee_usd": 4_320,
                "reachable_collateral_usd": 300_000,
                "settlement": underwater_close,
                "qualification": (
                    "Execution fee is collected first; remaining seizure covers "
                    "base loss. Frozen spread is zero."
                ),
            },
            "liquidation": {
                "current_notional_usd": 2_000_000,
                "reachable_collateral_usd": 30_000,
                "pre_bounty_equity_usd": 15_000,
                "maintenance_margin_bps": 100,
                "bounty_bps": 10,
                "state": liquidation_state,
                "settlement": liquidation_result,
            },
            "frozen_terminal_close": {
                "current_notional_usd": 2_000_000,
                "base_price_loss_usd": 2_000,
                "execution_fee_usd": 800,
                "frozen_spread_bps": 50,
                "frozen_spread_assessed_usd": 10_000,
                "reachable_collateral_usd": 5_000,
                "settlement": frozen_close,
                "frozen_spread_paid_usd": frozen_spread_paid / USDC,
                "frozen_spread_waived_usd": frozen_spread_waived / USDC,
            },
            "conservation_identities": {
                "underwater_close_owed_equals_seized_plus_shortfall": (
                    underwater_close.seized_usdc
                    + underwater_close.shortfall_usdc
                    == 804_320 * USDC
                ),
                "liquidation_reachable_equals_bounty_retained_plus_seized": (
                    liquidation_state.reachable_collateral_usdc
                    == liquidation_state.keeper_bounty_usdc
                    + liquidation_result.settlement_retained_usdc
                    + liquidation_result.settlement_seized_usdc
                ),
                "frozen_spread_assessed_equals_paid_plus_waived": (
                    10_000 * USDC
                    == frozen_spread_paid + frozen_spread_waived
                ),
            },
        },
    }
    return _serialize(result)  # type: ignore[return-value]


def write_derived_csv(
    observations: Sequence[BasketObservation],
    destination: Path,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "date",
                "basket",
                "eur_usd",
                "jpy_usd",
                "gbp_usd",
                "cad_usd",
                "sek_usd",
                "chf_usd",
            ]
        )
        for observation in observations:
            writer.writerow(
                [
                    observation.date.isoformat(),
                    f"{observation.basket:.12f}",
                    f"{observation.eur_usd:.12f}",
                    f"{observation.jpy_usd:.12f}",
                    f"{observation.gbp_usd:.12f}",
                    f"{observation.cad_usd:.12f}",
                    f"{observation.sek_usd:.12f}",
                    f"{observation.chf_usd:.12f}",
                ]
            )


def _svg_header(width: int, height: int, title: str, description: str) -> list[str]:
    return [
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
            f'height="{height}" viewBox="0 0 {width} {height}" role="img" '
            f'aria-labelledby="title desc">'
        ),
        f"<title id=\"title\">{escape(title)}</title>",
        f"<desc id=\"desc\">{escape(description)}</desc>",
        "<style>",
        "text{font-family:'Times New Roman',Times,serif;fill:#111111}",
        ".axis{stroke:#444444;stroke-width:1}",
        ".grid{stroke:#dddddd;stroke-width:1}",
        ".label{font-size:12px}",
        ".small{font-size:10px;fill:#555555}",
        ".title{font-size:18px;font-weight:700}",
        "</style>",
        '<rect width="100%" height="100%" fill="#ffffff"/>',
    ]


def write_basket_history_svg(
    observations: Sequence[BasketObservation],
    destination: Path,
) -> None:
    width, height = 960, 430
    left, right, top, bottom = 72, 24, 52, 58
    plot_w, plot_h = width - left - right, height - top - bottom
    y_min = min(item.basket for item in observations) - 0.02
    y_max = max(item.basket for item in observations) + 0.02
    start_ord = observations[0].date.toordinal()
    end_ord = observations[-1].date.toordinal()

    def x_for(date: dt.date) -> float:
        return left + (date.toordinal() - start_ord) / (end_ord - start_ord) * plot_w

    def y_for(value: float) -> float:
        return top + (y_max - value) / (y_max - y_min) * plot_h

    lines = _svg_header(
        width,
        height,
        "Plether Labs basket history",
        "Daily normalized Plether basket reconstructed from ECB reference rates.",
    )
    lines.append(
        '<text x="72" y="29" class="title">Plether six-FX basket, 2016-2026</text>'
    )
    for value in (0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15):
        if y_min <= value <= y_max:
            y = y_for(value)
            lines.append(
                f'<line x1="{left}" y1="{y:.2f}" x2="{left + plot_w}" '
                f'y2="{y:.2f}" class="grid"/>'
            )
            lines.append(
                f'<text x="{left - 10}" y="{y + 4:.2f}" '
                f'text-anchor="end" class="label">{value:.2f}</text>'
            )
    for year in range(2016, 2027, 2):
        date = dt.date(year, 1, 1)
        x = x_for(max(observations[0].date, min(date, observations[-1].date)))
        lines.append(
            f'<line x1="{x:.2f}" y1="{top}" x2="{x:.2f}" '
            f'y2="{top + plot_h}" class="grid"/>'
        )
        lines.append(
            f'<text x="{x:.2f}" y="{top + plot_h + 22}" '
            f'text-anchor="middle" class="label">{year}</text>'
        )
    points = " ".join(
        f"{x_for(item.date):.2f},{y_for(item.basket):.2f}" for item in observations
    )
    lines.extend(
        [
            f'<line x1="{left}" y1="{top + plot_h}" x2="{left + plot_w}" '
            f'y2="{top + plot_h}" class="axis"/>',
            f'<line x1="{left}" y1="{top}" x2="{left}" '
            f'y2="{top + plot_h}" class="axis"/>',
            (
                f'<polyline points="{points}" fill="none" stroke="#111111" '
                'stroke-width="1.8" stroke-linejoin="round"/>'
            ),
            (
                '<text x="72" y="410" class="small">'
                "Source: ECB daily information-only reference rates. "
                "Protocol cap = 2.00 (outside plotted range)."
                "</text>"
            ),
            "</svg>",
        ]
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(lines), encoding="utf-8")


def write_gap_chart_svg(
    observations: Sequence[BasketObservation],
    destination: Path,
) -> None:
    intervals = [
        item
        for item in _intervals(observations)
        if int(item["calendar_days"]) >= 3
    ]
    top_items = sorted(
        intervals, key=lambda item: abs(float(item["return"])), reverse=True
    )[:10]
    width, height = 960, 460
    left, right, top, bottom = 104, 34, 54, 118
    plot_w, plot_h = width - left - right, height - top - bottom
    max_value = max(abs(float(item["return"])) for item in top_items) * 10_000
    bar_gap = plot_w / len(top_items)
    bar_width = bar_gap * 0.62
    lines = _svg_header(
        width,
        height,
        "Largest ECB nonpublication-gap changes",
        "Ten largest absolute normalized basket moves across observation "
        "gaps of at least three calendar days.",
    )
    lines.append(
        '<text x="72" y="29" class="title">Largest reference-rate changes across 3+ day gaps</text>'
    )
    for bps in range(0, math.ceil(max_value / 50) * 50 + 1, 50):
        y = top + plot_h - (bps / max_value) * plot_h
        lines.append(
            f'<line x1="{left}" y1="{y:.2f}" x2="{left + plot_w}" '
            f'y2="{y:.2f}" class="grid"/>'
        )
        lines.append(
            f'<text x="{left - 10}" y="{y + 4:.2f}" '
            f'text-anchor="end" class="label">{bps}</text>'
        )
    for index, item in enumerate(top_items):
        bps = float(item["return"]) * 10_000
        magnitude = abs(bps)
        x = left + index * bar_gap + (bar_gap - bar_width) / 2
        y = top + plot_h - magnitude / max_value * plot_h
        color = "#555555" if bps >= 0 else "#bbbbbb"
        label = f"{item['from'].isoformat()} to {item['to'].isoformat()}"
        lines.append(
            f'<rect x="{x:.2f}" y="{y:.2f}" width="{bar_width:.2f}" '
            f'height="{top + plot_h - y:.2f}" fill="{color}" '
            'stroke="#222222" stroke-width="0.5"/>'
        )
        lines.append(
            f'<text x="{x + bar_width / 2:.2f}" y="{y - 7:.2f}" '
            f'text-anchor="middle" class="small">{bps:+.0f}</text>'
        )
        lines.append(
            f'<text x="{x + bar_width / 2:.2f}" y="{top + plot_h + 15}" '
            f'text-anchor="end" transform="rotate(-50 '
            f'{x + bar_width / 2:.2f} {top + plot_h + 15})" '
            f'class="small">{escape(label)}</text>'
        )
    lines.extend(
        [
            f'<line x1="{left}" y1="{top + plot_h}" x2="{left + plot_w}" '
            f'y2="{top + plot_h}" class="axis"/>',
            (
                '<text x="104" y="448" class="small">'
                "Basis points; dark grey = basket rose, light grey = basket fell. "
                "These are reference-fix changes, not executable weekend gaps."
                "</text>"
            ),
            "</svg>",
        ]
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(lines), encoding="utf-8")


def write_cap_sensitivity_svg(
    analysis: dict[str, object],
    destination: Path,
) -> None:
    rows = analysis["stylized_cap_sensitivity"]["results"]  # type: ignore[index]
    width, height = 960, 420
    left, right, top, bottom = 78, 28, 56, 64
    plot_w, plot_h = width - left - right, height - top - bottom
    caps = [float(row["cap"]) for row in rows]  # type: ignore[index]
    values = [
        float(row["pool_reserve_utilization"]) * 100 for row in rows  # type: ignore[index]
    ]
    cap_min, cap_max = min(caps), max(caps)
    y_max = 100.0

    def x_for(value: float) -> float:
        return left + (value - cap_min) / (cap_max - cap_min) * plot_w

    def y_for(value: float) -> float:
        return top + (y_max - value) / y_max * plot_h

    lines = _svg_header(
        width,
        height,
        "Cap sensitivity of the common-mark liability envelope",
        "Stylized maximum endpoint liability as a percentage of a 100 million dollar pool.",
    )
    lines.append(
        '<text x="72" y="29" class="title">'
        "Cap sensitivity depends on directional open interest</text>"
    )
    for pct in range(0, 101, 20):
        y = y_for(float(pct))
        lines.append(
            f'<line x1="{left}" y1="{y:.2f}" x2="{left + plot_w}" '
            f'y2="{y:.2f}" class="grid"/>'
        )
        lines.append(
            f'<text x="{left - 10}" y="{y + 4:.2f}" '
            f'text-anchor="end" class="label">{pct}%</text>'
        )
    for cap in caps:
        x = x_for(cap)
        lines.append(
            f'<text x="{x:.2f}" y="{top + plot_h + 22}" '
            f'text-anchor="middle" class="label">{cap:.2f}</text>'
        )
    points = " ".join(
        f"{x_for(cap):.2f},{y_for(value):.2f}"
        for cap, value in zip(caps, values)
    )
    lines.append(
        f'<polyline points="{points}" fill="none" stroke="#111111" '
        'stroke-width="2" stroke-linejoin="round"/>'
    )
    for cap, value in zip(caps, values):
        lines.append(
            f'<circle cx="{x_for(cap):.2f}" cy="{y_for(value):.2f}" '
            'r="4" fill="#111111"/>'
        )
    lines.extend(
        [
            f'<line x1="{left}" y1="{top + plot_h}" x2="{left + plot_w}" '
            f'y2="{top + plot_h}" class="axis"/>',
            (
                '<text x="78" y="407" class="small">'
                "Assumptions: pool $100m; entry 1.00; Short size 50m; "
                "Long size 30m. Envelope = max(30m, 50m x (cap - 1))."
                "</text>"
            ),
            "</svg>",
        ]
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(lines), encoding="utf-8")


def write_replay_summary_svg(
    analysis: dict[str, object],
    destination: Path,
) -> None:
    replay = analysis["historical_replays"]  # type: ignore[index]
    scenarios = replay["scenarios"]  # type: ignore[index]
    ordered = [
        ("balanced_50_50", "Balanced"),
        ("momentum_80_20", "Momentum 80/20"),
        ("momentum_100_0", "Momentum 100/0"),
    ]
    ending_equity = [
        float(
            scenarios[key]["ending_balance_sheet"]["lp_economic_equity_usd"]  # type: ignore[index]
        )
        / 1_000_000
        for key, _ in ordered
    ]
    realized_carry = [
        float(scenarios[key]["carry"]["conservatively_realized_usd"])  # type: ignore[index]
        / 1_000_000
        for key, _ in ordered
    ]
    cap_rows = replay["cap_sensitivity_momentum_80_20"]  # type: ignore[index]
    caps = [float(item["cap"]) for item in cap_rows]  # type: ignore[index]
    reserve_utilization = [
        float(
            item["result"]["book"]["time_weighted_endpoint_reserve_utilization"]  # type: ignore[index]
        )
        * 100
        for item in cap_rows
    ]

    width, height = 1200, 430
    lines = _svg_header(
        width,
        height,
        "Historical cohort replay summary",
        "Ending LP equity, conservatively realized carry, and cap-sensitive "
        "reserve utilization in the stylized ECB replay.",
    )
    lines.append(
        '<text x="50" y="30" class="title">'
        "Stylized historical replay: capital, carry, and cap sensitivity</text>"
    )

    panel_lefts = [55, 430, 805]
    panel_width = 320
    plot_top = 78
    plot_height = 245
    labels = [label for _, label in ordered]
    colors_by_bar = ["#333333", "#777777", "#B0B0B0"]

    def draw_bar_panel(
        x0: int,
        title: str,
        values: Sequence[float],
        y_max: float,
        suffix: str,
        baseline: float | None = None,
    ) -> None:
        lines.append(
            f'<text x="{x0}" y="58" class="label" font-weight="700">{escape(title)}</text>'
        )
        for step in range(0, 5):
            value = y_max * step / 4
            y = plot_top + plot_height - value / y_max * plot_height
            lines.append(
                f'<line x1="{x0}" y1="{y:.2f}" x2="{x0 + panel_width}" '
                f'y2="{y:.2f}" class="grid"/>'
            )
            lines.append(
                f'<text x="{x0 - 7}" y="{y + 4:.2f}" text-anchor="end" '
                f'class="small">{value:.0f}</text>'
            )
        if baseline is not None:
            y = plot_top + plot_height - baseline / y_max * plot_height
            lines.append(
                f'<line x1="{x0}" y1="{y:.2f}" x2="{x0 + panel_width}" '
                f'y2="{y:.2f}" stroke="#666666" stroke-width="1.2" '
                'stroke-dasharray="5 4"/>'
            )
        slot = panel_width / len(values)
        bar_width = slot * 0.52
        for index, (label, value) in enumerate(zip(labels, values)):
            x = x0 + index * slot + (slot - bar_width) / 2
            y = plot_top + plot_height - value / y_max * plot_height
            lines.append(
                f'<rect x="{x:.2f}" y="{y:.2f}" width="{bar_width:.2f}" '
                f'height="{plot_top + plot_height - y:.2f}" '
                f'fill="{colors_by_bar[index]}" stroke="#222222" '
                'stroke-width="0.5"/>'
            )
            lines.append(
                f'<text x="{x + bar_width / 2:.2f}" y="{y - 7:.2f}" '
                f'text-anchor="middle" class="small">{value:.1f}{suffix}</text>'
            )
            lines.append(
                f'<text x="{x + bar_width / 2:.2f}" y="{plot_top + plot_height + 18}" '
                f'text-anchor="middle" class="small">{escape(label)}</text>'
            )

    draw_bar_panel(
        panel_lefts[0],
        "Ending LP economic equity ($m)",
        ending_equity,
        125,
        "",
        baseline=100,
    )
    draw_bar_panel(
        panel_lefts[1],
        "Conservatively realized carry ($m)",
        realized_carry,
        25,
        "",
    )

    x0 = panel_lefts[2]
    lines.append(
        f'<text x="{x0}" y="58" class="label" font-weight="700">'
        "Time-weighted endpoint reserve utilization</text>"
    )
    for pct in (0, 15, 30, 45, 60):
        y = plot_top + plot_height - pct / 60 * plot_height
        lines.append(
            f'<line x1="{x0}" y1="{y:.2f}" x2="{x0 + panel_width}" '
            f'y2="{y:.2f}" class="grid"/>'
        )
        lines.append(
            f'<text x="{x0 - 7}" y="{y + 4:.2f}" text-anchor="end" '
            f'class="small">{pct}%</text>'
        )
    cap_min, cap_max = min(caps), max(caps)
    points = []
    for cap, utilization in zip(caps, reserve_utilization):
        x = x0 + (cap - cap_min) / (cap_max - cap_min) * panel_width
        y = plot_top + plot_height - utilization / 60 * plot_height
        points.append(f"{x:.2f},{y:.2f}")
        lines.append(
            f'<circle cx="{x:.2f}" cy="{y:.2f}" r="4" fill="#111111"/>'
        )
        lines.append(
            f'<text x="{x:.2f}" y="{y - 8:.2f}" text-anchor="middle" '
            f'class="small">{utilization:.1f}%</text>'
        )
        lines.append(
            f'<text x="{x:.2f}" y="{plot_top + plot_height + 18}" '
            f'text-anchor="middle" class="small">C={cap:g}</text>'
        )
    lines.append(
        f'<polyline points="{" ".join(points)}" fill="none" '
        'stroke="#111111" stroke-width="2"/>'
    )
    lines.extend(
        [
            (
                '<text x="55" y="394" class="small">'
                "Monthly 63-day cohorts; $100m initial pool; 1.5% initial / "
                "1% maintenance margin; 5% full-utilization carry; ECB daily fixes."
                "</text>"
            ),
            (
                '<text x="55" y="412" class="small">'
                "Scenario evidence only: VPI, Pyth confidence, frozen execution, "
                "intraday paths, and keeper latency are held outside the replay."
                "</text>"
            ),
            "</svg>",
        ]
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(lines), encoding="utf-8")


def run_analysis(csv_path: Path, output_dir: Path) -> dict[str, object]:
    raw_sha256 = sha256_file(csv_path)
    observations = load_ecb_basket(csv_path)
    analysis = build_analysis(observations, raw_sha256)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "results.json").write_text(
        json.dumps(analysis, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    write_derived_csv(observations, output_dir / "ecb_plether_basket.csv")
    write_basket_history_svg(observations, output_dir / "basket_history.svg")
    write_gap_chart_svg(observations, output_dir / "nonpublication_gaps.svg")
    write_cap_sensitivity_svg(analysis, output_dir / "cap_sensitivity.svg")
    write_replay_summary_svg(analysis, output_dir / "replay_summary.svg")
    return analysis


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ecb-csv",
        type=Path,
        help="Raw ECB csvdata file. If omitted, --fetch is required.",
    )
    parser.add_argument(
        "--fetch",
        action="store_true",
        help="Fetch the fixed ECB dataset before analysis.",
    )
    parser.add_argument(
        "--raw-cache",
        type=Path,
        default=Path("/tmp/plether_ecb_fx.csv"),
        help="Raw ECB download path used with --fetch.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "generated",
        help="Directory for results, derived data, and SVG figures.",
    )
    parser.add_argument(
        "--allow-checksum-mismatch",
        action="store_true",
        help="Continue if ECB has revised the fixed-window response.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    csv_path = args.ecb_csv
    if args.fetch:
        csv_path = args.raw_cache
        fetch_ecb_data(csv_path)
    if csv_path is None:
        raise SystemExit("provide --ecb-csv PATH or --fetch")

    actual_sha256 = sha256_file(csv_path)
    if (
        actual_sha256 != EXPECTED_ECB_SHA256
        and not args.allow_checksum_mismatch
    ):
        raise SystemExit(
            "ECB response checksum differs from the paper snapshot: "
            f"expected {EXPECTED_ECB_SHA256}, got {actual_sha256}. "
            "Review upstream revisions, then pass --allow-checksum-mismatch "
            "if the change is understood."
        )

    analysis = run_analysis(csv_path, args.output_dir)
    print(
        json.dumps(
            {
                "output_dir": str(args.output_dir),
                "observations": analysis["data"]["complete_observations"],  # type: ignore[index]
                "raw_sha256": actual_sha256,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
