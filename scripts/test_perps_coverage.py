"""Exercise the real coverage wrapper's physical partition and failure handling without solc."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CoverageBatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="perps coverage ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.package = self.root / "packages/perps"
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.evidence = self.root / "evidence"
        self.report = self.root / "merged.info"
        self.calls = self.root / "calls.jsonl"
        self.paths = [f"perps/spec/Scenario{i}.t.sol" for i in range(9)]
        for relative in self.paths + ["perps/spec/Excluded.t.sol", "perps/shared/Fixture.sol"]:
            source = self.package / "test" / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("// physical fixture\n")
        for name in ("run-perps-coverage.sh", "perps_coverage_config.py"):
            shutil.copyfile(ROOT / "scripts" / name, self.scripts / name)
        (self.scripts / "perps-test-inventory.py").write_text(
            "import json,sys\n"
            f"paths={self.paths!r}\n"
            "print('testFuzz_|invariant_' if '--coverage-exclusion-regex' in sys.argv else "
            "'\\n'.join(paths) if '--format' in sys.argv else json.dumps({'entrypoints':paths}))\n"
        )
        (self.scripts / "run-perps-recorded.py").write_text(
            "from pathlib import Path\nimport sys\n"
            "Path(sys.argv[2]).write_text('{\"remappings\": []}')\n"
        )
        self.executable("git", "print('a' * 40)\n")
        self.executable("forge", """
import json,os,sys
from pathlib import Path
if sys.argv[1]=='--version':
    print('forge coverage fixture')
    sys.exit(0)
assert sys.argv[1]=='coverage'
args=sys.argv[2:]
package=Path(args[args.index('--root')+1])
test=package/os.environ['FOUNDRY_TEST']
paths=sorted(p.relative_to(test).as_posix() for p in test.rglob('*.t.sol'))
assert (test/'perps/shared/Fixture.sol').is_file()
calls=Path(os.environ['MOCK_CALLS'])
prior=calls.read_text().splitlines() if calls.exists() else []
for previous in prior:
    assert not Path(json.loads(previous)['build_dir']).exists(), 'completed batch must release its build directory'
with calls.open('a') as log:
    log.write(json.dumps({'paths':paths,'args':args,'build_dir':str(test.parent)})+'\\n')
if len(prior)==int(os.environ.get('MOCK_FAIL_AT','-1')):
    sys.exit(1)
report=Path(args[args.index('--report-file')+1])
report.write_text(''.join('SF:src/'+Path(p).stem+'.sol\\nDA:1,1\\nend_of_record\\n' for p in paths))
""")
        self.executable("lcov", """
import sys
from pathlib import Path
args=sys.argv[1:]
reports=[Path(args[i+1]) for i,arg in enumerate(args) if arg=='--add-tracefile']
assert reports and all(p.is_file() for p in reports)
Path(args[args.index('--output-file')+1]).write_text(''.join(p.read_text() for p in reports))
""")

    def executable(self, name, source):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + source)
        path.chmod(0o755)

    def run_coverage(self, **overrides):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PERPS_COVERAGE_")}
        env.update(PATH=str(self.bin) + os.pathsep + env["PATH"], MOCK_CALLS=str(self.calls),
                   PERPS_ARTIFACT_DIR=str(self.evidence), **overrides)
        result = subprocess.run(
            ["bash", str(self.scripts / "run-perps-coverage.sh"), "--threads", "1", "--ir-minimum",
             "--report", "lcov", "--report-file", str(self.report)],
            cwd=self.root, env=env, capture_output=True, text=True,
        )
        self.assertEqual(list(self.package.glob(".coverage-perps.*")), [], "scratch must be cleaned")
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, calls

    def assert_complete(self, calls, maximum):
        paths = [path for call in calls for path in call["paths"]]
        self.assertCountEqual(paths, self.paths)
        self.assertEqual(len(paths), len(set(paths)))
        self.assertTrue(all(0 < len(call["paths"]) <= maximum for call in calls))
        for call in calls:
            self.assertIn("--ir-minimum", call["args"])
            self.assertEqual(call["args"][call["args"].index("--threads") + 1], "1")
        self.assertEqual(self.report.read_text().count("SF:packages/perps/src/"), len(self.paths))

    def test_bounded_batches_keep_every_eligible_entrypoint_once_and_merge_all_reports(self):
        result, calls = self.run_coverage(PERPS_COVERAGE_BATCH_SIZE="4")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 3)
        self.assert_complete(calls, 4)
        selections = sorted(self.evidence.glob("shard-*-entrypoints.txt"))
        self.assertEqual(len(selections), 3)
        self.assertCountEqual([p for f in selections for p in f.read_text().splitlines()], self.paths)

    def test_single_batch_keeps_the_same_selection_and_normalizes_report_paths(self):
        result, calls = self.run_coverage(PERPS_COVERAGE_BATCH_SIZE="10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assert_complete(calls, 10)

    def test_explicit_legacy_shards_remain_supported(self):
        result, calls = self.run_coverage(PERPS_COVERAGE_SHARDS="2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2)
        self.assert_complete(calls, 5)

    def test_coverage_failure_stops_batches_and_never_emits_a_partial_merged_report(self):
        result, calls = self.run_coverage(PERPS_COVERAGE_BATCH_SIZE="4", MOCK_FAIL_AT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2)
        self.assertFalse(self.report.exists())

    def test_invalid_or_conflicting_batch_controls_fail_before_running_coverage(self):
        for settings in ({"PERPS_COVERAGE_BATCH_SIZE": "0"}, {"PERPS_COVERAGE_BATCH_SIZE": "bad"},
                         {"PERPS_COVERAGE_BATCH_SIZE": "4", "PERPS_COVERAGE_SHARDS": "2"}):
            with self.subTest(settings=settings):
                result, calls = self.run_coverage(**settings)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, [])
                self.assertFalse(self.report.exists())


if __name__ == "__main__":
    unittest.main()
