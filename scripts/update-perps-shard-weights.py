#!/usr/bin/env python3
"""Rebalance unpinned shards from recorded Forge result durations.

Pass all shard results from one campaign together. Migration maps are optional
and are only needed to translate pre-reorganization baseline results.
"""

import argparse
import json
import re
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = ROOT / "packages/perps/test"


def seconds(value):
    if isinstance(value, dict):
        return value.get("secs", 0) + value.get("nanos", 0) / 1e9
    units = {"h": 3600, "m": 60, "s": 1, "ms": 1e-3, "µs": 1e-6, "us": 1e-6, "ns": 1e-9}
    return sum(float(number) * units[unit] for number, unit in
               re.findall(r"([\d.]+)(ms|µs|us|ns|h|m|s)", value or ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", nargs="+", type=Path, required=True)
    parser.add_argument("--structural-migration", type=Path)
    parser.add_argument("--audit-migration", type=Path)
    parser.add_argument("--label", required=True, help="Profile, compiler mode, seed, and evidence provenance")
    parser.add_argument("--output", type=Path, default=ROOT / "scripts/perps-shard-weights.json")
    args = parser.parse_args()
    paths = list(TEST_ROOT.rglob("*.t.sol"))
    migration = {}
    if args.structural_migration:
        for entry in json.loads(args.structural_migration.read_text()):
            for name in entry.get("tests", []):
                migration[(Path(entry["old_file"]).name, name)] = entry["new_file"].split("packages/perps/test/")[-1]
    if args.audit_migration:
        for entry in json.loads(args.audit_migration.read_text())["tests"]:
            replacement = entry.get("replacement") or ""
            if ".t.sol::" in replacement:
                migration[(entry["source"], entry["test"])] = "perps/" + replacement.split("::")[0]
    measurements = {}
    measured_tests = 0
    for result_file in args.results:
        for suite, data in json.loads(result_file.read_text()).items():
            source, contract = suite.rsplit(":", 1)
            basename = Path(source).name
            for signature, result in data.get("test_results", {}).items():
                if result.get("status") != "Success":
                    continue
                name = signature.split("(", 1)[0]
                destination = migration.get((basename, name))
                if destination is None:
                    candidates = [p for p in paths if p.name == basename]
                    if len(candidates) != 1:
                        continue
                    destination = candidates[0].relative_to(TEST_ROOT).as_posix()
                if not (TEST_ROOT / destination).is_file():
                    continue
                # Inherited tests execute once per concrete contract; only
                # repeated measurements of that same instance use a median.
                key = (destination, contract, signature)
                measurements.setdefault(key, []).append(seconds(result.get("duration")))
                measured_tests += 1
    weights = {}
    for (destination, _, _), samples in measurements.items():
        weights[destination] = weights.get(destination, 0) + statistics.median(samples)
    if not weights:
        raise SystemExit("no successful tests matched current entrypoints")
    output = {"provenance": args.label, "measured_test_results": measured_tests,
              "method": "Sum of median successful per-test durations; fixed stateful pins remain unchanged. Unmeasured files use the median file weight.",
              "default_seconds": round(statistics.median(weights.values()), 6),
              "seconds": {path: round(value, 6) for path, value in sorted(weights.items())}}
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(f"Recorded {measured_tests} successful result durations across {len(weights)} current entrypoints.")


if __name__ == "__main__":
    main()
