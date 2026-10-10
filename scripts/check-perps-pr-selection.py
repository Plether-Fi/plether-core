#!/usr/bin/env python3
"""Require an exact, nonoverlapping PR lane partition of unfiltered discovery."""

import json
from pathlib import Path
import sys

import importlib.util

_spec = importlib.util.spec_from_file_location("perps_recorded", Path(__file__).with_name("run-perps-recorded.py"))
_recorder = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_recorder)
selected_ids = _recorder.selected_ids


def check(directory, package, expected_file):
    def read(name):
        return json.loads((directory / name).read_text())

    all_tests = read("all-tests.json")
    expected = selected_ids(all_tests)
    production = selected_ids(read("production-gates/selected-tests.json"))
    correctness = selected_ids(read("correctness/selected-tests.json"))
    missing = sorted(expected - (production | correctness))
    unexpected = sorted((production | correctness) - expected)
    overlap = sorted(production & correctness)
    missing_entrypoints = []
    if expected_file:
        config = read("production-gates/config.json")
        test_root = Path(config.get("test", "test"))
        if not test_root.is_absolute():
            test_root = package / test_root
        actual = set()
        for source, contracts in all_tests.items():
            if not any(contracts.values()):
                continue
            path = Path(source)
            if not path.is_absolute():
                path = package / path
            actual.add(path.relative_to(test_root).as_posix())
        missing_entrypoints = sorted(set(Path(expected_file).read_text().splitlines()) - actual)
    result = {"discovered": len(expected), "production": len(production),
              "correctness": len(correctness), "missing": missing, "unexpected": unexpected,
              "overlap": overlap, "missing_entrypoints": missing_entrypoints}
    (directory / "pr-selection.json").write_text(json.dumps(result, indent=2) + "\n")
    if not expected or missing or unexpected or overlap or missing_entrypoints:
        raise ValueError("PR lanes are not an exact discovery partition: " + json.dumps(result))
    print("PR lane partition verified: " + json.dumps(result))


if __name__ == "__main__":
    check(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
