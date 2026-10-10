#!/usr/bin/env python3
"""Exercise physical shard coverage and command execution without compiling Solidity."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
RUNNER = REPO / "scripts/run-perps-package-tests.sh"
PINNED = {
    "perps/invariant/PerpAccountingInvariant.t.sol": 0,
    "perps/PerpInvariant.t.sol": 1,
    "perps/invariant/PerpEconomicConservationInvariant.t.sol": 2,
    "perps/invariant/PerpValueConservationInvariant.t.sol": 2,
    "perps/invariant/PerpPreviewInvariant.t.sol": 3,
    "perps/invariant/PerpClosePreviewParityInvariant.t.sol": 3,
    "perps/invariant/PerpMultiAccountInvariant.t.sol": 3,
    "perps/invariant/PerpHousePoolLifecycleInvariant.t.sol": 3,
}
SETTINGS = {
    "FOUNDRY_PROFILE": "ci",
    "FOUNDRY_FUZZ_SEED": "0xdeadbeef",
    "FOUNDRY_INVARIANT_RUNS": "16",
    "FOUNDRY_INVARIANT_DEPTH": "500",
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
        shutil.copyfile(RUNNER, self.runner)
        # Use the real filename inventory so new entrypoints must also be covered.
        self.entrypoints = {
            path.relative_to(REPO / "packages/perps/test").as_posix()
            for path in (REPO / "packages/perps/test").rglob("*.t.sol")
        }
        for relative in self.entrypoints:
            self.write_source(relative, "// Test entrypoint\n")
        self.write_source("support/Shared.sol", "// Shared non-entrypoint helper\n")
        self.log = self.root / "forge-invocations.jsonl"
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake_forge = fake_bin / "forge"
        fake_forge.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "package = pathlib.Path(args[args.index('--root') + 1])\n"
            "test = package / os.environ['FOUNDRY_TEST']\n"
            "record = {'args': args, 'test': str(test),\n"
            " 'files': sorted(str(p.relative_to(test)) for p in test.rglob('*') if p.is_file()),\n"
            " 'settings': {k: v for k, v in os.environ.items() if k.startswith('FOUNDRY_')}}\n"
            "with open(os.environ['SHARD_TEST_LOG'], 'a') as out:\n"
            " out.write(json.dumps(record) + '\\n')\n"
            "sys.exit(int(os.environ.get('SHARD_TEST_EXIT', '0')))\n"
        )
        fake_forge.chmod(0o755)
        self.env = dict(os.environ, **SETTINGS)
        self.env.update(PATH=str(fake_bin) + os.pathsep + os.environ["PATH"], SHARD_TEST_LOG=str(self.log))
        self.env.pop("PERPS_SHARD_LIST_ONLY", None)

    def write_source(self, relative, content):
        path = self.tests / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def run_shard(self, index, count=4, **environment):
        return subprocess.run(
            ["bash", str(self.runner), str(index), str(count)],
            cwd=self.root,
            env=dict(self.env, **environment),
            capture_output=True,
            text=True,
        )

    def invocations(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_cleaned(self):
        self.assertEqual(list(self.package.glob(".package-test-shard.*")), [])

    def test_every_entrypoint_runs_once_in_one_unfiltered_call_per_shard(self):
        seen = set()
        for shard in range(4):
            with self.subTest(shard=shard):
                result = self.run_shard(shard)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.invocations()
                self.assertEqual(len(calls), shard + 1)
                call = calls[-1]
                self.assertEqual(call["args"], ["test", "--offline", "-vvv", "--root", str(self.package)])
                for key, value in SETTINGS.items():
                    self.assertEqual(call["settings"][key], value)
                assigned = {path for path in call["files"] if path.endswith(".t.sol")}
                self.assertTrue(assigned)
                self.assertFalse(seen & assigned)
                self.assertTrue(assigned <= self.entrypoints)
                seen.update(assigned)
                for entrypoint, expected_shard in PINNED.items():
                    self.assertEqual(entrypoint in assigned, shard == expected_shard)
                self.assertIn("support/Shared.sol", call["files"])
                self.assertFalse(Path(call["test"]).exists())
                self.assert_cleaned()
        self.assertEqual(seen, self.entrypoints)

    def test_list_only_preserves_the_executed_inventory_without_running_forge(self):
        for shard in range(4):
            with self.subTest(shard=shard):
                listed = self.run_shard(shard, PERPS_SHARD_LIST_ONLY="1")
                self.assertEqual(listed.returncode, 0, listed.stderr)
                self.assertEqual(len(self.invocations()), shard)
                executed = self.run_shard(shard)
                self.assertEqual(executed.returncode, 0, executed.stderr)
                files = {path for path in self.invocations()[-1]["files"] if path.endswith(".t.sol")}
                self.assertEqual(set(listed.stdout.splitlines()), files)
                self.assert_cleaned()

    def test_forge_failure_is_propagated_without_retry_and_worktree_is_cleaned(self):
        result = self.run_shard(0, SHARD_TEST_EXIT="19")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(len(self.invocations()), 1)
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
        self.assertEqual(result.returncode, 2)
        self.assertIn("required pinned perps test entrypoint is missing", result.stderr)
        self.assertEqual(self.invocations(), [])
        self.assert_cleaned()

    def test_imported_test_entrypoint_is_rejected_before_sharding(self):
        self.write_source("support/Shared.sol", 'import "../perps/PerpInvariant.t.sol";\n')
        result = self.run_shard(0)
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not support imports of .t.sol entrypoints", result.stderr)
        self.assertEqual(self.invocations(), [])
        self.assert_cleaned()


if __name__ == "__main__":
    unittest.main()
