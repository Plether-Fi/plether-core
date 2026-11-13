#!/usr/bin/env python3
"""Generate offline carry goldens using exact rational arithmetic, never Solidity output.

Run from any directory. --check verifies the checked-in fixture without rewriting it.
The flat annual index increment and account assessment each have their own specified
floor. One global index depends only on the annual rate and elapsed time.
"""

from __future__ import annotations

import argparse
from fractions import Fraction
from pathlib import Path
import random

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "packages/perps/test/perps/shared/CarryReferenceVectors.sol"
YEAR = 365 * 24 * 60 * 60
SCALE = 10**18
BPS = 10_000


def floor(value: Fraction) -> int:
    return value.numerator // value.denominator


def vector(name: str, exposure: int, rate: int, elapsed: int,
           stored: int = 0, last: int = 0) -> tuple:
    increment = floor(Fraction(rate, BPS) * Fraction(elapsed, YEAR) * SCALE)
    index = stored + increment
    amount = floor(Fraction(exposure, SCALE) * (index - last))
    return name, exposure, rate, elapsed, stored, last, index, amount


def vectors() -> list[tuple]:
    cases = [
        vector("zero-exposure", 0, 500, YEAR),
        vector("zero-rate", 10**12, 0, YEAR),
        vector("zero-time", 10**12, 500, 0),
        vector("one-year-flat-rate", 10**12, 500, YEAR),
        vector("thousand-unit-exposure", 10**9, 500, YEAR),
        vector("non-round-exposure", 10**12 + 1, 500, YEAR),
        vector("ninety-thousand-units", 90_000 * 10**6, 500, YEAR),
        vector("below-one-unit", 999_999, 500, YEAR),
        vector("exact-one-unit", 1_000_000, 500, YEAR),
        vector("above-one-unit", 1_000_001, 500, YEAR),
        vector("one-bp-annual-flat-rate", 10**12, 1, YEAR),
        vector("one-second-dust", 1, 1, 1),
        vector("amount-below-one-atom", SCALE - 1, 0, 0, stored=1),
        vector("amount-exact-one-atom", SCALE, 0, 0, stored=1),
        vector("amount-above-one-atom", SCALE + 1, 0, 0, stored=1),
        vector("stored-index-is-not-recharged", 333_333_333, 777, 86_401,
               stored=123456789012345678, last=123456789012345678),
        vector("prior-uncollected-index", 333_333_333, 777, 86_401,
               stored=123456789012345678, last=123456780000000000),
        vector("maximum-governable-rate", 10**23, 100_000, 73 * YEAR),
        vector("long-interval", 10**29, 99_999, 250 * YEAR),
    ]
    rng = random.Random(0xCA771ED)
    for i in range(24):
        exposure = rng.randrange(1, 10**24)
        stored = rng.randrange(SCALE)
        cases.append(vector(f"fraction-{i:02d}", exposure, rng.randrange(100_001),
                            rng.randrange(250 * YEAR), stored, rng.randrange(stored + 1)))
    return cases


def recovery_vectors() -> list[tuple]:
    """Terminal carry recovery after an ordinary collection: economic recovery is not necessarily cash."""
    inputs = [
        ("all-withheld", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 87, 0),
        ("all-waived", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 87),
        ("physical-withheld-and-waived", 90, 100, 10, 3, 7, 10_000, YEAR, 7, 50, 30),
        ("partial-resolution-retains-arrears", 90, 100, 10, 3, 7, 10_000, YEAR, 7, 11, 13),
        ("flat-rate-and-mixed-recovery", 333, 217, 17, 2, 11, 10_000, YEAR, 11, 180, 7),
        ("half-year-account-floor", 300, 101, 1, 0, 0, 10_000, YEAR // 2, 0, 48, 1),
        ("zero-recovery-preserves-arrears", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 0),
        ("zero-time-no-assessment", 90, 100, 10, 3, 7, 10_000, 0, 0, 0, 0),
        ("physical-only-compatibility", 90, 100, 10, 3, 87, 10_000, YEAR, 87, 0, 0),
    ]
    inputs = [(*row[:-1], 0, row[-1]) for row in inputs]
    inputs += [
        ("all-vpi-offset-no-gain-or-cash", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 87, 0),
        ("partial-vpi-offset-and-waiver", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 6, 81),
        ("all-three-recoveries-plus-waiver", 90, 100, 10, 3, 7, 10_000, YEAR, 7, 11, 13, 56),
        ("partial-vpi-offset-retains-arrears", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 19, 0),
    ]
    rows = []
    for name, depth, maximum, pledge, free, protected, rate, elapsed, physical, withheld, offset, waived in inputs:
        ordinary = vector(name, maximum, rate, elapsed)
        index, new_carry = ordinary[-2:]
        margin_paid = min(pledge, new_carry)
        free_paid = min(free, new_carry - margin_paid)
        remaining = new_carry - margin_paid - free_paid - physical - withheld - offset - waived
        assert remaining >= 0 and physical <= protected
        rows.append((name, depth, maximum, pledge, free, protected, rate, elapsed, physical, withheld, offset, waived,
                     new_carry, remaining, depth + margin_paid + free_paid + physical,
                     margin_paid + free_paid + physical + withheld + offset, maximum, index))
    return rows


def passive_depth_vectors() -> list[tuple]:
    """Cash changes without checkpointing do not change the flat rate observed at later assessment."""
    inputs = [
        ("passive-cash-increases-depth", 1000, 2000, 500, 700, 500, YEAR),
        ("passive-loss-preserves-flat-rate", 2000, 999, 500, 700, 500, YEAR),
        ("cash-shortage-preserves-both-rates", 1000, 0, 500, 700, 500, YEAR),
        ("dust-changes-floor-boundary", 10_001, 10_000, 1, 9999, 10_000, YEAR),
        ("one-second-rounding", 300, 333, 200, 101, 777, 1),
    ]
    rows = []
    for name, initial, final, long_exposure, short_exposure, rate, elapsed in inputs:
        long = vector(name, long_exposure, rate, elapsed)
        short = vector(name, short_exposure, rate, elapsed)
        rows.append((name, initial, final, long_exposure, short_exposure, rate, elapsed,
                     long[-2], long[-1], short[-1]))
    return rows


def render_extra(name: str, function: str, rows: list[tuple], fields: tuple[str, ...]) -> list[str]:
    lines = ["", f"    struct {name} {{"]
    lines += [f"        uint256 {field};" for field in fields]
    lines += ["    }", "", f"    function {function}() internal pure returns ({name}[] memory result) {{",
              f"        result = new {name}[]({len(rows)});"]
    for i, (label, *values) in enumerate(rows):
        lines.append(f"        // {label}")
        for field, value in zip(fields, values, strict=True):
            literal = f"{value:_}" if value >= 10_000 else str(value)
            lines.append(f"        result[{i}].{field} = {literal};")
    lines += ["    }"]
    return lines


def render() -> str:
    rows = vectors()
    lines = [
        "// SPDX-License-Identifier: AGPL-3.0",
        "pragma solidity 0.8.35;",
        "",
        "// Generated by scripts/generate-perps-carry-vectors.py using Python fractions.Fraction.",
        "// Reproduce with that script; --check fails on stale fixture contents. No on-chain output is an input.",
        "library CarryReferenceVectors {",
        "",
        "    struct Vector {",
        "        uint256 maxProfitExposure;",
        "        uint256 annualBps;",
        "        uint256 elapsed;",
        "        uint256 storedIndex;",
        "        uint256 lastPositionIndex;",
        "        uint256 expectedIndex;",
        "        uint256 expectedAmount;",
        "    }",
        "",
        "    function all() internal pure returns (Vector[] memory result) {",
        f"        result = new Vector[]({len(rows)});",
    ]
    fields = ("maxProfitExposure", "annualBps", "elapsed", "storedIndex", "lastPositionIndex",
              "expectedIndex", "expectedAmount")
    for i, (name, *values) in enumerate(rows):
        lines.append(f"        // {name}")
        for field, value in zip(fields, values):
            literal = f"{value:_}" if value >= 10_000 else str(value)
            lines.append(f"        result[{i}].{field} = {literal};")
    lines += ["    }"]
    lines += render_extra("RecoveryVector", "recoveries", recovery_vectors(),
                          ("initialDepth", "maxProfit", "pledge", "free", "protectedFunds", "annualBps", "elapsed",
                           "physicalPaid", "gainWithheld", "vpiOffset", "waived", "expectedNewCarry", "expectedRemainingArrears",
                           "expectedPoolDepth", "expectedCollected", "expectedMaxProfitExposure", "expectedIndex"))
    lines += render_extra("PassiveDepthVector", "passiveDepths", passive_depth_vectors(),
                          ("initialDepth", "finalDepth", "longMaxProfit", "shortMaxProfit", "annualBps", "elapsed",
                           "expectedIndex", "expectedLongCarry", "expectedShortCarry"))
    lines += ["", "}", ""]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered = render()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != rendered:
            raise SystemExit("Carry reference vectors are stale; run scripts/generate-perps-carry-vectors.py")
        print(f"Verified {len(vectors())} accrual, {len(recovery_vectors())} recovery and "
              f"{len(passive_depth_vectors())} passive-depth exact-rational carry vectors")
    else:
        OUTPUT.write_text(rendered)
        print(f"Wrote {len(vectors())} accrual, {len(recovery_vectors())} recovery and "
              f"{len(passive_depth_vectors())} passive-depth exact-rational carry vectors to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
