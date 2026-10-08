#!/usr/bin/env python3
"""Package an exported perps bundle reproducibly. Never builds, publishes or broadcasts."""

import argparse
import gzip
import hashlib
import io
import json
import re
import tarfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="Export directory with README.md and verification.json")
    parser.add_argument("output", type=Path, help="New output directory")
    parser.add_argument("--version", required=True, help="Release tag and archive root name")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.version):
        parser.error("version must be a portable filename")
    if args.output.exists():
        parser.error("output directory already exists; choose a new directory")

    bundle = args.bundle.resolve()
    build = json.loads((bundle / "build.json").read_text())
    files = [bundle / name for name in ("README.md", "build.json", "verification.json")]
    abi_files = sorted((bundle / "abi").glob("*.json"))
    if {p.stem for p in abi_files} != set(build["contracts"]):
        parser.error("ABI files must match the build manifest exactly")
    files += abi_files
    payloads = {}
    for path in files:
        if path.is_symlink() or not path.is_file():
            parser.error(f"expected a regular file: {path}")
        payload = path.read_bytes()
        if path.parent.name == "abi":
            expected = build["contracts"][path.stem]["abiSha256"]
            if hashlib.sha256(payload).hexdigest() != expected:
                parser.error(f"ABI checksum mismatch: {path.name}")
        payloads[path.relative_to(bundle).as_posix()] = payload

    checksums = "".join(
        f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
        for name, payload in sorted(payloads.items())
    ).encode()
    payloads["SHA256SUMS"] = checksums
    args.output.mkdir(parents=True)
    archive = args.output / f"{args.version}.tar.gz"
    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for name, payload in sorted(payloads.items()):
                    info = tarfile.TarInfo(f"{args.version}/{name}")
                    info.size = len(payload)
                    info.mode = 0o644
                    tar.addfile(info, io.BytesIO(payload))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.output / f"{archive.name}.sha256").write_text(f"{digest}  {archive.name}\n")
    (args.output / "SHA256SUMS").write_bytes(checksums)
    manifest = {
        "version": args.version,
        "sourceCommit": build["sourceCommit"],
        "archive": archive.name,
        "archiveSha256": digest,
        "archiveBytes": archive.stat().st_size,
        "archiveRoot": args.version,
        "abiCount": len(abi_files),
        "payloadFileCount": len(payloads) - 1,
        "checksumsFile": "SHA256SUMS",
        "checksumsSha256": hashlib.sha256(checksums).hexdigest(),
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
