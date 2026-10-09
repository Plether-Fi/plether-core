"""Release export must bind every deployment and reject incomplete or changing evidence."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
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
SOURCE_PATH = "packages/perps/src/Example.sol"
SOURCE = b"contract Example {}\n"


def synthetic_keccak(data):
    return "0x" + hashlib.sha256(b"mock-keccak" + data).hexdigest()
MANIFEST = {"schemaVersion": 3, "orderInterfaceVersion": 3,
            "contracts": {"example": {"artifact": "packages/perps/src/" + IDENTIFIER}}}


def artifact(creation=b"\x60\x00", runtime=b"\x00", source=SOURCE_PATH, name="Example", content=SOURCE):
    result = {
        "abi": [{"type": "constructor", "inputs": [{"name": "owner", "type": "address"}]}],
        "bytecode": {"object": "0x" + creation.hex()},
        "deployedBytecode": {"object": "0x" + runtime.hex()},
        "metadata": {"compiler": {"version": "0.8.35+commit.47b9dedd"}, "settings": {
            "viaIR": True, "optimizer": {"enabled": True, "runs": 200}, "evmVersion": "prague",
            "compilationTarget": {source: name},
        }, "sources": {source: {"keccak256": synthetic_keccak(content)}}},
    }

    result["metadata"]["output"] = {"abi": json.loads(json.dumps(result["abi"]))}
    return result


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


class CompilerSourceBindingTest(unittest.TestCase):
    def test_dependency_source_uses_recorded_gitlink_commit(self):
        root = Path("/synthetic/repo")
        revision, dependency_commit = "a" * 40, "b" * 40
        def links(repo, sha):
            if repo == root:
                self.assertEqual(sha, revision)
                return [("lib/dependency", dependency_commit)]
            self.assertEqual((repo, sha), (root / "lib/dependency", dependency_commit))
            return []
        release.pinned_source.cache_clear()
        self.addCleanup(release.pinned_source.cache_clear)
        with patch.object(release, "gitlinks", side_effect=links), \
             patch.object(release.subprocess, "check_output", return_value=SOURCE) as read:
            self.assertEqual(release.pinned_source(root, revision, "lib/dependency/src/Example.sol"), SOURCE)
        self.assertEqual(read.call_args.args[0], ["git", "-C", str(root / "lib/dependency"),
                                                "show", dependency_commit + ":src/Example.sol"])

    def test_removed_source_and_external_metadata_paths_are_rejected(self):
        release.pinned_source.cache_clear()
        self.addCleanup(release.pinned_source.cache_clear)
        for path in ("/outside.sol", "../outside.sol"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "non-repository"):
                release.pinned_source(Path("/synthetic/repo"), "a" * 40, path)
        with patch.object(release, "gitlinks", return_value=[]), \
             patch.object(release.subprocess, "check_output", side_effect=subprocess.CalledProcessError(128, "git")):
            with self.assertRaisesRegex(ValueError, "absent at pinned revision"):
                release.pinned_source(Path("/synthetic/repo"), "a" * 40, "removed.sol")

    def test_abi_order_and_empty_output_normalization_preserve_semantics(self):
        function = {"type": "function", "name": "call", "inputs": [], "stateMutability": "nonpayable"}
        constructor = {"type": "constructor", "inputs": []}
        self.assertEqual(release.normalized_abi([function, constructor]),
                         release.normalized_abi([constructor, dict(function, outputs=[])]))
        self.assertNotEqual(release.normalized_abi([function]),
                            release.normalized_abi([dict(function, outputs=[{"type": "uint256", "name": ""}])]))


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
        self.build_artifacts = {IDENTIFIER: artifact()}
        self.build_paths = []
        self.fingerprint = {"sourceCommit": "a" * 40, "sha256": "b" * 64, "files": [], "dependencies": []}

    def check_output(self, command, **_kwargs):
        if command == ["forge", "--version"]:
            return "forge Version: 1.5.1-stable\nCommit SHA: synthetic\n"
        self.assertEqual(command, ["forge", "config", "--json"])
        return json.dumps({"out": "out", "eth_rpc_url": None, "fork_block_number": None})

    def run_command(self, command, **_kwargs):
        build_out = Path(command[command.index("--out") + 1])
        self.build_paths.append(build_out)
        if command[1] == "build":
            self.fresh_artifact_path = build_out / "Example.sol/Example.json"
            for identifier, compiled in self.build_artifacts.items():
                filename, name = identifier.split(":")
                path = build_out / filename / (name + ".json")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(compiled))
        output = json.dumps(forge_result()) if command[1] == "test" else "production build complete\n"
        return subprocess.CompletedProcess(command, 0, output, "")

    def export(self, fingerprints=None, run=None, check_output=None):
        with patch.object(release, "source_fingerprint", side_effect=fingerprints or [self.fingerprint] * 3), \
             patch.object(release.subprocess, "check_output", side_effect=check_output or self.check_output), \
             patch.object(release.subprocess, "run", side_effect=run or self.run_command), \
             patch.object(release, "pinned_source", side_effect=lambda _root, _revision, path: SOURCE if path == SOURCE_PATH else (self.root / path).read_bytes()), \
             patch.object(release, "keccak256", side_effect=synthetic_keccak):
            return release.export_release(self.root, self.output, self.fingerprint["sourceCommit"])

    def test_success_binds_full_source_revision_abi_and_local_size_evidence(self):
        report = self.export()
        self.assertEqual(report["sourceCommit"], self.fingerprint["sourceCommit"])
        self.assertEqual(report["sourceFingerprint"], self.fingerprint)
        self.assertEqual(set(report["deploymentSizeValidation"]["deployments"]), {"example"})
        abi = (self.output / "abi/Example.json").read_bytes()
        self.assertEqual(report["contracts"]["Example"]["abiSha256"], hashlib.sha256(abi).hexdigest())
        self.assertEqual(report["contracts"]["Example"]["artifactSha256"], hashlib.sha256((self.output / report["contracts"]["Example"]["artifact"]).read_bytes()).hexdigest())
        self.assertEqual(self.build_paths[0], self.build_paths[1])
        self.assertNotEqual(self.build_paths[0], self.root / "out")
        self.assertFalse(self.build_paths[0].exists())
        self.assertEqual(report["contracts"]["Example"]["sourceArtifact"], SOURCE_PATH + ":Example")
        self.assertEqual(set(report["compilerSources"]), {SOURCE_PATH})
        self.assertNotIn("qualified", report)
        command = report["logs"]["deployment-sizes.log"]["command"]
        self.assertNotIn("--broadcast", " ".join(command))
        # Forge tests are matched by their canonical signature, including the parentheses.
        self.assertTrue(re.fullmatch(command[command.index("--match-test") + 1], release.SIZE_TEST))

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
        self.build_artifacts[IDENTIFIER] = wrong
        with self.assertRaisesRegex(ValueError, "production settings"):
            self.export()
        self.assertFalse((self.output / "build.json").exists())

    def test_concurrent_compiler_artifact_replacement_fails_closed(self):
        calls = 0
        def fingerprint(*_args):
            nonlocal calls
            calls += 1
            if calls == 3:
                self.fresh_artifact_path.write_text(json.dumps(artifact(creation=b"\x61\x00")))
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


    def add_unused_interface(self):
        path = self.root / "packages/perps/src/interfaces/IUnused.sol"
        path.parent.mkdir(parents=True)
        path.write_text("interface IUnused { function current() external; }\n")
        fresh = artifact(creation=b"", runtime=b"", source=str(path.relative_to(self.root)),
                         name="IUnused", content=path.read_bytes())
        fresh["abi"] = [{"type": "function", "name": "current", "inputs": [], "outputs": [], "stateMutability": "nonpayable"}]
        fresh["metadata"]["output"]["abi"] = fresh["abi"]
        stale = release.artifact_path(self.root, "IUnused.sol:IUnused")
        stale.parent.mkdir(parents=True)
        stale.write_text(json.dumps(artifact()))
        return fresh

    def test_ignored_stale_interface_artifact_cannot_fill_missing_compiler_output(self):
        self.add_unused_interface()
        with self.assertRaises(FileNotFoundError):
            self.export()
        self.assertFalse((self.output / "build.json").exists())

    def test_unused_interface_is_explicitly_compiled_and_stale_abi_is_replaced(self):
        self.build_artifacts["IUnused.sol:IUnused"] = self.add_unused_interface()
        report = self.export()
        self.assertEqual(set(report["contracts"]), {"Example", "IUnused"})
        self.assertEqual(json.loads((self.output / "abi/IUnused.json").read_text())[0]["name"], "current")
        self.assertIn("packages/perps/src/interfaces/IUnused.sol", report["logs"]["build.log"]["command"])
        self.assertEqual(report["logs"]["build.log"]["command"][3:7],
                         report["logs"]["deployment-sizes.log"]["command"][3:7])

    def test_stale_source_or_wrong_target_or_wrong_abi_fails_export(self):
        import shutil
        for corruption in ("source", "target", "abi", "compiler"):
            with self.subTest(corruption=corruption):
                if self.output.exists():
                    shutil.rmtree(self.output)
                value = artifact()
                if corruption == "source":
                    value["metadata"]["sources"][SOURCE_PATH]["keccak256"] = "0x" + "00" * 32
                elif corruption == "target":
                    value["metadata"]["settings"]["compilationTarget"] = {SOURCE_PATH: "Other"}
                elif corruption == "abi":
                    value["abi"] = []
                else:
                    value["metadata"]["compiler"]["version"] = "0.8.35+commit.ffffffff"
                self.build_artifacts[IDENTIFIER] = value
                with self.assertRaises(ValueError):
                    self.export()
                self.assertFalse((self.output / "build.json").exists())

    def test_inventory_exports_every_interface_declaration_without_artifact_discovery(self):
        path = self.root / "packages/perps/src/interfaces/IMultiple.sol"
        path.parent.mkdir(parents=True)
        path.write_text("// interface Fake {}\n/* contract Fake2 {} */\ninterface IMultiple {}\ninterface ISecondary {}\n")
        result = release.consumer_inventory(self.root, MANIFEST)
        self.assertEqual(set(result), {IDENTIFIER, "IMultiple.sol:IMultiple", "IMultiple.sol:ISecondary"})

    def test_existing_output_cannot_be_overwritten(self):
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.export()


if __name__ == "__main__":
    unittest.main()
