#!/usr/bin/env python3
"""Exercise physical shard selection, execution, and evidence without compiling Solidity."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
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
        shutil.copyfile(REPO / 'Makefile', self.root / 'Makefile')
        for name in ("run-perps-package-tests.sh", "perps-test-inventory.py", "perps-shard-weights.json",
                     "run-perps-recorded.py", "perps_forge_json.py", "run-perps-fast-tests.sh",
                     "check-perps-pr-selection.py", "run-perps-batched.py", "run-perps-fast-batch.sh"):
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
import json, os, pathlib, re, sys, time
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
    fuzz, runs, depth = {'quick': (256, 16, 128), 'ci': (2000, 32, 256), 'audit': (20000, 256, 1000)}[os.environ['FOUNDRY_PROFILE']]
    print(json.dumps({'fuzz': {'runs': fuzz}, 'invariant': {'runs': runs, 'depth': depth},
                      'via_ir': os.environ.get('FOUNDRY_VIA_IR') == 'true', 'cache_path': 'cache', 'test': os.environ['FOUNDRY_TEST']}))
    sys.exit(0)
entrypoints = [p for p in files if p.endswith('.t.sol')]
if os.environ.get('SHARD_TEST_EMPTY_ENTRYPOINT') == '1':
    entrypoints = entrypoints[1:]
paths = [str((test / p).relative_to(package)) for p in entrypoints]
if os.environ.get('SHARD_TEST_EXTRA_SOURCE') == '1':
    paths.append(str((test / 'UnexpectedCached.t.sol').relative_to(package)))
skips = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == '--skip']
paths = [p for p in paths if not any(skip in pathlib.Path(p).name for skip in skips)]
names = ['test_behavior']
if os.environ.get('SHARD_TEST_PR') == '1':
    names += ['test_gas_budget']
    if 'SHARD_TEST_ONLY_TEST' in os.environ:
        names = [n for n in names if n == os.environ['SHARD_TEST_ONLY_TEST']]
    for flag, keep in [('--match-test', True), ('--no-match-test', False)]:
        if flag in args and os.environ.get('SHARD_TEST_IGNORE_FILTERS') != '1':
            pattern = args[args.index(flag) + 1]
            names = [n for n in names if bool(re.search(pattern, n)) == keep]
    if os.environ.get('SHARD_TEST_DROP_CORRECTNESS') == '1' and '--no-match-test' in args:
        paths = paths[1:]
tests_by_path = {p: names for p in paths}
if os.environ.get('SHARD_TEST_GAS_SOURCE'):
    tests_by_path = {p: [n for n in names if n != 'test_gas_budget' or p.endswith(os.environ['SHARD_TEST_GAS_SOURCE'])]
                     for p in paths}
if '--list' in args:
    print(json.dumps({p: {'Example': tests_by_path[p]} for p in paths}))
    sys.exit(0)
if not names:
    print('No tests found in project!')
    sys.exit(0)
if os.environ.get('SHARD_TEST_SLEEP') == '1':
    time.sleep(60)
print(json.dumps({p + ':Example': {'test_results': {
    name + '()': {'status': 'Success', 'duration': {'secs': 0, 'nanos': 1}} for name in tests_by_path[p]
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

    def test_full_shards_bound_compilation_and_execute_every_entrypoint_once(self):
        seen = set()
        for shard in range(4):
            with self.subTest(shard=shard):
                before = len(self.executions())
                result = self.run_shard(shard)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.executions()[before:]
                assigned = set()
                for call in calls:
                    self.assertEqual(call["args"], ["test", "--offline", "--threads", "1", "-vvv",
                                                    "--skip", "script", "--root", str(self.package.resolve()),
                                                    "--json", "--suppress-successful-traces"])
                    for key, value in SETTINGS.items():
                        self.assertEqual(call["settings"][key], value)
                    for key in ("FOUNDRY_FUZZ_RUNS", "FOUNDRY_INVARIANT_RUNS", "FOUNDRY_INVARIANT_DEPTH"):
                        self.assertNotIn(key, call["settings"])
                    batch = {path for path in call["files"] if path.endswith(".t.sol")}
                    self.assertGreater(len(batch), 0)
                    self.assertLessEqual(len(batch), 4)
                    self.assertFalse(assigned & batch)
                    assigned.update(batch)
                    self.assertIn("support/Shared.sol", call["files"])
                    self.assertFalse(Path(call["test"]).exists())
                self.assertTrue(assigned)
                self.assertFalse(seen & assigned)
                self.assertFalse(assigned & self.forks)
                seen.update(assigned)
                for entrypoint, expected_shard in PINNED.items():
                    self.assertEqual(entrypoint in assigned, shard == expected_shard)
                evidence = self.root / f"artifacts/perps/shard-{shard}"
                metadata = json.loads((evidence / "run.json").read_text())
                self.assertEqual(metadata["counts"], {"passed": len(assigned), "failed": 0, "skipped": 0})
                self.assertEqual(metadata["budgets"]["invariant"], {"runs": 32, "depth": 256})
                self.assertEqual(metadata["status"], "passed")
                self.assertEqual(set(metadata["completed_entrypoints"]), assigned)
                for record in metadata["batches"]:
                    coverage = json.loads((evidence / record["lane"] / "execution-coverage.json").read_text())
                    self.assertEqual(coverage["selected"], coverage["executed"])
                    self.assertEqual(coverage["not_run"], [])
                    self.assertEqual(coverage["unexpected_results"], [])
                    replay = (evidence / record["lane"] / "replay.sh").read_text()
                    self.assertIn("PERPS_COMPILE_BATCH_SIZE=4 bash scripts/run-perps-package-tests.sh", replay)
                self.assert_cleaned()
        self.assertEqual(seen, self.entrypoints - self.forks)

    def batch_roots(self):
        return sorted((self.root / "artifacts/perps/fast").glob("batch-*/pr-selection.json"))

    def test_pr_shards_preserve_exact_partition_codegen_budgets_and_replay(self):
        seen = set()
        for shard in range(4):
            before = len(self.executions())
            result = self.run_shard(shard, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = self.executions()[before:]
            assigned = set()
            for call in calls:
                self.assertEqual(call["args"][call["args"].index("--threads") + 1], "1")
                self.assertEqual(call["settings"]["FOUNDRY_PROFILE"], "ci")
                self.assertEqual(call["settings"]["FOUNDRY_FUZZ_SEED"], "0xdeadbeef")
                batch = {p for p in call["files"] if p.endswith(".t.sol")}
                self.assertLessEqual(len(batch), 4)
                if '--no-match-test' in call['args']:
                    self.assertEqual(call["settings"]["FOUNDRY_VIA_IR"], "false")
                    self.assertFalse(assigned & batch)
                    assigned.update(batch)
                else:
                    self.assertEqual(call["settings"]["FOUNDRY_VIA_IR"], "true")
                for setting in ("FOUNDRY_FUZZ_RUNS", "FOUNDRY_INVARIANT_RUNS", "FOUNDRY_INVARIANT_DEPTH"):
                    self.assertNotIn(setting, call["settings"])
            self.assertFalse(seen & assigned)
            seen.update(assigned)
            partition = json.loads((self.root / "artifacts/perps/pr-selection.json").read_text())
            self.assertEqual(partition["discovered"], 2 * len(assigned))
            self.assertEqual(partition["failed_batches"], [])
            for field in ("missing", "unexpected", "overlap", "missing_entrypoints", "unexpected_entrypoints"):
                self.assertEqual(partition[field], [])
            # Inspect only the current manifest: prior invocations may leave historical batch artifacts.
            manifest = json.loads((self.root / "artifacts/perps/fast/run.json").read_text())
            for batch in manifest['batches']:
                directory = self.root / 'artifacts/perps/fast' / batch['lane']
                for lane in ("production-gates", "correctness"):
                    replay = (directory / lane / "replay.sh").read_text()
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

    def test_make_fast_target_batches_all_discovery_and_preserves_quick_budgets(self):
        source = 'perps/gas/GasProfile.t.sol'
        result = subprocess.run(['make', 'test-perps'], cwd=self.root,
                                env=dict(self.env, SHARD_TEST_PR='1', SHARD_TEST_GAS_SOURCE=source),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        discovered = [c for c in self.invocations() if '--list' in c['args']]
        self.assertGreater(len(discovered), 1)
        seen = set()
        for call in discovered:
            files = {p for p in call['files'] if p.endswith('.t.sol')}
            self.assertLessEqual(len(files), 4)
            self.assertFalse(seen & files)
            seen.update(files)
            self.assertEqual(call['settings']['FOUNDRY_VIA_IR'], 'false')
            self.assertEqual(call['settings']['FOUNDRY_PROFILE'], 'quick')
        self.assertEqual(seen, self.entrypoints - self.forks)
        production = [c for c in self.executions() if c['settings']['FOUNDRY_VIA_IR'] == 'true']
        self.assertEqual(len(production), 1)
        report = json.loads((self.root / 'artifacts/perps/pr-selection.json').read_text())
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['completed_entrypoints'], len(seen))
        self.assertEqual(report['discovered'], len(seen) + 1)
        manifest = json.loads((self.root / 'artifacts/perps/fast/run.json').read_text())
        self.assertEqual(manifest['budgets'], {'fuzz': {'runs': 256}, 'invariant': {'runs': 16, 'depth': 128}})
        replay = self.root / 'artifacts/perps/fast/batch-000/correctness/replay.sh'
        command = next(line for line in replay.read_text().splitlines() if line.startswith('export PERPS_ARTIFACT_DIR='))
        destination = subprocess.check_output(['bash', '-c', command + '\nprintf "%s" "$PERPS_ARTIFACT_DIR"'],
                                              env=dict(os.environ, replay_dir=str(replay.parent)), text=True)
        self.assertEqual(Path(destination).resolve(), (self.root / 'artifacts/perps').resolve())
        self.assert_cleaned()

    def cancel_fast(self, command, environment):
        process = subprocess.Popen(command, cwd=self.root,
                                   env=dict(self.env, SHARD_TEST_SLEEP='1', **environment),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        active = self.root / 'artifacts/perps/fast/batch-000/correctness/run.json'
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and process.poll() is None:
            try:
                if active.exists() and json.loads(active.read_text())['status'] == 'running':
                    break
            except json.JSONDecodeError:
                pass
            time.sleep(0.05)
        else:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=10)
            self.fail('fast run never reached execution')
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        report = json.loads((self.root / 'artifacts/perps/pr-selection.json').read_text())
        self.assertEqual(report['status'], 'interrupted')
        self.assertEqual(report['completed_entrypoints'], 0)
        self.assert_cleaned()

    def test_fast_cancellation_records_interruption_and_cleans_scratch(self):
        self.cancel_fast(['bash', str(self.runner), '2', '4'], {'PERPS_SHARD_MODE': 'pr'})

    def test_local_make_cancellation_cleans_owned_scratch(self):
        self.cancel_fast(['make', 'test-perps'], {})

    def test_fast_rejects_unassigned_cached_entrypoints(self):
        result = self.run_shard(2, PERPS_SHARD_MODE='pr', SHARD_TEST_EXTRA_SOURCE='1')
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.root / 'artifacts/perps/pr-selection.json').read_text())
        self.assertEqual(report['status'], 'failed')
        self.assertTrue(report['unexpected_entrypoints'])
        self.assertTrue(report['failed_batches'])
        self.assert_cleaned()

    def test_pr_partition_allows_one_empty_lane_and_executes_every_selected_test(self):
        for only_test, empty_lane in (("test_behavior", "production-gates"),
                                      ("test_gas_budget", "correctness")):
            with self.subTest(empty_lane=empty_lane):
                before = len(self.executions())
                result = self.run_shard(0, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1",
                                        SHARD_TEST_ONLY_TEST=only_test)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertGreater(len(self.executions()), before)
                evidence = self.root / "artifacts/perps"
                partition = json.loads((evidence / "pr-selection.json").read_text())
                self.assertGreater(partition["discovered"], 0)
                self.assertEqual(partition["production"] + partition["correctness"], partition["discovered"])
                for batch in (evidence / 'fast').glob('batch-*'):
                    if not batch.is_dir():
                        continue
                    metadata = json.loads((batch / empty_lane / "run.json").read_text())
                    self.assertEqual(metadata["execution_skipped_reason"], "empty_partition")
                    self.assertEqual(list((batch / empty_lane).glob("results.*")), [])
                for field in ("missing", "unexpected", "overlap", "missing_entrypoints"):
                    self.assertEqual(partition[field], [])
                self.assert_cleaned()

    def test_pr_partition_rejects_an_entirely_empty_shard(self):
        result = self.run_shard(0, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1", SHARD_TEST_ONLY_TEST="none")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not an exact discovery partition", result.stderr)
        self.assertEqual(self.executions(), [])
        self.assert_cleaned()

    def test_pr_compiles_only_discovered_production_sources_with_via_ir(self):
        listed = self.run_shard(0, PERPS_SHARD_LIST_ONLY="1")
        self.assertEqual(listed.returncode, 0, listed.stderr)
        assigned = listed.stdout.splitlines()
        # The source has no declared functions: discovery also captures inherited tests.
        required = assigned[0]
        result = self.run_shard(0, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1", SHARD_TEST_GAS_SOURCE=required)
        self.assertEqual(result.returncode, 0, result.stderr)
        unfiltered = next(call for call in self.invocations() if '--list' in call['args'])
        self.assertEqual(unfiltered['settings']['FOUNDRY_VIA_IR'], 'false')
        productions = [c for c in self.executions() if c['settings']['FOUNDRY_VIA_IR'] == 'true']
        self.assertEqual(len(productions), 1)
        args = productions[0]['args']
        skips = {args[i + 1] for i, arg in enumerate(args[:-1]) if arg == '--skip'}
        self.assertIn('script', skips)
        self.assertFalse(any(skip in Path(required).name for skip in skips))
        # No optimized discovery invocation is needed, including for empty production batches.
        self.assertTrue(all(c['settings']['FOUNDRY_VIA_IR'] == 'false'
                            for c in self.invocations() if '--list' in c['args']))
        partition = json.loads((self.root / 'artifacts/perps/pr-selection.json').read_text())
        self.assertEqual(partition['production'], 1)
        self.assertEqual(partition['correctness'], len(assigned))
        self.assert_cleaned()

    def test_pr_partition_rejects_tests_dropped_from_both_filtered_lanes(self):
        result = self.run_shard(0, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1", SHARD_TEST_DROP_CORRECTNESS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Discovery/result mismatch", result.stderr)
        manifest = json.loads((self.root / "artifacts/perps/fast/run.json").read_text())
        self.assertEqual(manifest["status"], "failed")
        self.assertTrue(manifest['selection']['failed_batches'])
        self.assert_cleaned()

    def test_pr_partition_rejects_overlapping_lanes(self):
        # Deliberately ignore function filters: both lanes report
        # the same test. An apparent pair of passes must not satisfy the gate.
        result = self.run_shard(0, PERPS_SHARD_MODE="pr", SHARD_TEST_PR="1", SHARD_TEST_IGNORE_FILTERS="1")
        self.assertNotEqual(result.returncode, 0)
        partition = json.loads((self.root / "artifacts/perps/pr-selection.json").read_text())
        self.assertTrue(partition["failed_batches"])
        self.assert_cleaned()

    def test_list_only_preserves_executed_inventory_without_running_forge(self):
        for shard in range(4):
            with self.subTest(shard=shard):
                count = len(self.invocations())
                listed = self.run_shard(shard, PERPS_SHARD_LIST_ONLY="1")
                self.assertEqual(listed.returncode, 0, listed.stderr)
                self.assertEqual(len(self.invocations()), count)
                before = len(self.executions())
                executed = self.run_shard(shard)
                self.assertEqual(executed.returncode, 0, executed.stderr)
                files = {p for call in self.executions()[before:] for p in call["files"] if p.endswith(".t.sol")}
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
        metadata = json.loads((self.root / "artifacts/perps/shard-0/run.json").read_text())
        self.assertEqual(metadata["status"], "failed")
        self.assertEqual(metadata["completed_entrypoints"], [])
        self.assertGreater(len(self.executions()), 1)
        self.assert_cleaned()

    def test_batch_size_validation_and_replay(self):
        for value in ("0", "-1", "invalid"):
            result = self.run_shard(0, PERPS_COMPILE_BATCH_SIZE=value)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(self.invocations(), [])
            self.assert_cleaned()
        result = self.run_shard(2, PERPS_COMPILE_BATCH_SIZE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in self.executions():
            self.assertEqual(len([p for p in call["files"] if p.endswith(".t.sol")]), 1)
        replay = (self.root / "artifacts/perps/shard-2/batch-000/replay.sh").read_text()
        self.assertIn("PERPS_COMPILE_BATCH_SIZE=1", replay)
        export_command = next(line for line in replay.splitlines() if line.startswith("export PERPS_ARTIFACT_DIR="))
        artifact_root = subprocess.check_output(
            ["bash", "-c", export_command + '\nprintf "%s" "$PERPS_ARTIFACT_DIR"'], text=True,
            env=dict(os.environ, replay_dir=str(self.root / "artifacts/perps/shard-2/batch-000")),
        )
        self.assertEqual(Path(artifact_root).resolve(), (self.root / "artifacts/perps").resolve())
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
        count = len(self.executions())
        scratch = Path(first).parent
        scratch.mkdir()
        marker = scratch / "owned-by-other-run"
        marker.write_text("keep")
        result = self.run_shard(0)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Shard scratch already exists", result.stderr)
        self.assertEqual(len(self.executions()), count)
        self.assertEqual(marker.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
