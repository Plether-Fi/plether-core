#!/usr/bin/env python3
"""One source of truth for physical perps shard and coverage selection.

This inventories source entrypoints; run-perps-recorded.py additionally records
Forge's discovered contract/test inventory, including inherited test functions.
"""

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = ROOT / "packages/perps/test"
WEIGHTS_FILE = ROOT / "scripts/perps-shard-weights.json"
PINS = {
    "PerpAccountingInvariant.t.sol": 0,
    "PerpInvariant.t.sol": 1,
    "PerpEconomicConservationInvariant.t.sol": 2,
    "PerpValueConservationInvariant.t.sol": 2,
    "PerpPreviewInvariant.t.sol": 3,
    "PerpClosePreviewParityInvariant.t.sol": 3,
    "PerpMultiAccountInvariant.t.sol": 3,
    "PerpHousePoolLifecycleInvariant.t.sol": 3,
    "PerpIndependentClaimInvariant.t.sol": 0,
    "PerpVpiFrozenAccountingInvariant.t.sol": 1,
    "PerpWaterfallReferenceInvariant.t.sol": 2,
}
GAS_TESTS = r"GasBudget|test_[Gg]as_"
SIZE_TESTS = r"RuntimeFitsEip170|FitsEip3860|FitDeploymentLimits|test_Runtime_"
PROPERTY_TESTS = r"testFuzz_|invariant_"
PRODUCTION_SENSITIVE_TESTS = {
    "test_BatchItemOogAndRefundGasBurnCannotRollbackCompletedPrefix",
    "test_Batch_LowGasReturnsSameUnattemptedIndex",
    "test_UpdatePrice_GasBurningRefundRecipientAccruesAndClaimsDeferredRefund",
    "test_BatchLiquidationAppliesRiskOffRefundBeforeLiquidating",
    "test_BatchLiquidationHonorsCutoffAdvancedDuringOracleRefund",
    "test_DeferredAdminRefundIsBackedUntilBeneficiaryClaimsExactlyOnce",
    # These properties run a setup prelude with fixed callback gas caps and burners.
    # Keep that prelude under production codegen in PRs as well as full CI/audit.
    "invariant_EthConservedAcrossFeesRefundsAndClaims",
    "invariant_AllRequiredPathsRemainExercised",
}
# Coverage changes generated code and gas usage. These tests still run in normal
# correctness and production-codegen lanes. No current-defect exclusions belong here.
COVERAGE_EXCLUSIONS = [
    (PROPERTY_TESTS, "Random/stateful campaigns run in correctness lanes; coverage uses deterministic scenarios."),
    (GAS_TESTS + "|" + SIZE_TESTS, "Instrumented bytecode cannot measure production gas or deployment size."),
    (r"test_BatchLiquidationAppliesRiskOffRefundBeforeLiquidating|test_BatchLiquidationHonorsCutoffAdvancedDuringOracleRefund",
     "Instrumentation changes bounded batch gas admission; execute under production codegen."),
]


def production_test_regex():
    # Some bounded-work correctness gates have descriptive names without "Gas".
    # Every declared test in gas/ belongs to production codegen regardless of name.
    names = set(PRODUCTION_SENSITIVE_TESTS)
    for source in TEST_ROOT.rglob("*.t.sol"):
        if "gas" in source.relative_to(TEST_ROOT).parts:
            names.update(re.findall(r"\bfunction\s+(test\w+)\s*\(", source.read_text()))
    return "|".join([GAS_TESTS, SIZE_TESTS] + ["^" + re.escape(name) + r"(\(|$)" for name in sorted(names)])


def inventory():
    files = sorted(TEST_ROOT.rglob("*.t.sol"))
    if not files:
        raise ValueError("perps package contains no test entrypoints")
    for source in TEST_ROOT.rglob("*.sol"):
        # Strip comments before checking multiline imports of entrypoints.
        text = re.sub(r"/\*.*?\*/|//[^\n]*", "", source.read_text(), flags=re.S)
        if any(".t.sol" in match for match in re.findall(r"\bimport\b[^;]*;", text)):
            raise ValueError(f"shared fixtures must not import .t.sol entrypoints: {source}")
    for name in PINS:
        matches = [path for path in files if path.name == name]
        if len(matches) != 1:
            raise ValueError(f"expected exactly one pinned entrypoint {name}, found {len(matches)}")
    rows = []
    timing = json.loads(WEIGHTS_FILE.read_text()) if WEIGHTS_FILE.exists() else {}
    weights = timing.get("seconds", {})
    default_weight = timing.get("default_seconds", 1)
    for source in files:
        path = source.relative_to(TEST_ROOT).as_posix()
        parts = source.relative_to(TEST_ROOT).parts
        # Also recognize the pre-migration locations while the move is reviewed.
        fork = "fork" in parts or source.name in {
            "CfdSponsoredCloseFork.t.sol", "HistoricalCloseRegression.t.sol"
        }
        shard = None if fork else PINS.get(source.name)
        reason = None
        if fork:
            reason = "RPC integration runs only in the explicitly configured fork lane."
        elif "invariant" in parts or source.name == "PerpInvariant.t.sol":
            reason = "Stateful campaigns run in correctness lanes without coverage instrumentation."
        elif "gas" in parts or source.name in {"GasProfile.t.sol", "GasProfileWithFees.t.sol"}:
            reason = "Production gas benchmarks cannot use instrumented bytecode."
        rows.append({"path": path, "shard": shard, "lane": "fork" if fork else "correctness",
                     "coverage": reason is None, "coverage_exclusion": reason,
                     "estimated_seconds": weights.get(path, default_weight),
                     "timing_source": "measured" if path in weights else "median default"})
    # Longest measured work first, while preserving stateful campaign isolation.
    loads = [sum(r["estimated_seconds"] for r in rows if r["shard"] == i) for i in range(4)]
    unassigned = [row for row in rows if row["lane"] == "correctness" and row["shard"] is None]
    for row in sorted(unassigned, key=lambda r: (-r["estimated_seconds"], r["path"])):
        shard = min(range(4), key=lambda i: (loads[i], i))
        row["shard"] = shard
        loads[shard] += row["estimated_seconds"]
    if len({row["path"] for row in rows}) != len(rows):
        raise ValueError("duplicate test entrypoint assignment")
    if {row["shard"] for row in rows if row["lane"] == "correctness"} != set(range(4)):
        raise ValueError("every correctness shard must contain tests")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("json", "tsv", "paths"), default="json")
    parser.add_argument("--lane", choices=("all", "correctness", "coverage", "fork"), default="all")
    parser.add_argument("--shard", type=int, choices=range(4))
    parser.add_argument("--coverage-exclusion-regex", action="store_true")
    parser.add_argument("--production-test-regex", action="store_true")
    args = parser.parse_args()
    if args.production_test_regex:
        print(production_test_regex())
        return
    if args.coverage_exclusion_regex:
        print("|".join(pattern for pattern, _ in COVERAGE_EXCLUSIONS))
        return
    rows = inventory()
    selected = [r for r in rows if (args.lane == "all" or
                (args.lane == "coverage" and r["coverage"]) or r["lane"] == args.lane)
                and (args.shard is None or r["shard"] == args.shard)]
    if args.format == "json":
        print(json.dumps({"entrypoints": selected, "coverage_test_exclusions": [
            {"pattern": pattern, "reason": reason, "execution_lane": "correctness"}
            for pattern, reason in COVERAGE_EXCLUSIONS]}, indent=2))
    elif args.format == "tsv":
        for row in selected:
            print(f'{row["shard"] if row["shard"] is not None else "fork"}\t{row["path"]}')
    else:
        print("\n".join(row["path"] for row in selected))


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error)) from error
