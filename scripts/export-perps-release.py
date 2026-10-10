#!/usr/bin/env python3
"""Export revision-bound perps ABIs and local full-deployment size evidence. Never broadcasts."""

import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from oracle_sync_evidence import assert_unchanged, production_environment, sanitize_log, sha256_file, source_fingerprint


RUNTIME_LIMIT = 24_576
CREATION_INPUT_LIMIT = 49_152
SIZE_TEST_PATH = "test/scripts/PerpsReleaseDeploymentSize.t.sol"
SIZE_TEST_SUITE = SIZE_TEST_PATH + ":PerpsReleaseDeploymentSizeTest"
SIZE_TEST = "test_AllReleaseContractsFitFullDeploymentLimits()"
LOG_PREFIX = "RELEASE_SIZE "
SOLC_VERSION = "0.8.35+commit.47b9dedd"


def artifact_identifier(key, entry):
    if entry.get("artifact"):
        source, name = entry["artifact"].rsplit(":", 1)
        return Path(source).name + ":" + name
    name = {"mockUsdc": "MockUSDC", "seniorVault": "TrancheVault", "juniorVault": "TrancheVault"}.get(
        key, key[0].upper() + key[1:]
    )
    source = "DeployPerpsArbitrumSepolia.s.sol" if name == "MockUSDC" else name + ".sol"
    return source + ":" + name


def artifact_path(root, identifier):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+\.sol:[A-Za-z0-9_]+", identifier):
        raise ValueError("Invalid artifact identifier")
    source, name = identifier.split(":")
    return Path(root) / "out" / source / (name + ".json")


def consumer_inventory(root, manifest):
    """Select artifacts from committed source declarations, never from pre-existing compiler output."""
    inventory = {}
    for key, entry in manifest["contracts"].items():
        identifier = artifact_identifier(key, entry)
        filename = identifier.split(":")[0]
        source = entry["artifact"].rsplit(":", 1)[0] if entry.get("artifact") else (
            "script/" + filename if filename == "DeployPerpsArbitrumSepolia.s.sol"
            else "packages/perps/src/" + filename
        )
        inventory[identifier] = source
    for path in sorted((root / "packages/perps/src/interfaces").glob("*.sol")):
        # Remove comments and literals so example declarations cannot become ABI inventory entries.
        source = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', "", path.read_text())
        names = re.findall(r"^\s*(?:abstract\s+)?(?:interface|library|contract)\s+([A-Za-z_$][A-Za-z0-9_$]*)\b", source, re.M)
        if not names:
            raise ValueError(f"Consumer source has no exportable declaration: {path.name}")
        for name in names:
            inventory[path.name + ":" + name] = str(path.relative_to(root))
    if len({identifier.split(":")[1] for identifier in inventory}) != len(inventory):
        raise ValueError("Duplicate artifact names would overwrite consumer ABI files")
    return inventory


@lru_cache(maxsize=None)
def gitlinks(repo, revision):
    entries = subprocess.check_output(["git", "-C", str(repo), "ls-tree", "-r", "-z", revision]).split(b"\0")
    result = []
    for entry in entries:
        if entry:
            info, path = entry.split(b"\t", 1)
            mode, _kind, object_id = info.decode().split()
            if mode == "160000":
                result.append((path.decode(), object_id))
    return result


@lru_cache(maxsize=None)
def pinned_source(repo, revision, path):
    """Read exact Git blobs, following each dependency's pinned commit rather than its working tree."""
    if Path(path).is_absolute() or ".." in Path(path).parts:
        raise ValueError("Compiler metadata has a non-repository source path")
    for dependency, commit in gitlinks(repo, revision):
        if path.startswith(dependency + "/"):
            return pinned_source(Path(repo) / dependency, commit, path[len(dependency) + 1:])
    try:
        return subprocess.check_output(["git", "-C", str(repo), "show", revision + ":" + path], stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        raise ValueError(f"Compiler metadata source is absent at pinned revision: {path}") from error


def keccak256(data):
    # Ethereum Keccak differs from hashlib.sha3_256. Cast is provided by the pinned Foundry toolchain.
    return subprocess.check_output(["cast", "keccak"], input=b"0x" + data.hex().encode()).decode().strip()


def normalized_abi(abi):
    entries = []
    for item in abi:
        item = dict(item)
        if item["type"] in ("function", "constructor", "event", "error"):
            item.setdefault("inputs", [])
        if item["type"] == "function":
            item.setdefault("outputs", [])
        if item["type"] == "event":
            item.setdefault("anonymous", False)
        entries.append(json.dumps(item, sort_keys=True, separators=(",", ":")))
    return sorted(entries)


def validate_metadata_sources(root, revision, inventory, artifacts):
    sources = {}
    for identifier, artifact in artifacts.items():
        metadata = artifact["metadata"]
        source, name = inventory[identifier], identifier.split(":")[1]
        if metadata["settings"].get("compilationTarget") != {source: name}:
            raise ValueError(f"{identifier}: compiler metadata has the wrong compilation target")
        if normalized_abi(artifact["abi"]) != normalized_abi(metadata["output"]["abi"]):
            raise ValueError(f"{identifier}: ABI differs from compiler metadata")
        if source not in metadata["sources"]:
            raise ValueError(f"{identifier}: compilation target is absent from metadata sources")
        for path, record in metadata["sources"].items():
            if path not in sources:
                content = pinned_source(root, revision, path)
                sources[path] = {"keccak256": keccak256(content), "sha256": hashlib.sha256(content).hexdigest()}
            if record.get("keccak256") != sources[path]["keccak256"]:
                raise ValueError(f"{identifier}: metadata source differs from pinned Git blob: {path}")
    return dict(sorted(sources.items()))


def bytecode(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:0x)?(?:[a-fA-F0-9]{2})*", value):
        raise ValueError("Malformed or unlinked bytecode")
    return bytes.fromhex(value.removeprefix("0x"))


def read_artifact(path):
    raw = path.read_bytes()
    artifact = json.loads(raw)
    artifact["_artifactSha256"] = hashlib.sha256(raw).hexdigest()
    artifact["_rawArtifact"] = raw
    metadata = artifact["metadata"]
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
        artifact["metadata"] = metadata
    settings = metadata["settings"]
    if (
        metadata["compiler"]["version"] != SOLC_VERSION
        or settings.get("viaIR") is not True
        or settings.get("optimizer") != {"enabled": True, "runs": 200}
        or settings.get("evmVersion") != "prague"
    ):
        raise ValueError(f"{path.name} was not compiled with the reviewed production settings")
    return artifact


def parse_size_records(output):
    """Require the exact local test to pass, not just success-looking log lines."""
    result = json.loads(output)
    if set(result) != {SIZE_TEST_SUITE}:
        raise ValueError("Expected exactly the local deployment-size suite")
    tests = result[SIZE_TEST_SUITE]["test_results"]
    if set(tests) != {SIZE_TEST} or tests[SIZE_TEST].get("status") != "Success":
        raise ValueError("The required deployment-size test did not pass")
    records = []
    for line in tests[SIZE_TEST].get("decoded_logs", []):
        if line.startswith(LOG_PREFIX):
            records.append(json.loads(line[len(LOG_PREFIX):]))
    if not records:
        raise ValueError("Deployment-size test emitted no structured evidence")
    return records


def validate_size_records(records, manifest, artifacts):
    expected = manifest["contracts"]
    seen = set()
    for record in records:
        key = record.get("contractKey")
        if key not in expected or key in seen:
            raise ValueError("Missing, duplicate, or unexpected deployment-size entry")
        seen.add(key)
        identifier = artifact_identifier(key, expected[key])
        if record.get("artifact") != identifier:
            raise ValueError(f"{key}: deployment evidence uses the wrong artifact")
        artifact = artifacts[identifier]
        creation = bytecode(artifact["bytecode"]["object"])
        runtime = bytecode(artifact["deployedBytecode"]["object"])
        arguments = bytecode(record.get("constructorArguments"))
        for field in ("runtimeBytes", "creationCodeBytes", "creationInputBytes"):
            if type(record.get(field)) is not int or record[field] < 0:
                raise ValueError(f"{key}: malformed size measurement")
        if record["runtimeBytes"] != len(runtime) or not 0 < len(runtime) <= RUNTIME_LIMIT:
            raise ValueError(f"{key}: deployed runtime size mismatch or limit exceeded")
        if record["creationCodeBytes"] != len(creation) or not creation:
            raise ValueError(f"{key}: creation code size mismatch")
        if record["creationInputBytes"] != len(creation) + len(arguments):
            raise ValueError(f"{key}: full creation input omits constructor arguments")
        if record["creationInputBytes"] > CREATION_INPUT_LIMIT:
            raise ValueError(f"{key}: full creation input exceeds EIP-3860")
        digest = "0x" + hashlib.sha256(creation + arguments).hexdigest()
        if record.get("creationInputSha256") != digest:
            raise ValueError(f"{key}: creation input is not bound to the compiled artifact")
        if not re.fullmatch(r"0x[a-fA-F0-9]{64}", record.get("runtimeSha256", "")):
            raise ValueError(f"{key}: missing deployed runtime hash")
        if not artifact["deployedBytecode"].get("immutableReferences"):
            if record["runtimeSha256"] != "0x" + hashlib.sha256(runtime).hexdigest():
                raise ValueError(f"{key}: immutable-free deployed runtime differs from compiler artifact")
        if not re.fullmatch(r"0x[a-fA-F0-9]{40}", record.get("localAddress", "")):
            raise ValueError(f"{key}: missing local deployment address")
    if seen != set(expected):
        raise ValueError("Deployment-size evidence does not cover every manifest contract")
    return {record["contractKey"]: record for record in records}


def export_release(root, output, source_revision=None):
    root, output = Path(root).resolve(), Path(output).resolve()
    if output.exists():
        raise ValueError("Output directory already exists; choose a new directory")
    before = source_fingerprint(root, source_revision)
    forge_version = subprocess.check_output(["forge", "--version"], text=True).splitlines()[0]
    if forge_version != "forge Version: 1.5.1-stable":
        raise ValueError("Release artifacts require Forge 1.5.1-stable")
    environment = production_environment()
    # No configured fork may turn this local-only check into a remote execution.
    config = json.loads(subprocess.check_output(["forge", "config", "--json"], cwd=root, env=environment, text=True))
    if config.get("eth_rpc_url") or config.get("fork_block_number") is not None:
        raise ValueError("Local release export forbids configured RPC/fork execution")
    output.mkdir(parents=True)
    logs = {}

    def run(command, name):
        completed = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True)
        log = output / name
        log.write_text(sanitize_log(completed.stdout + completed.stderr, environment))
        logs[name] = dict(sha256=sha256_file(log), command=command, exitCode=completed.returncode)
        if completed.returncode:
            raise ValueError(f"{name} failed; see sanitized log")
        return completed.stdout

    # Build from an empty, private compiler tree. Ignored root/out artifacts must never select
    # the inventory or supply an ABI; use these same paths when vm.getCode deploys the fixtures.
    with tempfile.TemporaryDirectory(prefix="perps-release-export-") as temporary:
        build_root = Path(temporary)
        compiler_paths = ["--out", str(build_root / "out"), "--cache-path", str(build_root / "cache")]
        try:
            manifest_path = root / "deployments/arbitrum-sepolia-perps.template.json"
            manifest = json.loads(manifest_path.read_text())
            inventory = consumer_inventory(root, manifest)
            build_sources = sorted(set(inventory.values()))
            run(["forge", "build", "--offline", *compiler_paths, *build_sources], "build.log")
            size_output = run([
                "forge", "test", "--offline", *compiler_paths, "--match-path", SIZE_TEST_PATH,
                "--match-test", "^" + re.escape(SIZE_TEST) + "$", "--json", "-vv",
            ], "deployment-sizes.log")
            records = parse_size_records(size_output)
            artifacts = {identifier: read_artifact(artifact_path(build_root, identifier))
                         for identifier in sorted(inventory)}
            metadata_sources = validate_metadata_sources(root, before["sourceCommit"], inventory, artifacts)
            deployment_sizes = validate_size_records(records, manifest, artifacts)
            after = source_fingerprint(root, before["sourceCommit"])
            assert_unchanged(before, after)
            report = {
                "sourceCommit": before["sourceCommit"],
                "sourceFingerprint": before,
                "schemaVersion": manifest["schemaVersion"],
                "orderInterfaceVersion": manifest["orderInterfaceVersion"],
                "manifestTemplateSha256": sha256_file(manifest_path),
                "forgeVersion": forge_version,
                "compilerInputs": build_sources,
                "compilerSources": metadata_sources,
                "artifactIsolation": "fresh temporary output and cache shared by build and local deployment-size test",
                "inventoryPolicy": "all manifest contracts and every declaration in perps consumer interface sources",
                "deploymentSizeValidation": {
                    "environment": "local EVM; no RPC; inactive deployment",
                    "test": SIZE_TEST_SUITE + "::" + SIZE_TEST,
                    "runtimeLimitBytes": RUNTIME_LIMIT,
                    "creationInputLimitBytes": CREATION_INPUT_LIMIT,
                    "deployments": deployment_sizes,
                },
                "note": "Compiler runtime templates precede immutable substitution; local deployed sizes and hashes are recorded separately. Full creation inputs include exact local constructor arguments. This export alone does not qualify or deploy a release.",
                "logs": logs,
                "contracts": {},
            }
            (output / "abi").mkdir()
            for identifier, artifact in artifacts.items():
                name = identifier.split(":")[1]
                abi = (json.dumps(artifact["abi"], indent=2) + "\n").encode()
                path = Path("compiler-artifacts") / artifact_path(build_root, identifier).relative_to(build_root / "out")
                (output / path).parent.mkdir(parents=True, exist_ok=True)
                (output / path).write_bytes(artifact["_rawArtifact"])
                (output / "abi" / (name + ".json")).write_bytes(abi)
                report["contracts"][name] = {
                    "artifact": str(path),
                    "sourceArtifact": inventory[identifier] + ":" + name,
                    "artifactSha256": artifact["_artifactSha256"],
                    "abiSha256": hashlib.sha256(abi).hexdigest(),
                    "runtimeBytes": len(bytecode(artifact["deployedBytecode"]["object"])),
                    "creationCodeBytes": len(bytecode(artifact["bytecode"]["object"])),
                    "compiler": artifact["metadata"]["compiler"],
                    "settings": artifact["metadata"]["settings"],
                }
            # Recheck after reading artifact bytes and exporting ABIs as well as after the build/test commands.
            assert_unchanged(before, source_fingerprint(root, before["sourceCommit"]))
            if any(sha256_file(artifact_path(build_root, identifier)) != artifact["_artifactSha256"]
                   for identifier, artifact in artifacts.items()):
                raise ValueError("Compiler artifacts changed during export; evidence cannot pass")
            (output / "build.json").write_text(json.dumps(report, indent=2) + "\n")
            return report
        except Exception as error:
            (output / "export-failed.json").write_text(json.dumps({
                "exportComplete": False, "sourceCommit": before["sourceCommit"], "logs": logs,
                "error": sanitize_log(str(error), environment),
            }, indent=2) + "\n")
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New ignored or external output directory for the release bundle")
    parser.add_argument("--source-revision", help="Require this exact full immutable source commit (default: current HEAD)")
    args = parser.parse_args()
    try:
        report = export_release(Path(__file__).resolve().parents[1], args.output, args.source_revision)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, sanitize_log(str(error)) + "\n")
    print(f"Exported {len(report['contracts'])} ABIs and complete local deployment-size evidence to {args.output}")


if __name__ == "__main__":
    main()
