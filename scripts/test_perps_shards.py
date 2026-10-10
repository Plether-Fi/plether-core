#!/usr/bin/env python3
"""Exercise physical shard selection, execution, and evidence without compiling Solidity."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"
spec = importlib.util.spec_from_file_location("perps_inventory", SCRIPTS / "perps-test-inventory.py")
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)
PINNED = {f"perps/invariant/properties/{name}": shard for name, shard in inventory.PINS.items()}
SETTINGS = {
    "FOUNDRY_PROFILE": "ci",
    "FOUNDRY_FUZZ_SEED": "0xdeadbeef",
    "FOUNDRY_VIA_IR": "true",
}


class PerpsShardRunnerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / "packages/perps"
        self.tests = self.package / "test"
        self.runner = self.root / "scripts/run-perps-package-tests.sh"
        self.runner.parent.mkdir(parents=True)
        for name in ("run-perps-package-tests.sh", "perps-test-inventory.py", "perps-shard-weights.json",
                     "run-perps-recorded.py", "perps_forge_json.py", "run-perps-fast-tests.sh",
                     "check-perps-pr-selection.py"):
            shutil.copyfile(SCRIPTS / name, self.runner.parent / name)
        # Exercise the real filename inventory, including newly added entrypoints.
        self.entrypoints = {
            path.relative_to(REPO / "packages/perps/test").as_posix()
            for path in (REPO / "packages/perps/test").rglob("*.t.sol")
        }
        self.forks = {path for path in self.entrypoints if "fork" in Path(path).parts}
        for relative in self.entrypoints:
            self.write_source(relative, "// Test entrypoint\n")
        self.write_source("support/Shared.sol", "// Shared non-entrypoint helper\n")
        self.log = self.root / "forge-invocations.jsonl"
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake_forge = fake_bin / "forge"
        fake_forge.write_text('''#!/usr/bin/env python3
import json, os, pathlib, re, sys
args = sys.argv[1:]
if args == ['--version']:
    print('forge mocked shard fixture')
    sys.exit(0)
package = pathlib.Path(args[args.index('--root') + 1])
test = package / os.environ['FOUNDRY_TEST']
files = sorted(str(p.relative_to(test)) for p in test.rglob('*') if p.is_file())
record = {'args': args, 'test': str(test), 'files': files,
          'settings': {k: v for k, v in os.environ.items() if k.startswith('FOUNDRY_')}}
with open(os.environ['SHARD_TEST_LOG'], 'a') as out:
    out.write(json.dumps(record) + '\\n')
if args[0] == 'config':
    print(json.dumps({'fuzz': {'runs': 2000}, 'invariant': {'runs': 32, 'depth': 256},
                      'via_ir': os.environ.get('FOUNDRY_VIA_IR') == 'true', 'cache_path': 'cache', 'test': os.environ['FOUNDRY_TEST']}))
    sys.exit(0)
entrypoints = [p for p in files if p.endswith('.t.sol')]
if os.environ.get('SHARD_TEST_EMPTY_ENTRYPOINT') == '1':
    entrypoints = entrypoints[1:]
paths = [str((test / p).relative_to(package)) for p in entrypoints]
names = ['test_behavior']
if os.environ.get('SHARD_TEST_PR') == '1':
    names += ['test_gas_budget']
    for flag, keep in [('--match-test', True), ('--no-match-test', False)]:
        if flag in args:
            pattern = args[args.index(flag) + 1]
            names = [n for n in names if bool(re.search(pattern, n)) == keep]
    if os.environ.get('SHARD_TEST_DROP_CORRECTNESS') == '1' and '--no-match-test' in args:
        paths = paths[1:]
if '--list' in args:
    print(json.dumps({p: {'Example': names} for p in paths}))
    sys.exit(0)
print(json.dumps({p + ':Example': {'test_results': {
    name + '()': {'status': 'Success', 'duration': {'secs': 0, 'nanos': 1}} for name in names
}} for p in paths}))
sys.exit(int(os.environ.get('SHARD_TEST_EXIT', '0')))
''')
        fake_forge.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("FOUNDRY_", "FORGE_", "PERPS_"))}
        self.env.update(SETTINGS)
        self.env.update(PATH=str(fake_bin) + os.pathsep + os.environ["PATH"], SHARD_TEST_LOG=str(self.log),
                        PYTHONDONTWRITEBYTECODE="1")

    def write_source(self, relative, content):
        path = self.tests / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def run_shard(self, index, count=4, **environment):
        return subprocess.run(
            ["bash", str(self.runner), str(index), str(count)], cwd=self.root,
            env=dict(self.env, **environment), capture_output=True, text=True,
        )

    def invocations(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def executions(self):
        return [call for call in self.invocations() if call["args"][0] == "test" and "--list" not in call["args"]]

    def assert_cleaned(self):
        self.assertEqual(list(self.package.glob(".package-test-shard.*")), [])

    def assignments(self):
        actual = {}
        for shard in range(4):
            result = self.run_shard(shard, PERPS_SHARD_LIST_ONLY="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            for entrypoint in result.stdout.splitlines():
                self.assertNotIn(entrypoint, actual)
                actual[entrypoint] = shard
        self.assertEqual(set(actual), self.entrypoints - self.forks)
        for entrypoint, shard in PINNED.items():
            self.assertEqual(actual[entrypoint], shard)
        self.assert_cleaned()
        return actual

    def test_every_eligible_entrypoint_runs_once_in_one_unfiltered_execution_per_shard(self):
        seen = set()
        for shard in range(4):
            with self.subTest(shard=shard):
                result = self.run_shard(shard)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.executions()
                self.assertEqual(len(calls), shard + 1)
                call = calls[-1]
                self.assertEqual(call["args"], ["test", "--offline", "-vvv", "--root", str(self.package),
                                                "--json", "--suppress-successful-traces"])
                for key, value in SETTINGS.items():
                    self.assertEqual(call["settings"][key], value)
                for key in ("FOUNDRY_FUZZ_RUNS", "FOUNDRY_INVARIANT_RUNS", "FOUNDRY_INVARIANT_DEPTH"):
                    self.assertNotIn(key, call["settings"])
                assigned = {path for path in call["files"] if path.endswith(".t.sol")}
                self.assertTrue(assigned)
                self.assertFalse(seen & assigned)
                self.assertFalse(assigned & self.forks)
                seen.update(assigned)
                for entrypoint, expected_shard in PINNED.items():
                    self.assertEqual(entrypoint in assigned, shard == expected_shard)
                self.assertIn("support/Shared.sol", call["files"])
                self.assertFalse(Path(call["test"]).exists())
                evidence = self.root / f"artifacts/perps/shard-{shard}"
                metadata = json.loads((evidence / "run.json").read_text())
                self.assertEqual(metadata["counts"], {"passed": len(assigned), "failed": 0, "skipped": 0})
                self.assertEqual(metadata["budgets"]["invariant"], {"runs": 32, "depth": 256})
                coverage = json.loads((evidence / "execution-coverage.json").read_text())
                self.assertEqual(coverage["selected"], coverage["executed"])
                self.assertEqual(coverage["not_run"], [])
                self.assertEqual(coverage["unexpected_results"], [])
                self.assert_cleaned()
        self.assertEqual(seen, self.entrypoints - self.forks)

    def test_pr_shards_preserve_exact_partition_codegen_budgets_and_replay(self):
        seen = set()
        for shard in range(4):
            result = self.run_shard(shard, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            production, correctness = self.executions()[-2:]
            self.assertEqual(production["settings"]["FOUNDRY_VIA_IR"], "true")
            self.assertEqual(correctness["settings"]["FOUNDRY_VIA_IR"], "false")
            for call in (production, correctness):
                self.assertEqual(call["args"][call["args"].index("--threads") + 1], "1")
                self.assertEqual(call["settings"]["FOUNDRY_PROFILE"], "ci")
                self.assertEqual(call["settings"]["FOUNDRY_FUZZ_SEED"], "0xdeadbeef")
                for setting in ("FOUNDRY_FUZZ_RUNS", "FOUNDRY_INVARIANT_RUNS", "FOUNDRY_INVARIANT_DEPTH"):
                    self.assertNotIn(setting, call["settings"])
            assigned = {p for p in production["files"] if p.endswith(".t.sol")}
            self.assertEqual(assigned, {p for p in correctness["files"] if p.endswith(".t.sol")})
            self.assertFalse(seen & assigned)
            seen.update(assigned)
            evidence = self.root / "artifacts/perps"
            partition = json.loads((evidence / "pr-selection.json").read_text())
            self.assertEqual(partition["discovered"], 2 * len(assigned))
            for field in ("missing", "unexpected", "overlap", "missing_entrypoints"):
                self.assertEqual(partition[field], [])
            for lane in ("production-gates", "correctness"):
                replay = (evidence / lane / "replay.sh").read_text()
                self.assertIn(f"PERPS_SHARD_MODE=pr bash scripts/run-perps-package-tests.sh {shard} 4", replay)
            self.assert_cleaned()
        self.assertEqual(seen, self.entrypoints - self.forks)

    def test_pr_replay_keeps_source_identity_from_either_lane(self):
        identities = []
        for via_ir in ("true", "false"):
            result = self.run_shard(0, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1", FOUNDRY_VIA_IR=via_ir)
            self.assertEqual(result.returncode, 0, result.stderr)
            identities.append((self.root / "artifacts/perps/shard-0-scratch.txt").read_text())
        self.assertEqual(identities[0], identities[1])
        self.assert_cleaned()

    def test_pr_partition_rejects_tests_dropped_from_both_filtered_lanes(self):
        result = self.run_shard(0, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1", SHARD_TEST_DROP_CORRECTNESS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not an exact discovery partition", result.stderr)
        partition = json.loads((self.root / "artifacts/perps/pr-selection.json").read_text())
        self.assertTrue(partition["missing"])
        self.assert_cleaned()

    def test_pr_partition_rejects_overlapping_lanes(self):
        # The baseline fake Forge deliberately ignores filters: both lanes report
        # the same test. An apparent pair of passes must not satisfy the gate.
        result = self.run_shard(0, PERPS_SHARD_MODE="pr")
        self.assertNotEqual(result.returncode, 0)
        partition = json.loads((self.root / "artifacts/perps/pr-selection.json").read_text())
        self.assertTrue(partition["overlap"])
        self.assert_cleaned()

    def test_list_only_preserves_executed_inventory_without_running_forge(self):
        for shard in range(4):
            with self.subTest(shard=shard):
                count = len(self.invocations())
                listed = self.run_shard(shard, PERPS_SHARD_LIST_ONLY="1")
                self.assertEqual(listed.returncode, 0, listed.stderr)
                self.assertEqual(len(self.invocations()), count)
                executed = self.run_shard(shard)
                self.assertEqual(executed.returncode, 0, executed.stderr)
                files = {p for p in self.executions()[-1]["files"] if p.endswith(".t.sol")}
                self.assertEqual(set(listed.stdout.splitlines()), files)
                self.assert_cleaned()

    def test_weighted_assignments_and_pins_survive_inventory_changes(self):
        first = self.assignments()
        self.assertEqual(first, self.assignments())
        for index in range(4):
            path = f"perps/spec/trader/NewBehavior{index}.t.sol"
            self.write_source(path, "// Additional test entrypoint\n")
            self.entrypoints.add(path)
            changed = self.assignments()
            self.assertEqual(changed, self.assignments())
        self.assertEqual(self.invocations(), [])

    def test_forge_failure_is_propagated_without_retry_and_scratch_is_cleaned(self):
        result = self.run_shard(0, SHARD_TEST_EXIT="19")
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(len(self.executions()), 1)
        self.assert_cleaned()

    def test_invalid_shard_requests_never_invoke_forge(self):
        for index, count in ((4, 4), (0, 3), ("x", 4), (-1, 4), (0, 0)):
            with self.subTest(index=index, count=count):
                self.assertEqual(self.run_shard(index, count).returncode, 2)
                self.assertEqual(self.invocations(), [])
                self.assert_cleaned()

    def test_missing_pinned_suite_is_rejected(self):
        (self.tests / next(iter(PINNED))).unlink()
        result = self.run_shard(0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected exactly one pinned entrypoint", result.stderr)
        self.assertEqual(self.invocations(), [])
        self.assert_cleaned()

    def test_imported_test_entrypoint_is_rejected_before_sharding(self):
        self.write_source("support/Shared.sol", 'import "../perps/invariant/properties/PerpInvariant.t.sol";\n')
        result = self.run_shard(0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not import .t.sol entrypoints", result.stderr)
        self.assertEqual(self.invocations(), [])
        self.assert_cleaned()

    def test_missing_discovered_entrypoint_fails_before_execution(self):
        result = self.run_shard(0, SHARD_TEST_EMPTY_ENTRYPOINT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.executions(), [])
        self.assert_cleaned()

    def test_replay_source_paths_are_stable_and_foreign_scratch_is_preserved(self):
        self.assertEqual(self.run_shard(0).returncode, 0)
        first = self.executions()[-1]["test"]
        self.assertEqual(self.run_shard(0).returncode, 0)
        self.assertEqual(first, self.executions()[-1]["test"])
        scratch = Path(first).parent
        scratch.mkdir()
        marker = scratch / "owned-by-other-run"
        marker.write_text("keep")
        result = self.run_shard(0)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Shard scratch already exists", result.stderr)
        self.assertEqual(len(self.executions()), 2)
        self.assertEqual(marker.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
