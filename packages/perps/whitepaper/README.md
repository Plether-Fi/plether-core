# Whitepaper research model and reproduction

This directory contains the historical research model, saved results, and PDF
renderer for [Bounded Perpetuals](../WHITEPAPER.md). For current protocol
behavior, start with the [package guide](../README.md) and
[accounting specification](../ACCOUNTING_SPEC.md).

The Python model freezes selected accounting kernels from publication revision
`06d0ab451ad9bb42f4e9869fc94b0eeb1e88efe5`. The whitepaper's protocol description
is maintained separately; its front matter identifies the implementation
revision reviewed. Regenerating the research results does **not** update the
model to current Solidity behavior.

## What the model covers

[`bounded_perps_model.py`](bounded_perps_model.py) reconstructs the six-currency
normalized basket from official ECB daily reference rates, checks selected
integer accounting examples, and runs the monthly-cohort scenarios in Section
8 of the whitepaper. The fixed data window is 2016-01-01 through 2026-06-30,
with 2,685 complete observations from 2016-01-04 onward.

Important differences from the current protocol:

| Area | Research-model treatment |
| --- | --- |
| Price settlement | Legacy collateral/claim ordering and uncovered-loss telemetry; no exact-lot entry-cost book, claim-first capped price collection, or separate action/liquidation reserves |
| Carry and admission | Historical carry collection and gross-cash utilization; no current margin-first carry checkpoint or liability-scaled settlement buffer |
| LP valuation | A realized-cash waterfall and a separate conservative side-envelope stress shadow; neither implements `TerminalNavBookV2` share NAV |
| Execution | Daily ECB fixes, not Pyth ticks; no confidence shifts, VPI in the scenario replay, frozen execution, slippage rejection, or keeper delays |
| Capital and epochs | Static LP capital; no deposits, withdrawals, recapitalizations, synchronized LP epochs, Senior capacity admission, or Junior maintenance-fee dilution |

The module includes a standalone VPI arithmetic helper even though the historical
scenario replay excludes VPI. Historical Solidity names in its comments identify
the publication kernels; some, such as `CfdEngineSettlementLib`, no longer exist
in the current source tree.

Signals are formed one fix before the entry proxy. The reference 40% final-skew
wall is enforced on paired cohorts with exact integer/rational scaling. The legs
are assumed to be interleaved, so this is not a transaction-level simulation.
The shadow waterfall reconciles after each observation and once more after the
forced end-of-sample closes. `results.json` records settlement-order alternatives
and forced closes. ECB fixes are an information-only research proxy, not
executable market prices.

## Check the saved publication results

All commands below run from the repository root. The model and its tests use
only the Python standard library. These tests require the checked-in generated
files but no network access:

```bash
python3 -m unittest discover \
  -s packages/perps/whitepaper \
  -p 'test_bounded_perps_model.py' -v
```

The tests cover historical kernel vectors, the endpoint-envelope proposition
and its sequential-settlement counterexample, deterministic replay, and
agreement between the whitepaper's reported tables and saved results. They do
not establish parity with current Solidity settlement.

## Regenerate the research outputs

Fetch the fixed-window ECB `csvdata` response and rebuild the results:

```bash
python3 packages/perps/whitepaper/bounded_perps_model.py \
  --fetch \
  --output-dir packages/perps/whitepaper/generated
```

The raw response is cached at `/tmp/plether_ecb_fx.csv` by default; use
`--raw-cache /path/to/ecb-exr.csv` to choose another path. To reuse a downloaded
response without fetching:

```bash
python3 packages/perps/whitepaper/bounded_perps_model.py \
  --ecb-csv /path/to/ecb-exr.csv \
  --output-dir packages/perps/whitepaper/generated
```

The script verifies the raw response against the publication's pinned SHA-256
hash before analysis. A mismatch stops the run. Inspect upstream revisions
before using `--allow-checksum-mismatch`; write a revised dataset's results to
a separate output directory so they are not confused with the publication
snapshot. Rerun the tests after regenerating the published outputs.

| Output | Contents |
| --- | --- |
| [`generated/results.json`](generated/results.json) | Statistics, scenario assumptions, and fixed accounting examples |
| [`generated/ecb_plether_basket.csv`](generated/ecb_plether_basket.csv) | Derived basket and crossed component prices; this is not the raw ECB response accepted by `--ecb-csv` |
| [`generated/basket_history.svg`](generated/basket_history.svg) | Normalized basket history |
| [`generated/nonpublication_gaps.svg`](generated/nonpublication_gaps.svg) | Largest reference-fix changes across long publication gaps |
| [`generated/cap_sensitivity.svg`](generated/cap_sensitivity.svg) | Stylized reserve sensitivity to the cap |
| [`generated/replay_summary.svg`](generated/replay_summary.svg) | Scenario capital, carry, and cap sensitivity |

## Render the maintained whitepaper

[`render_whitepaper.py`](render_whitepaper.py) requires ReportLab and Pillow,
Pandoc and `rsvg-convert` on `PATH`, and the macOS Times New Roman font files in
`/System/Library/Fonts/Supplemental`. It uses the maintained Markdown and saved
figures; it does not rerun the research model.

```bash
python3 packages/perps/whitepaper/render_whitepaper.py
```

The output is
[`output/pdf/plether-perps-bounded-credit-whitepaper.pdf`](../../../output/pdf/plether-perps-bounded-credit-whitepaper.pdf).
The cover retains the original publication metadata. Installed tools and fonts
affect layout, and PDF bytes are not deterministic. Review a regenerated PDF
before distributing it.
