"""Release export must bind every deployment and reject incomplete or changing evidence."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
spec = importlib.util.spec_from_file_location("release_export", Path(__file__).with_name("export-perps-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


IDENTIFIER = "Example.sol:Example"
MANIFEST = {"schemaVersion": 3, "orderInterfaceVersion": 3,
            "contracts": {"example": {"artifact": "packages/perps/src/" + IDENTIFIER}}}


def artifact(creation=b"\x60\x00", runtime=b"\x00"):
    return {
        "abi": [{"type": "constructor", "inputs": [{"name": "owner", "type": "address"}]}],
        "bytecode": {"object": "0x" + creation.hex()},
        "deployedBytecode": {"object": "0x" + runtime.hex()},
        "metadata": {"compiler": {"version": "0.8.35+commit.47b9dedd"}, "settings": {
            "viaIR": True, "optimizer": {"enabled": True, "runs": 200}, "evmVersion": "prague",
        }},
    }


def record(creation=b"\x60\x00", runtime=b"\x00", arguments=b"\x00" * 31 + b"\x01"):
    return {
        "contractKey": "example", "artifact": IDENTIFIER,
        "constructorArguments": "0x" + arguments.hex(), "localAddress": "0x" + "12" * 20,
        "runtimeBytes": len(runtime), "creationCodeBytes": len(creation),
        "creationInputBytes": len(creation) + len(arguments),
        "creationInputSha256": "0x" + hashlib.sha256(creation + arguments).hexdigest(),
        "runtimeSha256": "0x" + hashlib.sha256(runtime).hexdigest(),
    }


def forge_result(records=None, status="Success"):
    records = [record()] if records is None else records
    return {release.SIZE_TEST_SUITE: {"test_results": {release.SIZE_TEST: {
        "status": status, "decoded_logs": [release.LOG_PREFIX + json.dumps(item) for item in records],
    }}}}


class DeploymentSizeEvidenceTest(unittest.TestCase):
    def validate(self, records, compiled=None):
        return release.validate_size_records(records, MANIFEST, {IDENTIFIER: compiled or artifact()})

    def test_exact_constructor_input_is_bound_to_current_compiler_bytecode(self):
        self.assertEqual(set(self.validate([record()])), {"example"})
        changed = artifact(creation=b"\x61\x00")
        with self.assertRaisesRegex(ValueError, "compiled artifact"):
            self.validate([record()], changed)

    def test_creation_code_fits_but_constructor_pushes_input_over_limit(self):
        creation = b"\x00" * (release.CREATION_INPUT_LIMIT - 1)
        with self.assertRaisesRegex(ValueError, "full creation input exceeds"):
            self.validate([record(creation=creation)], artifact(creation=creation))

    def test_constructor_arguments_cannot_be_excluded_from_size(self):
        item = record()
        item["creationInputBytes"] = item["creationCodeBytes"]
        with self.assertRaisesRegex(ValueError, "omits constructor"):
            self.validate([item])

    def test_empty_or_oversized_runtime_does_not_qualify(self):
        for runtime in (b"", b"\x00" * (release.RUNTIME_LIMIT + 1)):
            with self.subTest(size=len(runtime)), self.assertRaisesRegex(ValueError, "runtime size"):
                self.validate([record(runtime=runtime)], artifact(runtime=runtime))

    def test_every_manifest_contract_required_exactly_once(self):
        for records in ([], [record(), record()], [dict(record(), contractKey="other")]):
            with self.subTest(records=records), self.assertRaisesRegex(ValueError, "entry|every manifest"):
                self.validate(records)

    def test_wrong_artifact_or_malformed_measurement_does_not_qualify(self):
        for replacement in ({"artifact": "Other.sol:Other"}, {"runtimeBytes": True},
                            {"creationInputSha256": "0x" + "00" * 32}, {"constructorArguments": "xyz"},
                            {"runtimeSha256": "0x" + "00" * 32}):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                self.validate([dict(record(), **replacement)])

    def test_failed_or_skipped_test_cannot_pass_using_success_looking_logs(self):
        for status in ("Failure", "Skipped", None):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "did not pass"):
                release.parse_size_records(json.dumps(forge_result(status=status)))

    def test_wrong_suite_or_no_structured_logs_does_not_qualify(self):
        for result in ({}, {"other": forge_result()[release.SIZE_TEST_SUITE]}, forge_result(records=[])):
            with self.subTest(result=result), self.assertRaises(ValueError):
                release.parse_size_records(json.dumps(result))

    def test_expected_local_test_logs_are_parsed(self):
        self.assertEqual(release.parse_size_records(json.dumps(forge_result())), [record()])


class ExportWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.output = Path(self.temp.name) / "output"
        (self.root / "deployments").mkdir(parents=True)
        (self.root / "deployments/arbitrum-sepolia-perps.template.json").write_text(json.dumps(MANIFEST))
        self.artifact_path = release.artifact_path(self.root, IDENTIFIER)
        self.artifact_path.parent.mkdir(parents=True)
        self.artifact_path.write_text(json.dumps(artifact()))
        self.fingerprint = {"sourceCommit": "a" * 40, "sha256": "b" * 64, "files": [], "dependencies": []}

    def check_output(self, command, **_kwargs):
        if command == ["forge", "--version"]:
            return "forge Version: 1.5.1-stable\nCommit SHA: synthetic\n"
        self.assertEqual(command, ["forge", "config", "--json"])
        return json.dumps({"out": "out", "eth_rpc_url": None, "fork_block_number": None})

    def run_command(self, command, **_kwargs):
        output = json.dumps(forge_result()) if command[1] == "test" else "production build complete\n"
        return subprocess.CompletedProcess(command, 0, output, "")

    def export(self, fingerprints=None, run=None, check_output=None):
        with patch.object(release, "source_fingerprint", side_effect=fingerprints or [self.fingerprint] * 3), \
             patch.object(release.subprocess, "check_output", side_effect=check_output or self.check_output), \
             patch.object(release.subprocess, "run", side_effect=run or self.run_command):
            return release.export_release(self.root, self.output, self.fingerprint["sourceCommit"])

    def test_success_binds_full_source_revision_abi_and_local_size_evidence(self):
        report = self.export()
        self.assertEqual(report["sourceCommit"], self.fingerprint["sourceCommit"])
        self.assertEqual(report["sourceFingerprint"], self.fingerprint)
        self.assertEqual(set(report["deploymentSizeValidation"]["deployments"]), {"example"})
        abi = (self.output / "abi/Example.json").read_bytes()
        self.assertEqual(report["contracts"]["Example"]["abiSha256"], hashlib.sha256(abi).hexdigest())
        self.assertEqual(report["contracts"]["Example"]["artifactSha256"], hashlib.sha256(self.artifact_path.read_bytes()).hexdigest())
        self.assertNotIn("qualified", report)
        self.assertNotIn("--broadcast", " ".join(report["logs"]["deployment-sizes.log"]["command"]))

    def test_source_change_after_build_or_after_export_fails_closed(self):
        for fingerprints in ([self.fingerprint, dict(self.fingerprint, sha256="c" * 64)],
                             [self.fingerprint, self.fingerprint, dict(self.fingerprint, sha256="c" * 64)]):
            with self.subTest(fingerprints=fingerprints):
                if self.output.exists():
                    import shutil
                    shutil.rmtree(self.output)
                with self.assertRaisesRegex(ValueError, "inputs changed"):
                    self.export(fingerprints=fingerprints)
                self.assertFalse((self.output / "build.json").exists())
                self.assertFalse(json.loads((self.output / "export-failed.json").read_text())["exportComplete"])

    def test_wrong_compiler_settings_prevent_abi_export(self):
        wrong = artifact()
        wrong["metadata"]["settings"]["optimizer"]["runs"] = 1
        self.artifact_path.write_text(json.dumps(wrong))
        with self.assertRaisesRegex(ValueError, "production settings"):
            self.export()
        self.assertFalse((self.output / "build.json").exists())

    def test_concurrent_compiler_artifact_replacement_fails_closed(self):
        calls = 0
        def fingerprint(*_args):
            nonlocal calls
            calls += 1
            if calls == 3:
                self.artifact_path.write_text(json.dumps(artifact(creation=b"\x61\x00")))
            return self.fingerprint
        with self.assertRaisesRegex(ValueError, "Compiler artifacts changed"):
            self.export(fingerprints=fingerprint)
        self.assertFalse((self.output / "build.json").exists())

    def test_failed_local_size_test_preserves_sanitized_log_without_pass_report(self):
        secret = "sensitive-example-token"
        def failed(command, **kwargs):
            if command[1] == "test":
                return subprocess.CompletedProcess(command, 1, "failed " + secret, "")
            return self.run_command(command, **kwargs)
        with patch.dict(os.environ, {"PYTH_API_KEY": secret}), self.assertRaisesRegex(ValueError, "failed"):
            self.export(run=failed)
        log = (self.output / "deployment-sizes.log").read_text()
        self.assertNotIn(secret, log)
        self.assertIn("[REDACTED]", log)
        self.assertFalse((self.output / "build.json").exists())

    def test_configured_rpc_is_rejected_before_any_build(self):
        def remote(command, **kwargs):
            if command[1] == "config":
                return json.dumps({"eth_rpc_url": "https://example.invalid"})
            return self.check_output(command, **kwargs)
        with self.assertRaisesRegex(ValueError, "forbids configured RPC"):
            self.export(check_output=remote)
        self.assertFalse(self.output.exists())

    def test_existing_output_cannot_be_overwritten(self):
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.export()


if __name__ == "__main__":
    unittest.main()
