#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0

import datetime as dt
import json
import random
import re
import unittest
from pathlib import Path

import bounded_perps_model as model


class SolidityKernelVectorTests(unittest.TestCase):
    def test_pnl_and_max_profit(self) -> None:
        size = 100_000 * model.SIZE
        is_profit, pnl = model.calculate_pnl(
            size, 1 * model.PRICE, 98_000_000, "SHORT"
        )
        self.assertTrue(is_profit)
        self.assertEqual(pnl, 2_000 * model.USDC)
        self.assertEqual(
            model.calculate_max_profit(size, model.PRICE, "SHORT"),
            100_000 * model.USDC,
        )
        self.assertEqual(
            model.calculate_max_profit(size, model.PRICE, "LONG"),
            100_000 * model.USDC,
        )

    def test_price_clamps_to_cap(self) -> None:
        size = 100_000 * model.SIZE
        _, capped = model.calculate_pnl(
            size, model.PRICE, model.CAP_PRICE_8, "LONG"
        )
        _, over_cap = model.calculate_pnl(
            size, model.PRICE, 5 * model.PRICE, "LONG"
        )
        self.assertEqual(capped, over_cap)

    def test_vpi_vector_and_reverse_path(self) -> None:
        depth = 100_000_000 * model.USDC
        low_skew = 10_000_000 * model.USDC
        high_skew = 30_000_000 * model.USDC
        factor = 5 * 10**15
        charge = model.calculate_vpi(low_skew, high_skew, depth, factor)
        rebate = model.calculate_vpi(high_skew, low_skew, depth, factor)
        self.assertEqual(charge, 20_000 * model.USDC)
        self.assertEqual(rebate, -charge)

    def test_floor_rounded_vpi_potential_still_telescopes(self) -> None:
        depth = 97_000_003 * model.USDC
        factor = 7_123_456_789_012_345
        path = [
            1_000_001 * model.USDC,
            8_765_432 * model.USDC,
            3_333_337 * model.USDC,
            15_000_019 * model.USDC,
        ]
        path_sum = sum(
            model.calculate_vpi(before, after, depth, factor)
            for before, after in zip(path, path[1:])
        )
        direct = model.calculate_vpi(path[0], path[-1], depth, factor)
        self.assertEqual(path_sum, direct)

    def test_full_utilization_carry_index(self) -> None:
        index = model.compute_current_carry_index(
            0,
            0,
            model.SECONDS_PER_YEAR,
            100_000_000 * model.USDC,
            100_000_000 * model.USDC,
            500,
        )
        self.assertEqual(index, 5 * 10**16)
        carry = model.compute_indexed_carry(90_000 * model.USDC, index)
        self.assertEqual(carry, 4_500 * model.USDC)

    def test_solvency_and_withdrawal_are_different_questions(self) -> None:
        state = model.build_solvency_state(
            60_000_000 * model.USDC,
            55_000_000 * model.USDC,
            5_000_000 * model.USDC,
        )
        self.assertEqual(state.effective_assets_usdc, 55_000_000 * model.USDC)
        self.assertEqual(state.free_withdrawable_usdc, 0)

    def test_conservative_mtm_rounds_up(self) -> None:
        self.assertEqual(
            model.conservative_mtm_liability(1, "SHORT", model.PRICE),
            1,
        )
        self.assertEqual(
            model.conservative_mtm_liability(
                10_000 * model.USDC,
                "LONG",
                model.PRICE,
            ),
            5_000 * model.USDC,
        )

    def test_close_collection_and_claim_priority_vectors(self) -> None:
        result = model.close_settlement_result(
            300_000 * model.USDC,
            804_320 * model.USDC,
            4_320 * model.USDC,
            0,
        )
        self.assertEqual(result.seized_usdc, 300_000 * model.USDC)
        self.assertEqual(result.collected_exec_fee_usdc, 4_320 * model.USDC)
        self.assertEqual(result.bad_debt_usdc, 504_320 * model.USDC)

        route = model.reserve_fresh_payout(
            18_000_000 * model.USDC,
            15_000_000 * model.USDC,
            5_000_000 * model.USDC,
        )
        self.assertEqual(route.immediate_payout_usdc, 0)
        self.assertEqual(route.claim_created_usdc, 5_000_000 * model.USDC)

    def test_frozen_spread_is_junior_and_waivable(self) -> None:
        result = model.close_settlement_result(
            5_000 * model.USDC,
            12_800 * model.USDC,
            800 * model.USDC,
            10_000 * model.USDC,
        )
        uncollected_fee = (
            800 * model.USDC
            - result.collected_exec_fee_usdc
            - result.retained_exec_fee_usdc
        )
        waived_spread = (
            result.shortfall_usdc - uncollected_fee - result.bad_debt_usdc
        )
        paid_spread = 10_000 * model.USDC - waived_spread
        self.assertEqual(result.bad_debt_usdc, 0)
        self.assertEqual(paid_spread, 2_200 * model.USDC)
        self.assertEqual(waived_spread, 7_800 * model.USDC)

    def test_liquidation_bounty_retention_and_seizure(self) -> None:
        state = model.build_liquidation_state(
            2_000_000 * model.SIZE,
            model.PRICE,
            30_000 * model.USDC,
            15_000 * model.USDC,
            100,
            1 * model.USDC,
            10,
        )
        result = model.liquidation_settlement_for_state(state)
        self.assertEqual(state.maintenance_margin_usdc, 20_000 * model.USDC)
        self.assertEqual(state.keeper_bounty_usdc, 2_000 * model.USDC)
        self.assertEqual(result.settlement_retained_usdc, 13_000 * model.USDC)
        self.assertEqual(result.settlement_seized_usdc, 15_000 * model.USDC)
        self.assertEqual(result.bad_debt_usdc, 0)

    def test_post_operation_degraded_latch_preview(self) -> None:
        current = model.build_solvency_state(
            10_000 * model.USDC,
            9_000 * model.USDC,
            0,
        )
        preview = model.preview_post_op_solvency(
            current,
            -2_000 * model.USDC,
            9_000 * model.USDC,
            0,
            0,
            False,
        )
        self.assertTrue(preview.triggers_degraded_mode)
        self.assertTrue(preview.post_op_degraded_mode)

    def test_senior_coupon_vector(self) -> None:
        start = model.WaterfallState(
            50_000_000 * model.USDC,
            10_000_000 * model.USDC,
            50_000_000 * model.USDC,
        )
        after, paid = model.pay_senior_coupon(
            start, 800, model.SECONDS_PER_YEAR
        )
        self.assertEqual(paid, 4_000_000 * model.USDC)
        self.assertEqual(after.senior_principal_usdc, 54_000_000 * model.USDC)
        self.assertEqual(after.junior_principal_usdc, 6_000_000 * model.USDC)
        self.assertEqual(
            after.senior_high_water_mark_usdc,
            54_000_000 * model.USDC,
        )

    def test_multi_increase_weighted_entry_can_exceed_stored_max_by_dust(
        self,
    ) -> None:
        size_delta = 100 * model.SIZE
        first_price = 90_000_000
        second_price = 90_000_001
        combined_entry = model.weighted_entry_price(
            size_delta,
            first_price,
            size_delta,
            second_price,
        )
        stored_max_profit = model.calculate_max_profit(
            size_delta,
            first_price,
            "LONG",
        ) + model.calculate_max_profit(
            size_delta,
            second_price,
            "LONG",
        )
        _, endpoint_pnl = model.calculate_pnl(
            2 * size_delta,
            combined_entry,
            model.CAP_PRICE_8,
            "LONG",
        )
        self.assertEqual(combined_entry, first_price)
        self.assertEqual(endpoint_pnl - stored_max_profit, 1)

    def test_carry_attribution_does_not_credit_unrecovered_shortfall(
        self,
    ) -> None:
        self.assertEqual(
            model.conservatively_realized_carry(
                1_000 * model.USDC,
                100 * model.USDC,
                200 * model.USDC,
            ),
            300 * model.USDC,
        )
        self.assertEqual(
            model.conservatively_realized_carry(
                1_000 * model.USDC,
                -400 * model.USDC,
                650 * model.USDC,
            ),
            250 * model.USDC,
        )

    def test_claims_require_a_strictly_later_observation(self) -> None:
        created = dt.date(2026, 1, 2)
        claims = [
            model.ReplayClaim(1, created, 100 * model.USDC),
        ]
        self.assertFalse(
            model.aggregate_claims_serviceable(
                claims,
                created,
                100 * model.USDC,
                100 * model.USDC,
            )
        )
        self.assertTrue(
            model.aggregate_claims_serviceable(
                claims,
                created + dt.timedelta(days=1),
                100 * model.USDC,
                100 * model.USDC,
            )
        )

    def test_waterfall_is_junior_first_and_restores_senior_first(self) -> None:
        start = model.WaterfallState(
            60_000_000 * model.USDC,
            40_000_000 * model.USDC,
            60_000_000 * model.USDC,
        )
        impaired = model.absorb_loss(start, 50_000_000 * model.USDC)
        self.assertEqual(impaired.senior_principal_usdc, 50_000_000 * model.USDC)
        self.assertEqual(impaired.junior_principal_usdc, 0)
        self.assertEqual(
            impaired.senior_high_water_mark_usdc, 60_000_000 * model.USDC
        )
        recovered = model.distribute_revenue(
            impaired, 25_000_000 * model.USDC
        )
        self.assertEqual(recovered.senior_principal_usdc, 60_000_000 * model.USDC)
        self.assertEqual(recovered.junior_principal_usdc, 15_000_000 * model.USDC)


class LiabilityEnvelopeTests(unittest.TestCase):
    def test_common_mark_gross_positive_pnl_is_endpoint_bounded(self) -> None:
        rng = random.Random(0xB0A1DED)
        cap = 2.0
        for _ in range(500):
            shorts = [
                (rng.uniform(0.1, 10.0), rng.uniform(0.0, cap))
                for _ in range(rng.randint(0, 12))
            ]
            longs = [
                (rng.uniform(0.1, 10.0), rng.uniform(0.0, cap))
                for _ in range(rng.randint(0, 12))
            ]
            short_endpoint = sum(size * entry for size, entry in shorts)
            long_endpoint = sum(size * (cap - entry) for size, entry in longs)
            envelope = max(short_endpoint, long_endpoint)
            for point in range(101):
                price = cap * point / 100
                gross_positive_pnl = sum(
                    size * max(entry - price, 0.0) for size, entry in shorts
                ) + sum(
                    size * max(price - entry, 0.0) for size, entry in longs
                )
                self.assertLessEqual(gross_positive_pnl, envelope + 1e-9)

    def test_integer_common_mark_envelope_matches_stored_aggregates(self) -> None:
        rng = random.Random(0x1A70)
        cap_price = model.CAP_PRICE_8
        for _ in range(200):
            positions = []
            short_endpoint = 0
            long_endpoint = 0
            for _ in range(rng.randint(1, 20)):
                side = rng.choice(("SHORT", "LONG"))
                size = rng.randint(1, 10_000) * model.SIZE
                entry = rng.randint(0, cap_price)
                maximum = model.calculate_max_profit(
                    size, entry, side, cap_price
                )
                positions.append((side, size, entry))
                if side == "SHORT":
                    short_endpoint += maximum
                else:
                    long_endpoint += maximum
            envelope = max(short_endpoint, long_endpoint)
            for _ in range(20):
                price = rng.randint(0, cap_price)
                gross_positive = 0
                for side, size, entry in positions:
                    is_profit, amount = model.calculate_pnl(
                        size, entry, price, side, cap_price
                    )
                    if is_profit:
                        gross_positive += amount
                self.assertLessEqual(gross_positive, envelope)

    def test_common_mark_envelope_is_not_a_pathwise_reserve(self) -> None:
        cap = 2.0
        short_size, short_entry = 1.0, 1.0
        long_size, long_entry = 1.0, 1.0
        envelope = max(
            short_size * short_entry,
            long_size * (cap - long_entry),
        )
        short_closes_at_zero = short_size * (short_entry - 0.0)
        long_closes_later_at_cap = long_size * (cap - long_entry)
        self.assertEqual(envelope, 1.0)
        self.assertEqual(short_closes_at_zero + long_closes_later_at_cap, 2.0)
        self.assertGreater(
            short_closes_at_zero + long_closes_later_at_cap,
            envelope,
        )


class HistoricalReplayTests(unittest.TestCase):
    @staticmethod
    def observation(date: dt.date, basket: float) -> model.BasketObservation:
        return model.BasketObservation(
            date=date,
            basket=basket,
            eur_usd=basket,
            jpy_usd=basket,
            gbp_usd=basket,
            cad_usd=basket,
            sek_usd=basket,
            chf_usd=basket,
        )

    def sample(self) -> list[model.BasketObservation]:
        return [
            self.observation(dt.date(2026, 1, 1), 1.00),
            self.observation(dt.date(2026, 1, 2), 0.90),
            self.observation(dt.date(2026, 2, 2), 1.10),
            self.observation(dt.date(2026, 3, 2), 1.10),
        ]

    def test_sub_one_percent_cohort_scale_is_admitted_and_asserted(
        self,
    ) -> None:
        result = model.run_historical_replay(
            self.sample(),
            momentum_share=0.5,
            initial_pool_usd=100_000,
            cohort_target_notional_usd=90_000_000,
            holding_calendar_days=365,
            signal_lookback_observations=1,
        )
        book = result["book"]
        self.assertEqual(book["admitted_cohorts"], 1)
        self.assertEqual(book["scaled_cohorts"], 1)
        self.assertEqual(book["rejected_cohorts"], 0)
        self.assertEqual(
            book["post_admission_assertions"],
            book["admitted_cohorts"],
        )
        self.assertLess(
            book["admitted_notional_usd"] / 90_000_000,
            0.01,
        )
        self.assertEqual(result["settlement"]["forced_final_closes"], 2)

    def test_signal_is_formed_one_fix_before_entry_and_skew_is_bounded(
        self,
    ) -> None:
        result = model.run_historical_replay(
            self.sample(),
            momentum_share=1.0,
            holding_calendar_days=365,
            signal_lookback_observations=1,
        )
        book = result["book"]
        self.assertGreater(book["admitted_short_notional_usd"], 0)
        self.assertEqual(book["admitted_long_notional_usd"], 0)
        self.assertLessEqual(
            book["maximum_post_admission_skew_ratio"],
            0.40,
        )
        self.assertEqual(result["assumptions"]["signal_execution_lag_observations"], 1)

    def test_replay_is_deterministic_and_ordering_knobs_are_recorded(
        self,
    ) -> None:
        arguments = {
            "momentum_share": 0.8,
            "holding_calendar_days": 365,
            "signal_lookback_observations": 1,
            "settlement_priority": "scheduled_closes_first",
            "account_order": "reverse",
        }
        first = model.run_historical_replay(self.sample(), **arguments)
        second = model.run_historical_replay(self.sample(), **arguments)
        self.assertEqual(first, second)
        self.assertEqual(
            first["assumptions"]["daily_settlement_priority"],
            "scheduled_closes_first",
        )
        self.assertEqual(
            first["assumptions"]["within_class_account_order"],
            "reverse",
        )
        self.assertIn("daily_conservative_reconciliation", first)


class PublicationArtifactTests(unittest.TestCase):
    def test_published_replay_tables_match_generated_results(self) -> None:
        whitepaper_dir = Path(__file__).resolve().parent
        results = json.loads(
            (whitepaper_dir / "generated" / "results.json").read_text(
                encoding="utf-8"
            )
        )
        paper = (whitepaper_dir.parent / "WHITEPAPER.md").read_text(
            encoding="utf-8"
        )
        self.assertEqual(results["model_version"], "1.3.0")
        scenario_keys = (
            "balanced_50_50",
            "momentum_80_20",
            "momentum_100_0",
        )
        scenarios = [
            results["historical_replays"]["scenarios"][key]
            for key in scenario_keys
        ]
        for scenario in scenarios:
            admitted = scenario["book"]["admitted_notional_usd"] / 1e9
            equity = (
                scenario["ending_balance_sheet"]["lp_economic_equity_usd"]
                / 1e6
            )
            bad_debt = scenario["settlement"]["bad_debt_usd"] / 1e6
            self.assertIn(f"${admitted:.3f}bn", paper)
            self.assertIn(f"${equity:.3f}m", paper)
            self.assertIn(f"${bad_debt:.3f}m", paper)

        cohort_cells = [
            (
                f'{scenario["book"]["admitted_cohorts"]} / '
                f'{scenario["book"]["scaled_cohorts"]} / '
                f'{scenario["book"]["rejected_cohorts"]}'
            )
            for scenario in scenarios
        ]
        self.assertIn(
            "| Admitted / scaled / rejected cohorts | "
            + " | ".join(cohort_cells)
            + " |",
            paper,
        )
        self.assertIn(
            "| Time-weighted endpoint reserve utilization | "
            + " | ".join(
                f'{scenario["book"]["time_weighted_endpoint_reserve_utilization"] * 100:.2f}%'
                for scenario in scenarios
            )
            + " |",
            paper,
        )
        self.assertIn(
            "| Liquidations | "
            + " | ".join(
                str(scenario["settlement"]["liquidations"])
                for scenario in scenarios
            )
            + " |",
            paper,
        )
        self.assertIn(
            "| Carry conservatively realized | "
            + " | ".join(
                f'${scenario["carry"]["conservatively_realized_usd"] / 1e6:.3f}m'
                for scenario in scenarios
            )
            + " |",
            paper,
        )
        self.assertIn(
            "| Maximum conservative MtM | "
            + " | ".join(
                f'${scenario["daily_conservative_reconciliation"]["maximum_conservative_mtm_usd"] / 1e6:.3f}m'
                for scenario in scenarios
            )
            + " |",
            paper,
        )
        self.assertIn(
            "| Minimum senior principal | "
            + " | ".join(
                f'${scenario["daily_conservative_reconciliation"]["minimum_senior_principal_usd"] / 1e6:.3f}m'
                for scenario in scenarios
            )
            + " |",
            paper,
        )
        for item in results["historical_replays"][
            "cap_sensitivity_momentum_80_20"
        ]:
            cap = item["cap"]
            result = item["result"]
            expected_row = (
                f"| {cap:.2f} | "
                f'${result["book"]["admitted_notional_usd"] / 1e9:.3f}bn | '
                f'{result["book"]["time_weighted_endpoint_reserve_utilization"] * 100:.2f}% | '
                f'${result["carry"]["conservatively_realized_usd"] / 1e6:.3f}m | '
                f'${result["ending_balance_sheet"]["lp_economic_equity_usd"] / 1e6:.3f}m | '
                f'${result["settlement"]["bad_debt_usd"] / 1e6:.3f}m |'
            )
            self.assertIn(expected_row, paper)
        self.assertIn(results["data"]["raw_sha256"], paper)

    def test_publication_uses_long_short_terminology(self) -> None:
        whitepaper_dir = Path(__file__).resolve().parent
        publication_text = (
            (whitepaper_dir.parent / "WHITEPAPER.md").read_text(encoding="utf-8")
            + (whitepaper_dir / "README.md").read_text(encoding="utf-8")
            + (whitepaper_dir / "generated" / "results.json").read_text(
                encoding="utf-8"
            )
            + "".join(
                path.read_text(encoding="utf-8")
                for path in sorted((whitepaper_dir / "generated").glob("*.svg"))
            )
        )
        self.assertIsNone(
            re.search(r"\b(?:BULL|BEAR|Bull|Bear|bull|bear)\b", publication_text)
        )


if __name__ == "__main__":
    unittest.main()
