"""Regression checks for selection and evidence; these do not compile Solidity."""

import importlib.util
import io
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from contextlib import redirect_stdout

from perps_forge_json import compact
from perps_coverage_config import absolute_remappings

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("perps_inventory", ROOT / "scripts/perps-test-inventory.py")
inventory_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory_module)
timing_spec = importlib.util.spec_from_file_location("perps_timing", ROOT / "scripts/update-perps-shard-weights.py")
timing_module = importlib.util.module_from_spec(timing_spec)
timing_spec.loader.exec_module(timing_module)


class TimingTests(unittest.TestCase):
    def test_long_and_subsecond_forge_durations_keep_all_units(self):
        self.assertEqual(timing_module.seconds("2m 1s"), 121)
        self.assertAlmostEqual(timing_module.seconds("1h 2m 3s 4ms 5µs 6ns"), 3723.004005006)
        self.assertAlmostEqual(timing_module.seconds("7us 8ns"), 0.000007008)
        self.assertAlmostEqual(timing_module.seconds({"secs": 3, "nanos": 12}), 3.000000012)

    def test_inherited_instances_sum_while_repeated_measurements_use_medians(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "GasProfile.t.sol").write_text("contract GasProfile {}")
            paths = []
            for index, durations in enumerate(((10, 20), (12, 22))):
                results = {f"test/GasProfile.t.sol:{name}": {"test_results": {
                    "test_gas()": {"status": "Success", "duration": f"{seconds}s"}}}
                    for name, seconds in zip(("WithoutFees", "WithFees"), durations)}
                result_file = directory / f"results-{index}.json"
                result_file.write_text(json.dumps(results))
                paths.append(str(result_file))
            output = directory / "weights.json"
            args = ["update-weights", "--results", *paths, "--label", "fixture", "--output", str(output)]
            with patch.object(timing_module, "TEST_ROOT", directory), patch("sys.argv", args), redirect_stdout(io.StringIO()):
                timing_module.main()
            self.assertEqual(json.loads(output.read_text())["seconds"]["GasProfile.t.sol"], 32)


class CoverageConfigurationTests(unittest.TestCase):
    def test_dependency_targets_become_absolute_without_changing_aliases_or_context(self):
        package = Path("/workspace/packages/perps")
        self.assertEqual(absolute_remappings([
            "@plether/shared/=../shared/src/",
            "forge-std/=../../lib/forge-std/src/",
            "spec/:helper/=src/support/",
            "external/=/another checkout/lib/",
        ], package), [
            "@plether/shared/=/workspace/packages/shared/src/",
            "forge-std/=/workspace/lib/forge-std/src/",
            "spec/:helper/=/workspace/packages/perps/src/support/",
            "external/=/another checkout/lib/",
        ])

    def test_invalid_remapping_does_not_silently_select_a_different_source_tree(self):
        for mapping in ("missing-separator", "empty/="):
            with self.assertRaises(ValueError):
                absolute_remappings([mapping], Path("/workspace/packages/perps"))


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.test_root = Path(self.temp.name)
        self.original_root = inventory_module.TEST_ROOT
        inventory_module.TEST_ROOT = self.test_root
        for name in inventory_module.PINS:
            self.add("perps/invariant/properties/" + name)
        for number in range(12):
            self.add(f"perps/spec/trader/Behavior{number}.t.sol")
        self.add("perps/fork/CfdSponsoredCloseFork.t.sol")
        self.add("perps/gas/GasProfile.t.sol")

    def tearDown(self):
        inventory_module.TEST_ROOT = self.original_root
        self.temp.cleanup()

    def add(self, path, text="pragma solidity 0.8.35; contract Example {}"):
        target = self.test_root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def test_every_nonfork_entrypoint_has_exactly_one_assignment(self):
        rows = inventory_module.inventory()
        shards = [{row["path"] for row in rows if row["shard"] == i} for i in range(4)]
        self.assertEqual(sum(map(len, shards)), len(set.union(*shards)))
        self.assertEqual(set.union(*shards), {row["path"] for row in rows if row["lane"] != "fork"})
        self.assertTrue(all(shards))

    def test_instrumentation_exclusions_keep_correctness_execution(self):
        for row in inventory_module.inventory():
            if not row["coverage"] and row["lane"] != "fork":
                self.assertIn(row["shard"], range(4))
                self.assertTrue(row["coverage_exclusion"])

    def test_missing_or_duplicate_pins_fail(self):
        name = next(iter(inventory_module.PINS))
        self.add("perps/spec/" + name)
        with self.assertRaisesRegex(ValueError, "exactly one pinned"):
            inventory_module.inventory()
        (self.test_root / "perps/spec" / name).unlink()
        (self.test_root / "perps/invariant/properties" / name).unlink()
        with self.assertRaisesRegex(ValueError, "exactly one pinned"):
            inventory_module.inventory()

    def test_multiline_entrypoint_import_fails_but_comments_do_not(self):
        self.add("perps/Fixture.sol", '// import "Old.t.sol";\nimport {\n X\n} from "Bad.t.sol";')
        with self.assertRaisesRegex(ValueError, "must not import"):
            inventory_module.inventory()
        self.add("perps/Fixture.sol", '// import "Old.t.sol";\nimport {X} from "Fixture2.sol";')
        inventory_module.inventory()

    def test_production_selector_includes_bounded_callbacks_and_descriptive_gas_tests(self):
        self.add("perps/gas/Bounds.t.sol", "contract Bounds { function test_PrefixSurvives() public {} }")
        import re
        pattern = re.compile(inventory_module.production_test_regex())
        for name in inventory_module.PRODUCTION_SENSITIVE_TESTS | {"test_PrefixSurvives"}:
            self.assertRegex(name, pattern)


class EvidenceTests(unittest.TestCase):
    def run_lane(self, status="Success", empty=False, no_skips=False, cancel=False,
                 discovery_failure=False, missing=False, missing_entrypoint=False, custom_env=None):
        temp = tempfile.TemporaryDirectory()
        directory = Path(temp.name)
        forge = directory / "forge"
        forge.write_text("""#!/usr/bin/env python3
import json, os, sys, time
if sys.argv[1] == '--version':
    print('forge mocked runner fixture')
elif sys.argv[1] == 'config':
    print(json.dumps({'fuzz': {'runs': 2000}, 'invariant': {'runs': 32, 'depth': 256}, 'cache_path': os.environ['MOCK_CACHE_PATH'], 'via_ir': False, 'etherscan_api_key': 'dotenv-credential-value', 'rpc_endpoints': {'archive': 'https://example.invalid/private-rpc-key'}}))
elif '--list' in sys.argv:
    if os.environ['MOCK_DISCOVERY_FAILURE'] == '1':
        print('compiler diagnostic on stdout')
        sys.exit(2)
    tests = ['test_behavior', 'test_missing'] if os.environ['MOCK_MISSING'] == '1' else ['test_behavior']
    print(json.dumps({'test/Example.t.sol': {'Example': tests}}))
else:
    assert '--suppress-successful-traces' in sys.argv
    result = {} if os.environ['MOCK_EMPTY'] == '1' else {'test/Example.t.sol:Example': {'test_results': {
        'test_behavior()': {'status': os.environ['MOCK_STATUS'], 'reason': 'fixture', 'duration': {'secs': 0, 'nanos': 42}}}}}
    print(json.dumps(result))
    print(os.environ['EXAMPLE_RPC_URL'], file=sys.stderr, flush=True)
    if os.environ['MOCK_SLEEP'] == '1':
        time.sleep(60)
    sys.exit(1 if os.environ['MOCK_STATUS'] == 'Failure' and os.environ.get('FORGE_ALLOW_FAILURE') != '1' else 0)
""")
        forge.chmod(0o755)
        environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                           PERPS_ARTIFACT_DIR=str(directory / "evidence"), FOUNDRY_PROFILE="ci",
                           MOCK_STATUS=status, MOCK_EMPTY=str(int(empty)),
                           MOCK_SLEEP=str(int(cancel)),
                           MOCK_CACHE_PATH=str(directory / "cache"),
                           MOCK_DISCOVERY_FAILURE=str(int(discovery_failure)), MOCK_MISSING=str(int(missing)),
                           PERPS_REQUIRE_NO_SKIPS=str(int(no_skips)),
                           EXAMPLE_RPC_URL="https://example.invalid/private-rpc-token")
        environment.update(custom_env or {})
        if missing_entrypoint:
            expected = directory / "expected.txt"
            expected.write_text("Missing.t.sol\n")
            environment["PERPS_EXPECTED_ENTRYPOINTS"] = str(expected)
        command = ["python3", str(ROOT / "scripts/run-perps-recorded.py"), "fixture", "--",
                   "forge", "test", "--root", "packages/perps"]
        if cancel:
            process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 5
            running = directory / "evidence/fixture/results.json.stderr"
            while time.monotonic() < deadline and not (running.exists() and running.stat().st_size):
                time.sleep(0.02)
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        else:
            result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True)
        output = directory / "evidence/fixture"
        metadata = json.loads((output / "run.json").read_text())
        stderr_path = output / "results.json.stderr"
        stderr = stderr_path.read_text() if stderr_path.exists() else ""
        files = {file.name for file in output.iterdir()}
        self.last_replay = (output / "replay.sh").read_text()
        self.last_config = (output / "config.json").read_text()
        temp.cleanup()
        return result, metadata, stderr, files

    def test_success_records_config_selection_results_durations_and_replay(self):
        result, metadata, stderr, files = self.run_lane()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(metadata["counts"], {"passed": 1, "failed": 0, "skipped": 0})
        self.assertEqual(metadata["budgets"]["fuzz"]["runs"], 2000)
        self.assertTrue({"config.json", "selected-tests.json", "test-durations.json", "replay.sh"} <= files)
        self.assertNotIn("private-rpc-token", stderr)
        self.assertNotIn("dotenv-credential-value", self.last_config)
        self.assertNotIn("private-rpc-key", self.last_config)

    def test_failure_is_not_hidden(self):
        result, metadata, _, _ = self.run_lane("Failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(metadata["counts"]["failed"], 1)

    def test_allowed_forge_failure_still_fails_the_recorded_gate(self):
        result, metadata, _, _ = self.run_lane("Failure", custom_env={"FORGE_ALLOW_FAILURE": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(metadata["status"], "failed")
        self.assertEqual(metadata["counts"]["failed"], 1)

    def test_empty_run_and_skipped_configured_integration_fail(self):
        self.assertNotEqual(self.run_lane(empty=True)[0].returncode, 0)
        result, metadata, _, _ = self.run_lane("Skipped", no_skips=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(metadata["counts"]["skipped"], 1)

    def test_cancellation_retains_phase_budgets_and_flushed_diagnostics(self):
        result, metadata, stderr, _ = self.run_lane(cancel=True)
        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertEqual(metadata["status"], "interrupted")
        self.assertIn("tests_started_utc", metadata)
        self.assertEqual(metadata["budgets"]["invariant"]["depth"], 256)
        self.assertIn("redacted:EXAMPLE_RPC_URL", stderr)

    def test_discovery_failure_has_diagnostics_and_replay(self):
        result, metadata, _, files = self.run_lane(discovery_failure=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(metadata["status"], "discovery_failed")
        self.assertIn("compiler diagnostic on stdout", result.stderr)
        self.assertIn("replay.sh", files)

    def test_missing_selected_test_fails_even_if_executed_tests_pass(self):
        result, metadata, _, files = self.run_lane(missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(metadata["selected_count"], 2)
        self.assertIn("execution-coverage.json", files)

    def test_assigned_entrypoint_without_discovered_tests_fails(self):
        result, metadata, _, _ = self.run_lane(missing_entrypoint=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(metadata["status"], "discovery_failed")
        self.assertEqual(metadata["entrypoint_discovery"]["missing"], ["Missing.t.sol"])

    def test_replay_relocates_owned_paths_and_preserves_explicit_external_corpus_paths(self):
        result, _, _, _ = self.run_lane(custom_env={
            "FOUNDRY_FUZZ_FAILURE_PERSIST_DIR": str(ROOT / "artifacts/owned-replay/fuzz"),
            "FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR": "/private/tmp/explicit-external-corpus",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('FOUNDRY_FUZZ_FAILURE_PERSIST_DIR="${PWD}"/artifacts/owned-replay/fuzz', self.last_replay)
        self.assertIn('FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR=/private/tmp/explicit-external-corpus', self.last_replay)
        self.assertNotIn("recorded cache", self.last_replay)


class ScratchTests(unittest.TestCase):
    def test_physical_scratch_is_stable_and_collision_does_not_delete_existing_work(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            forge = directory / "forge"
            forge.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
test = os.environ['FOUNDRY_TEST']
package = Path(sys.argv[sys.argv.index('--root') + 1]) if '--root' in sys.argv else Path('.')
if sys.argv[1] == '--version':
    print('mock forge')
elif sys.argv[1] == 'config':
    print(json.dumps({'test': test, 'cache_path': os.environ['MOCK_CACHE_PATH']}))
else:
    paths = [p.relative_to(package).as_posix() for p in (package / test).rglob('*.t.sol')]
    if '--list' in sys.argv:
        print(json.dumps({p: {'MockTest': ['test_mock']} for p in paths}))
    else:
        print(json.dumps({p + ':MockTest': {'test_results': {'test_mock()': {'status': 'Success'}}} for p in paths}))
''')
            forge.chmod(0o755)
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                       FOUNDRY_PROFILE="quick", FOUNDRY_FUZZ_SEED="0xfeed57", FOUNDRY_VIA_IR="true",
                       PERPS_ARTIFACT_DIR=str(directory / "evidence"), MOCK_CACHE_PATH=str(directory / "cache"))
            command = ["bash", str(ROOT / "scripts/run-perps-package-tests.sh"), "0", "4"]
            first = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            scratch_file = directory / "evidence/shard-0-scratch.txt"
            identity = scratch_file.read_text().strip()
            scratch = ROOT / "packages/perps" / identity
            self.assertFalse(scratch.exists())
            second = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(scratch_file.read_text().strip(), identity)
            scratch.mkdir()
            sentinel = scratch / "belongs-to-another-run"
            sentinel.write_text("preserve me")
            try:
                collision = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
                self.assertEqual(collision.returncode, 2)
                self.assertEqual(sentinel.read_text(), "preserve me")
            finally:
                sentinel.unlink()
                scratch.rmdir()


class JsonEvidenceTests(unittest.TestCase):
    def test_streaming_compaction_preserves_failures_counters_and_escaped_strings(self):
        data = {"test/Checks.t.sol:Checks": {"duration": "3ms", "test_results": {
            "invariant_pass()": {"status": "Success", "logs": ['quotes " slash \\ and unicode µ'],
                                 "kind": {"Invariant": {"runs": 256, "calls": 1000}},
                                 "traces": [{"nested": ["a" * 10000, {"brackets": "[{}]"}]}]},
            "invariant_fail()": {"status": "Failure", "traces": [{"revert": "failure evidence"}],
                                 "counterexample": {"sequence": [1, 2, 3]}}
        }}}
        output, diagnostics = io.StringIO(), io.StringIO()
        removed = compact(io.StringIO("warning before JSON\n" + json.dumps(data)), output, diagnostics, chunk_size=7)
        self.assertEqual(removed, 1)
        self.assertEqual(diagnostics.getvalue(), "warning before JSON\n")
        data["test/Checks.t.sol:Checks"]["test_results"]["invariant_pass()"]["traces"] = []
        self.assertEqual(json.loads(output.getvalue()), data)

    def test_truncated_json_is_not_a_success(self):
        for text in ('{"a":"unterminated', '{"a": [1, 2', ''):
            with self.assertRaises(ValueError):
                compact(io.StringIO(text), io.StringIO(), io.StringIO(), chunk_size=3)


if __name__ == "__main__":
    unittest.main()
