#!/usr/bin/env python3
"""Build and export perps consumer ABIs and production bytecode size evidence. Never broadcasts."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New output directory for the release bundle")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    if output.exists():
        parser.error("output directory already exists; choose a new directory")

    def git(*arguments):
        return subprocess.check_output(["git", *arguments], cwd=root, text=True).strip()

    source_paths = ["script", "lib", "foundry.toml", "foundry.lock"]
    source_paths += [str(path.relative_to(root)) for path in (root / "packages").glob("*/src")]
    source_paths += [str(path.relative_to(root)) for path in (root / "packages").glob("*/foundry.toml")]
    if git("status", "--porcelain", "--", *source_paths):
        parser.error("commit or discard source/build-input changes before exporting a release")
    submodules = git("submodule", "status", "--recursive").splitlines()
    if not submodules or any(line.startswith(("-", "+", "U")) for line in submodules):
        parser.error("initialize submodules at their pinned commits before exporting a release")
    forge_version = subprocess.check_output(["forge", "--version"], text=True).splitlines()[0]
    if forge_version != "forge Version: 1.5.1-stable":
        parser.error("release artifacts require Forge 1.5.1-stable")
    subprocess.run(["forge", "build", "--skip", "test"], cwd=root, check=True)

    manifest = json.loads((root / "deployments/arbitrum-sepolia-perps.template.json").read_text())
    names = {
        "mockUsdc": "MockUSDC",
        "housePool": "ArbitrumSepoliaReleaseHousePool",
        "pletherOracle": "ArbitrumSepoliaReleaseOracle",
        "orderRouter": "ArbitrumSepoliaReleaseRouter",
        "seniorVault": "TrancheVault",
        "juniorVault": "TrancheVault",
    }
    artifacts = {}
    for key in manifest["contracts"]:
        name = names.get(key, key[0].upper() + key[1:])
        source = (
            "DeployPerpsArbitrumSepolia.s.sol"
            if name == "MockUSDC" or name.startswith("ArbitrumSepoliaRelease")
            else name + ".sol"
        )
        artifacts[name] = root / "out" / source / (name + ".json")
    for path in sorted((root / "packages/perps/src/interfaces").glob("*.sol")):
        artifact = root / "out" / path.name / (path.stem + ".json")
        if artifact.exists():
            artifacts[path.stem] = artifact

    report = {
        "sourceCommit": git("rev-parse", "HEAD"),
        "submodules": submodules,
        "forgeVersion": forge_version,
        "note": "Runtime sizes are compiler templates before immutable substitution. Creation-code sizes exclude constructor arguments; verify full creation inputs in the RPC simulation. ABI hashes are SHA-256, not on-chain runtime hashes.",
        "contracts": {},
    }
    payloads = {}
    for name, path in artifacts.items():
        artifact = json.loads(path.read_text())
        settings = artifact["metadata"]["settings"]
        if (
            not artifact["metadata"]["compiler"]["version"].startswith("0.8.35+")
            or settings.get("viaIR") is not True
            or settings.get("optimizer") != {"enabled": True, "runs": 200}
            or settings.get("evmVersion") != "prague"
        ):
            raise SystemExit(f"{name} was not compiled with the reviewed production settings")
        abi = (json.dumps(artifact["abi"], indent=2) + "\n").encode()
        runtime_size = len(artifact["deployedBytecode"]["object"].removeprefix("0x")) // 2
        creation_size = len(artifact["bytecode"]["object"].removeprefix("0x")) // 2
        if runtime_size > 24576 or creation_size > 49152:
            raise SystemExit(f"{name} exceeds production deployment size limits")
        payloads[name] = abi
        report["contracts"][name] = {
            "artifact": str(path.relative_to(root)),
            "abiSha256": hashlib.sha256(abi).hexdigest(),
            "runtimeBytes": runtime_size,
            "creationCodeBytes": creation_size,
            "compiler": artifact["metadata"]["compiler"],
            "settings": artifact["metadata"]["settings"],
        }
    output.mkdir(parents=True)
    (output / "abi").mkdir()
    for name, abi in payloads.items():
        (output / "abi" / (name + ".json")).write_bytes(abi)
    (output / "build.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Exported {len(payloads)} ABIs and build evidence to {output}")


if __name__ == "__main__":
    main()
