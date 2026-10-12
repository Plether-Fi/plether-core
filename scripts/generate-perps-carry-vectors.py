#!/usr/bin/env python3
"""Generate offline carry goldens using exact rational arithmetic, never Solidity output.

Run from any directory. --check verifies the checked-in fixture without rewriting it.
The bps utilization, global index increment and account assessment each have their
own specified floor. Keeping those three rounding boundaries is intentional.
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


def vector(name: str, base: int, depth: int, rate: int, elapsed: int,
           position_base: int | None = None, stored: int = 0, last: int = 0) -> tuple:
    utilization = 0 if base == 0 else BPS if depth == 0 else min(BPS, floor(Fraction(base, depth) * BPS))
    increment = floor(Fraction(rate, BPS) * Fraction(utilization, BPS) * Fraction(elapsed, YEAR) * SCALE)
    index = stored + increment
    position_base = base if position_base is None else position_base
    amount = floor(Fraction(position_base, SCALE) * (index - last))
    return name, base, depth, rate, elapsed, position_base, stored, last, utilization, index, amount


def vectors() -> list[tuple]:
    cases = [
        vector("zero-base", 0, 0, 500, YEAR),
        vector("zero-rate", 10**12, 2 * 10**12, 0, YEAR),
        vector("zero-time", 10**12, 2 * 10**12, 500, 0),
        vector("zero-depth-saturates", 10**12, 0, 500, YEAR),
        vector("exact-saturation", 10**12, 10**12, 500, YEAR),
        vector("above-saturation", 10**12 + 1, 10**12, 500, YEAR),
        vector("half-utilization", 90_000 * 10**6, 180_000 * 10**6, 500, YEAR),
        vector("below-one-bp", 999_999, 10**10, 500, YEAR),
        vector("exact-one-bp", 1_000_000, 10**10, 500, YEAR),
        vector("above-one-bp", 1_000_001, 10**10, 500, YEAR),
        vector("single-pass-retains-fractional-rate", 10**12, 3 * 10**12, 1, YEAR),
        vector("one-second-dust", 1, 1, 1, 1),
        vector("amount-below-one-atom", SCALE - 1, SCALE - 1, 0, 0, stored=1),
        vector("amount-exact-one-atom", SCALE, SCALE, 0, 0, stored=1),
        vector("amount-above-one-atom", SCALE + 1, SCALE + 1, 0, 0, stored=1),
        vector("stored-index-is-not-recharged", 333_333_333, 999_999_999, 777, 86_401,
               stored=123456789012345678, last=123456789012345678),
        vector("prior-uncollected-index", 333_333_333, 999_999_999, 777, 86_401,
               stored=123456789012345678, last=123456780000000000),
        vector("maximum-governable-rate", 10**24, 3 * 10**24, 100_000, 73 * YEAR, 10**23),
        vector("long-idle-high-depth", 10**30, 10**30 + 1, 99_999, 250 * YEAR, 10**29),
    ]
    rng = random.Random(0xCA771ED)
    for i in range(24):
        base = rng.randrange(1, 10**24)
        depth = rng.randrange(1, 2 * 10**24)
        stored = rng.randrange(SCALE)
        cases.append(vector(f"fraction-{i:02d}", base, depth, rng.randrange(100_001),
                            rng.randrange(250 * YEAR), rng.randrange(base + 1), stored, rng.randrange(stored + 1)))
    return cases


def recovery_vectors() -> list[tuple]:
    """Terminal carry recovery after an ordinary collection: economic recovery is not necessarily cash."""
    inputs = [
        ("all-withheld", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 77, 0),
        ("all-waived", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 77),
        ("physical-withheld-and-waived", 90, 100, 10, 3, 7, 10_000, YEAR, 7, 50, 20),
        ("partial-resolution-retains-arrears", 90, 100, 10, 3, 7, 10_000, YEAR, 7, 11, 13),
        ("utilization-floor-and-mixed-recovery", 333, 217, 17, 2, 11, 10_000, YEAR, 11, 83, 7),
        ("half-year-account-floor", 300, 101, 1, 0, 0, 10_000, YEAR // 2, 0, 14, 1),
        ("zero-recovery-preserves-arrears", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 0),
        ("zero-time-no-assessment", 90, 100, 10, 3, 7, 10_000, 0, 0, 0, 0),
        ("physical-only-compatibility", 90, 100, 10, 3, 77, 10_000, YEAR, 77, 0, 0),
    ]
    inputs = [(*row[:-1], 0, row[-1]) for row in inputs]
    inputs += [
        ("all-vpi-offset-no-gain-or-cash", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 77, 0),
        ("partial-vpi-offset-and-waiver", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 6, 71),
        ("all-three-recoveries-plus-waiver", 90, 100, 10, 3, 7, 10_000, YEAR, 7, 11, 13, 46),
        ("partial-vpi-offset-retains-arrears", 90, 100, 10, 3, 7, 10_000, YEAR, 0, 0, 19, 0),
    ]
    rows = []
    for name, depth, maximum, pledge, free, protected, rate, elapsed, physical, withheld, offset, waived in inputs:
        ordinary = vector(name, maximum - pledge, depth, rate, elapsed)
        index, new_carry = ordinary[-2:]
        margin_paid = min(pledge, new_carry)
        free_paid = min(free, new_carry - margin_paid)
        remaining = new_carry - margin_paid - free_paid - physical - withheld - offset - waived
        assert remaining >= 0 and physical <= protected
        rows.append((name, depth, maximum, pledge, free, protected, rate, elapsed, physical, withheld, offset, waived,
                     new_carry, remaining, depth + margin_paid + free_paid + physical,
                     margin_paid + free_paid + physical + withheld + offset, maximum - pledge + margin_paid, index))
    return rows


def passive_depth_vectors() -> list[tuple]:
    """A cash change without checkpointing alters the depth observed at the later assessment."""
    inputs = [
        ("passive-cash-increases-depth", 1000, 2000, 500, 700, 500, YEAR),
        ("passive-loss-increases-utilization", 2000, 999, 500, 700, 500, YEAR),
        ("cash-shortage-saturates-both-sides", 1000, 0, 500, 700, 500, YEAR),
        ("dust-changes-floor-boundary", 10_001, 10_000, 1, 9999, 10_000, YEAR),
        ("one-second-rounding", 300, 333, 200, 101, 777, 1),
    ]
    rows = []
    for name, initial, final, long_base, short_base, rate, elapsed in inputs:
        long = vector(name, long_base, final, rate, elapsed)
        short = vector(name, short_base, final, rate, elapsed)
        rows.append((name, initial, final, long_base, short_base, rate, elapsed,
                     long[-2], short[-2], long[-1], short[-1]))
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
        "        uint256 sideBorrowBase;",
        "        uint256 poolDepth;",
        "        uint256 annualBps;",
        "        uint256 elapsed;",
        "        uint256 positionBorrowBase;",
        "        uint256 storedIndex;",
        "        uint256 lastPositionIndex;",
        "        uint256 expectedUtilization;",
        "        uint256 expectedIndex;",
        "        uint256 expectedAmount;",
        "    }",
        "",
        "    function all() internal pure returns (Vector[] memory result) {",
        f"        result = new Vector[]({len(rows)});",
    ]
    fields = ("sideBorrowBase", "poolDepth", "annualBps", "elapsed", "positionBorrowBase", "storedIndex",
              "lastPositionIndex", "expectedUtilization", "expectedIndex", "expectedAmount")
    for i, (name, *values) in enumerate(rows):
        lines.append(f"        // {name}")
        for field, value in zip(fields, values):
            literal = f"{value:_}" if value >= 10_000 else str(value)
            lines.append(f"        result[{i}].{field} = {literal};")
    lines += ["    }"]
    lines += render_extra("RecoveryVector", "recoveries", recovery_vectors(),
                          ("initialDepth", "maxProfit", "pledge", "free", "protectedFunds", "annualBps", "elapsed",
                           "physicalPaid", "gainWithheld", "vpiOffset", "waived", "expectedNewCarry", "expectedRemainingArrears",
                           "expectedPoolDepth", "expectedCollected", "expectedBorrowBase", "expectedIndex"))
    lines += render_extra("PassiveDepthVector", "passiveDepths", passive_depth_vectors(),
                          ("initialDepth", "finalDepth", "longBase", "shortBase", "annualBps", "elapsed",
                           "expectedLongIndex", "expectedShortIndex", "expectedLongCarry", "expectedShortCarry"))
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
