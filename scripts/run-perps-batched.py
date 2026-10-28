#!/usr/bin/env python3
"""Compile and execute a complete physical shard in bounded, serial batches."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/perps"


def run(lane, batch_size):
    if batch_size <= 0:
        raise ValueError("batch size must be positive")
    test_root = PACKAGE / os.environ["FOUNDRY_TEST"]
    # Only mutate the disposable tree created by run-perps-package-tests.sh.
    if test_root.parent.parent != PACKAGE or not test_root.parent.name.startswith(".package-test-shard."):
        raise ValueError("batching requires a disposable physical shard")
    expected = Path(os.environ["PERPS_EXPECTED_ENTRYPOINTS"]).read_text().splitlines()
    actual = {p.relative_to(test_root).as_posix() for p in test_root.rglob("*.t.sol")}
    if not expected or len(set(expected)) != len(expected) or set(expected) != actual:
        raise ValueError("batch inputs must exactly match the assigned shard entrypoints")
    output = Path(os.environ["PERPS_ARTIFACT_DIR"]) / lane
    output.mkdir(parents=True, exist_ok=True)
    batches = [expected[i:i + batch_size] for i in range(0, len(expected), batch_size)]
    metadata = {"status": "running", "batch_size": batch_size, "expected_entrypoints": expected,
                "completed_entrypoints": [], "batches": [],
                "counts": {"passed": 0, "failed": 0, "skipped": 0}}

    def persist():
        (output / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")

    persist()
    for relative in expected:
        (test_root / relative).unlink()
    failure = 0
    try:
        for index, batch in enumerate(batches):
            label = f"batch-{index:03d}"
            expected_file = output / f"{label}-entrypoints.txt"
            expected_file.write_text("\n".join(batch) + "\n")
            for relative in batch:
                shutil.copyfile(PACKAGE / "test" / relative, test_root / relative)
            print(f"[{lane}] {label} ({index + 1}/{len(batches)}): " + ", ".join(batch), flush=True)
            environment = dict(os.environ, PERPS_EXPECTED_ENTRYPOINTS=str(expected_file))
            process = subprocess.Popen([
                sys.executable, str(ROOT / "scripts/run-perps-recorded.py"), f"{lane}/{label}", "--",
                "forge", "test", "--offline", "--threads", "1", "-vvv", "--skip", "script",
                "--root", str(PACKAGE),
            ], cwd=ROOT, env=environment)
            try:
                code = process.wait()
            except BaseException:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise
            result = json.loads((output / label / "run.json").read_text())
            metadata["batches"].append({"lane": label, "entrypoints": batch, "exit_code": code,
                                        "status": result["status"]})
            for name in metadata["counts"]:
                metadata["counts"][name] += result.get("counts", {}).get(name, 0)
            # Preserve effective settings alongside the aggregate, as well as in each batch.
            for key in ("budgets", "compiler", "environment"):
                if key in result:
                    metadata[key] = result[key]
            if code == 0 and result["status"] == "passed":
                metadata["completed_entrypoints"].extend(batch)
            else:
                failure = failure or code or 1
            persist()
            for relative in batch:
                (test_root / relative).unlink()
        if set(metadata["completed_entrypoints"]) != set(expected):
            failure = failure or 1
        metadata.update(status="failed" if failure else "passed", exit_code=failure)
        persist()
    except BaseException:
        metadata.update(status="interrupted", exit_code=1)
        persist()
        raise
    print(f"[{lane}] {metadata['counts']}; batches={len(batches)}; exit={failure}; artifacts={output}", flush=True)
    return failure


if __name__ == "__main__":
    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    raise SystemExit(run(sys.argv[1], int(sys.argv[2])))
