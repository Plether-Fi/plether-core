"""Fail-closed runner checks; no RPC, Forge, credentials or third-party dependencies needed."""

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
from oracle_sync_evidence import (SCENARIOS, assert_unchanged, load_scenario_manifest, parse_scenario_records,
                                  production_environment, sanitize_log, sha256_bytes, source_fingerprint, validate_fixture,
                                  validate_scenario_records)


def valid_records():
    records = []
    for name, (outcome, statuses, parses, updates, multiplier) in SCENARIOS.items():
        funded = (6 if name == "distinct_basket_batch" else 5) * 3
        record = dict(schemaVersion=1, scenarioId=name, callGas=1_000_000, gasCap=30_000_000,
                      quoteWei=3, fundedWei=funded, pythFeeDeltaWei=multiplier * 3,
                      immediateRefundWei=funded - multiplier * 3, oracleDeferredWei=0,
                      routerDeferredWei=0, oracleClaimedWei=0, routerClaimedWei=0,
                      oracleCreditedWei=0, routerCreditedWei=0,
                      terminalCount=sum(status != 1 for status in statuses), outcome=outcome,
                      markTime=1, markPrice=100, storedPublishTimes=[1] * 6,
                      requiredPublishTimes=[1] * 6, lifecycleStatuses=statuses,
                      expectedParseCalls=parses, expectedUpdateCalls=updates,
                      liveReadChecked=name == "historical_single", payloadBytes=128,
                      isolationMode="transaction", isolationVerified=True,
                      executionTimestamp=2, executionBlock=2, orderIds=list(range(1, len(statuses) + 1)),
                      orderCommitTimes=[1] * len(statuses), executionDeadlines=[61] * len(statuses))
        if name == "unavailable_deferred":
            record.update(immediateRefundWei=0, oracleCreditedWei=6, routerCreditedWei=9,
                          oracleClaimedWei=6, routerClaimedWei=9)
        records.append(record)
    return records


class ScenarioEvidenceTests(unittest.TestCase):
    def test_complete_matrix(self):
        records = valid_records()
        output = "\n".join("  oracle-sync-evidence: " + json.dumps(record) for record in records)
        self.assertEqual(validate_scenario_records(parse_scenario_records(output)), records)

    def test_omitted_mandatory_case(self):
        with self.assertRaisesRegex(ValueError, "mandatory"):
            validate_scenario_records(valid_records()[:-1])

    def test_duplicate_case(self):
        records = valid_records()
        with self.assertRaisesRegex(ValueError, "duplicate"):
            validate_scenario_records(records + [records[0]])

    def test_malformed_record(self):
        with self.assertRaises(json.JSONDecodeError):
            parse_scenario_records("oracle-sync-evidence: {bad}")

    def test_small_gas_pending_is_not_success(self):
        records = valid_records()
        records[0].update(callGas=100, outcome="pending", lifecycleStatuses=[1], terminalCount=0)
        with self.assertRaisesRegex(ValueError, "execution progress"):
            validate_scenario_records(records)

    def test_exceeded_or_raised_keeper_cap(self):
        for changes in ({"callGas": 30_000_001}, {"gasCap": 31_000_000}):
            records = valid_records()
            records[0].update(changes)
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, "gas"):
                validate_scenario_records(records)

    def test_nonisolated_results(self):
        records = valid_records()
        records[0]["isolationMode"] = "test"
        with self.assertRaisesRegex(ValueError, "isolation"):
            validate_scenario_records(records)

    def test_unverified_isolation(self):
        records = valid_records()
        records[0]["isolationVerified"] = False
        with self.assertRaisesRegex(ValueError, "isolation"):
            validate_scenario_records(records)

    def test_expired_receipt_is_not_valid_execution(self):
        records = valid_records()
        records[2]["executionDeadlines"][0] = 1
        with self.assertRaisesRegex(ValueError, "execution deadline"):
            validate_scenario_records(records)

    def test_double_refund(self):
        records = valid_records()
        records[-1]["immediateRefundWei"] = records[-1]["oracleClaimedWei"]
        with self.assertRaisesRegex(ValueError, "conserve"):
            validate_scenario_records(records)

    def test_unbacked_claim(self):
        records = valid_records()
        records[-1]["oracleCreditedWei"] += 1
        with self.assertRaisesRegex(ValueError, "claim accounting"):
            validate_scenario_records(records)

    def test_insufficient_storage_and_missing_feed(self):
        for stored in ([0] * 6, [1] * 5):
            records = valid_records()
            records[0]["storedPublishTimes"] = stored
            with self.subTest(stored=stored), self.assertRaisesRegex(ValueError, "[Cc]overage"):
                validate_scenario_records(records)

    def test_wrong_fee_multiplier(self):
        records = valid_records()
        records[2]["pythFeeDeltaWei"] //= 2
        with self.assertRaisesRegex(ValueError, "Pyth fees"):
            validate_scenario_records(records)

    def test_bool_is_not_a_gas_integer(self):
        records = valid_records()
        records[0]["callGas"] = True
        with self.assertRaisesRegex(ValueError, "integer"):
            validate_scenario_records(records)

    def test_missing_live_read(self):
        records = valid_records()
        records[0]["liveReadChecked"] = False
        with self.assertRaisesRegex(ValueError, "live read"):
            validate_scenario_records(records)

    def test_matrix_evidence_must_match_manifest_timestamps_and_payload(self):
        manifest = {"fixtures": {name: {"fixture": {"publishTimes": [1] * 6,
                    "initialStoredPublishTimes": [1] * 6, "updateData": ["0x" + "aa" * 128]}}
                    for name in ("historicalA", "historicalB", "fridayOpening", "fridayClosing")}}
        records = valid_records()
        records[2]["payloadBytes"] = 256
        validate_scenario_records(records, manifest)
        for field, value in (("payloadBytes", 127), ("requiredPublishTimes", [0] * 6)):
            changed = copy.deepcopy(records)
            changed[0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "signed"):
                validate_scenario_records(changed, manifest)


class FixtureTests(unittest.TestCase):
    def setUp(self):
        fixture_path = Path(__file__).resolve().parents[1] / "test/fixtures/oracle-sync/arbitrum-sepolia.json"
        self.fixture = json.loads(fixture_path.read_text())

    def test_existing_regression_fixture(self):
        validate_fixture(self.fixture, require_mismatch=True, require_provenance=True)

    def test_corrupted_signed_bytes(self):
        self.fixture["updateData"][0] = "0x00"
        with self.assertRaisesRegex(ValueError, "checksum"):
            validate_fixture(self.fixture)

    def test_invalid_unique_window(self):
        self.fixture["previousPublishTimes"][3] = self.fixture["commitTimestamp"] + 1
        with self.assertRaisesRegex(ValueError, "unique-tick"):
            validate_fixture(self.fixture)

    def test_current_storage_cannot_pass_mismatch_gate(self):
        self.fixture["initialStoredPublishTimes"] = self.fixture["publishTimes"][:]
        with self.assertRaisesRegex(ValueError, "Already-current"):
            validate_fixture(self.fixture, require_mismatch=True)

    def test_missing_transaction_provenance(self):
        del self.fixture["payloadSource"]
        with self.assertRaises(ValueError):
            validate_fixture(self.fixture, require_provenance=True)


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="oracle-evidence-test-")
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.email", "evidence-tests@example.invalid")
        self.git("config", "user.name", "Evidence tests")
        (self.repo / "source.sol").write_text("contract Source {}\n")
        (self.repo / ".gitignore").write_text("artifacts/\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, stderr=subprocess.STDOUT)


class FingerprintTests(RepositoryFixture):
    def test_deterministic_clean_inputs_and_ignored_outputs(self):
        before = source_fingerprint(self.repo)
        (self.repo / "artifacts").mkdir()
        (self.repo / "artifacts/result.json").write_text("{}")
        after = source_fingerprint(self.repo, before["sourceCommit"])
        assert_unchanged(before, after)
        self.assertEqual(len(before["sha256"]), 64)

    def test_dirty_source_rejected(self):
        (self.repo / "source.sol").write_text("contract Different {}\n")
        with self.assertRaisesRegex(ValueError, "Commit all"):
            source_fingerprint(self.repo)

    def test_untracked_fixture_rejected(self):
        (self.repo / "new-fixture.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "Commit all"):
            source_fingerprint(self.repo)

    def test_commit_change_rejected(self):
        before = source_fingerprint(self.repo)
        (self.repo / "source.sol").write_text("contract Different {}\n")
        self.git("add", ".")
        self.git("commit", "-qm", "changed")
        with self.assertRaisesRegex(ValueError, "Source revision changed"):
            source_fingerprint(self.repo, before["sourceCommit"])
        with self.assertRaisesRegex(ValueError, "inputs changed"):
            assert_unchanged(before, source_fingerprint(self.repo))

    def test_content_fingerprint_detects_index_hidden_edits(self):
        self.git("update-index", "--assume-unchanged", "source.sol")
        (self.repo / "source.sol").write_text("contract HiddenEdit {}\n")
        with self.assertRaisesRegex(ValueError, "Tracked input bytes"):
            source_fingerprint(self.repo)

    def test_dependency_pins_and_contents_are_fingerprinted(self):
        dependency = self.repo.parent / (self.repo.name + "-dependency")
        dependency.mkdir()
        self.addCleanup(lambda: shutil.rmtree(dependency))
        for args in (("init", "-q"), ("config", "user.email", "evidence-tests@example.invalid"),
                     ("config", "user.name", "Evidence tests")):
            subprocess.check_call(["git", *args], cwd=dependency)
        (dependency / "dependency.sol").write_text("contract Dependency {}\n")
        subprocess.check_call(["git", "add", "."], cwd=dependency)
        subprocess.check_call(["git", "commit", "-qm", "dependency"], cwd=dependency)
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(dependency), "lib/dependency")
        self.git("commit", "-qam", "pin dependency")
        before = source_fingerprint(self.repo)
        self.assertEqual(before["dependencies"][0]["path"], "lib/dependency")
        self.assertTrue(before["dependencies"][0]["files"])
        (self.repo / "lib/dependency/dependency.sol").write_text("contract ChangedDependency {}\n")
        with self.assertRaisesRegex(ValueError, "Commit all"):
            source_fingerprint(self.repo)


class ManifestTests(RepositoryFixture):
    def setUp(self):
        super().setUp()
        fixture = json.loads((Path(__file__).resolve().parents[1] /
                              "test/fixtures/oracle-sync/arbitrum-sepolia.json").read_text())
        self.manifest = {"schemaVersion": 1, "fixtures": {}}
        for name in ("historicalA", "historicalB", "fridayOpening", "fridayClosing"):
            item = copy.deepcopy(fixture)
            if name == "historicalB":
                for field in ("commitTimestamp", "executionTimestamp", "forkTimestamp"):
                    item[field] += 1
                item["publishTimes"] = [value + 1 for value in item["publishTimes"]]
                item["previousPublishTimes"] = [value + 1 for value in item["previousPublishTimes"]]
                item["updateData"] = ["0xab"]
                item["payloadSha256"] = sha256_bytes(json.dumps(item["updateData"], separators=(",", ":")).encode())
            filename = name + ".json"
            (self.repo / filename).write_text(json.dumps(item))
            self.manifest["fixtures"][name] = filename
        self.write_manifest()
        self.git("add", ".")
        self.git("commit", "-qm", "fixtures")

    def write_manifest(self):
        (self.repo / "scenarios.json").write_text(json.dumps(self.manifest))

    def test_valid_manifest(self):
        loaded = load_scenario_manifest(self.repo, self.repo / "scenarios.json")
        self.assertEqual(len(loaded["fixtures"]), 4)

    def test_omitted_manifest_fixture(self):
        del self.manifest["fixtures"]["fridayClosing"]
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "each required fixture"):
            load_scenario_manifest(self.repo, self.repo / "scenarios.json")

    def test_missing_manifest_fixture(self):
        (self.repo / "fridayClosing.json").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            load_scenario_manifest(self.repo, self.repo / "scenarios.json")

    def test_cache_compatible_ticks_do_not_prove_distinct_baskets(self):
        self.manifest["fixtures"]["historicalB"] = "historicalA.json"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "prevent reuse"):
            load_scenario_manifest(self.repo, self.repo / "scenarios.json")

    def test_external_fixture_is_rejected(self):
        self.manifest["fixtures"]["historicalB"] = "../outside.json"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "this repository"):
            load_scenario_manifest(self.repo, self.repo / "scenarios.json")


class RunnerResultTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("oracle_runner", Path(__file__).with_name("run-oracle-sync-fork.py"))
        cls.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.runner)

    def test_exit_failure_cannot_pass_with_success_log(self):
        log = "[PASS] test_RealPythBaselineVersusAtomicSynchronization\n0 skipped\nhistorical fill: 10\nneutral mark: 10\n"
        self.assertTrue(self.runner.baseline_result(0, log, "hash")["passed"])
        self.assertFalse(self.runner.baseline_result(1, log, "hash")["passed"])

    def test_missing_or_duplicate_price_evidence(self):
        log = "[PASS] test_RealPythBaselineVersusAtomicSynchronization\n0 skipped\nhistorical fill: 10\n"
        self.assertFalse(self.runner.baseline_result(0, log, "hash")["passed"])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.runner.baseline_result(0, log + "historical fill: 10\n", "hash")

    def test_logs_strip_credentials_and_urls(self):
        output = "\x1b[31mRPC https://private.example/path?secret=abcdef API abcdef\x1b[0m public https://example.com/path"
        clean = sanitize_log(output, {"ARB_SEPOLIA_RPC_URL": "https://private.example/path?secret=abcdef", "PYTH_API_KEY": "abcdef"})
        self.assertNotIn("abcdef", clean)
        self.assertNotIn("https://", clean)
        self.assertNotIn("\x1b", clean)

    def test_shell_compiler_overrides_cannot_change_qualification(self):
        environment = production_environment({"FOUNDRY_PROFILE": "dev", "FOUNDRY_OPTIMIZER": "false",
                                             "DAPP_BUILD_OPTIMIZE_RUNS": "1", "ARB_SEPOLIA_RPC_URL": "private"})
        self.assertEqual(environment, {"FOUNDRY_PROFILE": "ci", "FOUNDRY_VIA_IR": "true",
                                       "ARB_SEPOLIA_RPC_URL": "private"})


if __name__ == "__main__":
    unittest.main()
