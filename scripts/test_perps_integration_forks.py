"""Failure-mode checks for the complete perps-only fork runner."""
import importlib.util
import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load('perps_integration_forks', 'run-perps-integration-forks.py')
recorded = load('perps_integration_recorded', 'run-perps-recorded.py')

VALID = """# public signed fixture
export PYTH_REAL_UPDATE_DATA='0x1234abcd'
export PYTH_REAL_UPDATE_PUBLISH_TIME='1001'
export PYTH_REAL_UPDATE_PREV_PUBLISH_TIME='1000'
"""


class CompleteForkRunnerTests(unittest.TestCase):
    def test_parses_fixture_as_data_without_evaluating_shell(self):
        self.assertEqual(runner.fixture_exports(VALID), {
            'PYTH_REAL_UPDATE_DATA': '0x1234abcd',
            'PYTH_REAL_UPDATE_PUBLISH_TIME': '1001',
            'PYTH_REAL_UPDATE_PREV_PUBLISH_TIME': '1000',
        })
        for text in (VALID + 'touch /tmp/untrusted-command\n',
                     VALID.replace('0x1234abcd', '$(untrusted-command)'),
                     VALID + "export PYTH_API_KEY='untrusted'\n"):
            with self.assertRaises(ValueError):
                runner.fixture_exports(text)

    def test_rejects_partial_duplicate_malformed_or_non_unique_fixture(self):
        for text in ('\n'.join(VALID.splitlines()[:-1]),
                     VALID + "export PYTH_REAL_UPDATE_PUBLISH_TIME='1001'\n",
                     VALID.replace('0x1234abcd', '0x123'),
                     VALID.replace("'1000'", "'1001'"),
                     VALID.replace("'1000'", "'1002'")):
            with self.assertRaises(ValueError):
                runner.fixture_exports(text)

    def test_missing_rpc_fails_before_any_lane_can_be_reported_as_passed(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / 'summary.json'
            summary.write_text('{"status":"passed"}')
            with patch.dict(os.environ, {'MAINNET_RPC_URL': 'unused-test-url',
                                         'PERPS_ARTIFACT_DIR': directory}, clear=True), \
                    patch.object(runner.subprocess, 'run') as execute:
                with self.assertRaisesRegex(ValueError, 'ARB_SEPOLIA_RPC_URL is required'):
                    runner.main()
                execute.assert_not_called()
            self.assertEqual(json.loads(summary.read_text())['status'], 'failed')

    def test_saved_public_fixture_replays_exact_signed_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'pyth-fixture.json'
            values = runner.fixture_exports(VALID)
            fixture.write_text(json.dumps(values))
            self.assertEqual(runner.load_fixture(fixture), values)
            fixture.write_text(json.dumps(dict(values, unexpected='ignored-data')))
            with self.assertRaisesRegex(ValueError, 'Invalid saved Pyth fixture'):
                runner.load_fixture(fixture)

    def test_evidence_uses_the_selected_package_not_always_perps(self):
        self.assertEqual(recorded.command_root(['forge', 'test']), recorded.ROOT)
        self.assertEqual(recorded.command_root(['forge', 'test', '--root', 'packages/perps-aa']),
                         recorded.ROOT / 'packages/perps-aa')
        self.assertEqual(recorded.command_root(['forge', 'test', '--root=packages/perps']), recorded.PACKAGE)
        self.assertEqual(recorded.command_root(['forge', 'test', '--root', str(recorded.ROOT)]), recorded.ROOT)

    def test_rejects_filters_that_hide_one_test_inside_an_otherwise_selected_file(self):
        for field in runner.SELECTION_FIELDS:
            value = ['PerpsFork'] if field == 'skip' else 'test_OnlyOneRequiredCase'
            resolved = subprocess.CompletedProcess([], 0, json.dumps({field: value}), '')
            with patch.object(runner.subprocess, 'run', return_value=resolved):
                with self.assertRaisesRegex(ValueError, 'remove: ' + field):
                    runner.require_unfiltered_config(runner.ROOT, {})
        resolved = subprocess.CompletedProcess([], 0, '{"no_match_test":null,"skip":[]}', '')
        with patch.object(runner.subprocess, 'run', return_value=resolved):
            runner.require_unfiltered_config(runner.ROOT, {})

    def test_rejects_substitute_test_directory_with_matching_entrypoint_names(self):
        resolved = subprocess.CompletedProcess([], 0, '{"test":"/tmp/substitute-tests"}', '')
        with patch.object(runner.subprocess, 'run', return_value=resolved):
            with self.assertRaisesRegex(ValueError, 'checked-in test directory'):
                runner.require_unfiltered_config(runner.ROOT, {})


if __name__ == '__main__':
    unittest.main()
