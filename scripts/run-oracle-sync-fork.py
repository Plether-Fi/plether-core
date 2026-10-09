#!/usr/bin/env python3
"""Replay the baseline regression and optional mandatory V3 gas matrix; never broadcasts."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
from oracle_sync_evidence import (assert_unchanged, load_scenario_manifest, parse_scenario_records, production_environment,
                                  require_tracked_file, sanitize_log, sha256_file, source_fingerprint,
                                  validate_fixture, validate_scenario_records)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def run_forge(command, checkout, environment, log_path):
    result = subprocess.run(command, cwd=checkout, env=environment, capture_output=True, text=True)
    output = sanitize_log(result.stdout + result.stderr, environment)
    log_path.write_text(output)
    return result.returncode, output, sha256_file(log_path)


def baseline_result(returncode, output, log_hash):
    name = "test_RealPythBaselineVersusAtomicSynchronization"
    passed = returncode == 0 and f"[PASS] {name}" in output and "0 skipped" in output
    values = {}
    for line in output.splitlines():
        for field in ("historical fill", "neutral mark"):
            if line.strip().startswith(field + ":"):
                if field in values:
                    raise ValueError("Duplicate baseline price evidence")
                values[field] = int(line.strip().split(":", 1)[1].strip())
    if set(values) != {"historical fill", "neutral mark"} or any(value <= 0 for value in values.values()):
        passed = False
    return dict(passed=passed, prices=values, logSha256=log_hash, exitCode=returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--scenario-manifest", type=Path,
                        help="Committed V3 fixtures; required for release qualification, optional for regression-only replay")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    fixture_path = require_tracked_file(root, args.fixture)
    fixture = validate_fixture(json.loads(fixture_path.read_text()), require_mismatch=True)
    baseline = subprocess.check_output(
        ["git", "rev-parse", fixture["baselineSourceCommit"] + "^{commit}"], cwd=root, text=True).strip()
    if baseline != fixture["baselineSourceCommit"]:
        parser.error("Baseline must be an immutable full commit")
    if not os.environ.get("ARB_SEPOLIA_RPC_URL"):
        parser.error("ARB_SEPOLIA_RPC_URL is required; no skip fallback")
    manifest = load_scenario_manifest(root, args.scenario_manifest) if args.scenario_manifest else None
    fingerprint = source_fingerprint(root)
    candidate_commit = fingerprint["sourceCommit"]
    forge_version = subprocess.check_output(["forge", "--version"], text=True).splitlines()[0]
    if forge_version != "forge Version: 1.5.1-stable":
        parser.error("Release evidence requires Forge 1.5.1-stable")
    output_dir = args.output.resolve()
    if output_dir.exists():
        parser.error("Evidence output already exists")
    output_dir.mkdir(parents=True)
    write_json(output_dir / "inputs.before.json", fingerprint)
    report = dict(schemaVersion=2, passed=False, releaseMatrixPassed=False,
                  baselineSourceCommit=baseline, candidateSourceCommit=candidate_commit,
                  candidateHasUncommittedChanges=False, inputFingerprintSha256=fingerprint["sha256"],
                  fixtureSha256=sha256_file(fixture_path), payloadSha256=fixture["payloadSha256"],
                  forkBlockHash=fixture["forkBlockHash"], forgeVersion=forge_version, results={},
                  measurementNote="callGas measures the isolated contract call, excluding transaction intrinsic gas and Arbitrum data fees")
    try:
        with tempfile.TemporaryDirectory(prefix="oracle-sync-baseline-") as directory:
            old = Path(directory)
            archive = old / "source.tar"
            with archive.open("wb") as target:
                subprocess.run(["git", "archive", baseline], cwd=root, stdout=target, check=True)
            with tarfile.open(archive) as source:
                source.extractall(old, filter="data")
            for name in ("forge-std", "openzeppelin-contracts", "morpho-blue"):
                dependency = "lib/" + name
                baseline_pin = subprocess.check_output(["git", "rev-parse", baseline + ":" + dependency], cwd=root)
                candidate_pin = subprocess.check_output(["git", "rev-parse", candidate_commit + ":" + dependency], cwd=root)
                if baseline_pin != candidate_pin:
                    raise ValueError("Baseline dependency pins differ; shared dependency checkout would invalidate comparison")
                destination = old / dependency
                if destination.exists():
                    destination.rmdir()
                destination.symlink_to(root / dependency, target_is_directory=True)
            test = Path("test/fork/OracleSynchronizationFork.t.sol")
            (old / test).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(root / test, old / test)
            config = old / "foundry.toml"
            config.write_text(config.read_text().replace(
                'path = "script/bytecode/" }]',
                'path = "script/bytecode/" }, { access = "read", path = "test/fixtures/" }]'))
            if 'path = "test/fixtures/"' not in config.read_text():
                raise ValueError("Baseline fixture read permission could not be established")
            for name, checkout, fixed in (("baseline", old, False), ("candidate", root, True)):
                fixture_directory = checkout / "test/fixtures"
                fixture_directory.mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryDirectory(prefix=".oracle-sync-run-", dir=fixture_directory) as temporary:
                    local_fixture = Path(temporary) / "run.json"
                    write_json(local_fixture, fixture)
                    env = dict(production_environment(),
                               ORACLE_SYNC_FIXTURE=str(local_fixture), ORACLE_SYNC_EXPECT_FIXED=str(fixed).lower())
                    command = ["forge", "test", "--offline", "--isolate", "--match-path", str(test),
                               "--match-test", "test_RealPythBaselineVersusAtomicSynchronization", "-vv"]
                    code, log, log_hash = run_forge(command, checkout, env, output_dir / (name + ".log"))
                    report["results"][name] = baseline_result(code, log, log_hash)
        comparison = report["results"]
        if not all(value["passed"] for value in comparison.values()):
            raise ValueError("Baseline/candidate regression did not complete successfully")
        if comparison["baseline"]["prices"] != comparison["candidate"]["prices"]:
            raise ValueError("Candidate changed historical fill or neutral mark")
        if manifest:
            env = dict(production_environment(),
                       ORACLE_SYNC_SCENARIO_MANIFEST=str((root / manifest["path"]).resolve()),
                       ORACLE_SYNC_ISOLATION_MODE="transaction")
            command = ["forge", "test", "--offline", "--isolate", "--match-contract",
                       "^OracleSynchronizationGasForkTest$", "-vv"]
            code, log, log_hash = run_forge(command, root, env, output_dir / "scenarios.log")
            report["matrix"] = dict(passed=False, exitCode=code, logSha256=log_hash, manifest=manifest,
                                    command=command, isolationMode="transaction")
            if code != 0 or "0 skipped" not in log:
                raise ValueError("V3 scenario suite failed or skipped a mandatory test")
            records = validate_scenario_records(parse_scenario_records(log), manifest)
            report["matrix"].update(passed=True, scenarios=records)
            report["releaseMatrixPassed"] = True
        after = source_fingerprint(root, candidate_commit)
        write_json(output_dir / "inputs.after.json", after)
        assert_unchanged(fingerprint, after)
        report["afterInputFingerprintSha256"] = after["sha256"]
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["releaseMatrixPassed"] = False
        report["failure"] = sanitize_log(str(error))
        try:
            after = source_fingerprint(root, candidate_commit)
            write_json(output_dir / "inputs.after.json", after)
            assert_unchanged(fingerprint, after)
        except Exception:
            report["candidateHasUncommittedChanges"] = True
            report["candidateSourceCommit"] = None
        raise
    finally:
        write_json(output_dir / "result.json", report)
    if manifest:
        print("Baseline regression and every isolated V3 scenario passed with unchanged qualification inputs")
    else:
        print("Baseline regression passed; release matrix was not requested and remains unqualified")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(sanitize_log(f"Fork evidence failed: {type(error).__name__}: {error}"), file=sys.stderr)
        sys.exit(1)
