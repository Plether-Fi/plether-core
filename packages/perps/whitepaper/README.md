# White Paper Reproducibility

This directory contains the machine-readable accounting model and empirical
analysis used by `packages/perps/WHITEPAPER.md`.

The Python module mirrors selected integer accounting kernels from:

- `CfdMath`
- `PositionRiskAccountingLib`
- `SolvencyAccountingLib`
- `CashPriorityLib`
- `CfdEngineSettlementLib`
- `LiquidationAccountingLib`
- `HousePoolWaterfallAccountingLib`

It also reconstructs Plether's six-FX normalized basket from official ECB daily
reference rates and runs the deterministic monthly-cohort scenarios reported in
the paper. The ECB series is an information-only, daily research proxy. The
replay does not reproduce Pyth ticks, oracle confidence intervals, executable
weekend prices, intraday paths, VPI, frozen execution, keeper latency, or
pending-deposit epochs. Signals are formed one fix before the entry proxy; the
reference 40% final-skew wall is enforced on paired cohorts using exact
integer/rational admission scaling. Paired legs are assumed to be interleaved,
so this is not a transaction-level order simulation. LP capital is static:
the scenarios include no LP deposits, withdrawals, or recapitalizations.

The replay reports two non-production tranche views. The realized-cash overlay
applies cash/claim changes and observed-interval coupon checkpoints. The
separate daily shadow subtracts the legacy conservative side-envelope stress;
it predates the exact account-capped `TerminalNavBookV2` kernel and must not be
read as production LP share NAV. Its once-per-observation cadence is also a
research convention. The replay performs one additional shadow reconciliation
at the final fix after forced end-of-sample closes. Settlement-order
alternatives and the forced close are recorded in `results.json`.

## Reproduce

The publication snapshot covers 2016-01-01 through 2026-06-30:

```bash
python3 packages/perps/whitepaper/bounded_perps_model.py \
  --fetch \
  --output-dir packages/perps/whitepaper/generated
```

The script pins the expected SHA-256 hash of the ECB response. If the ECB later
revises the fixed-window dataset, it stops and asks the researcher to inspect the
revision before explicitly accepting a checksum change.

To use an already downloaded ECB `csvdata` response:

```bash
python3 packages/perps/whitepaper/bounded_perps_model.py \
  --ecb-csv /path/to/ecb-exr.csv \
  --output-dir packages/perps/whitepaper/generated
```

Run the kernel-vector, proposition, replay, and publication-consistency tests
from this directory:

```bash
cd packages/perps/whitepaper
python3 -m unittest -v test_bounded_perps_model.py
```

Generated outputs are:

- `results.json`: machine-readable statistics and fixed examples
- `ecb_plether_basket.csv`: derived basket and crossed component prices
- `basket_history.svg`: normalized basket history
- `nonpublication_gaps.svg`: largest reference-fix changes across long gaps
- `cap_sensitivity.svg`: stylized reserve sensitivity to the cap
- `replay_summary.svg`: scenario capital, carry, and cap-sensitivity summary

Render the publication PDF (requires Pandoc, `rsvg-convert`, and the bundled
ReportLab runtime):

```bash
python3 packages/perps/whitepaper/render_whitepaper.py
```

The stable output path is
[`output/pdf/plether-perps-bounded-credit-whitepaper.pdf`](../../../output/pdf/plether-perps-bounded-credit-whitepaper.pdf).

The Solidity implementation and `packages/perps/ACCOUNTING_SPEC.md` remain
normative. This model is a research companion, not an alternate execution
engine.
