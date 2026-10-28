#!/usr/bin/env python3
"""Compile and execute a complete physical shard in bounded, serial batches."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/perps"


def fast_result(directory, code):
    """Keep per-mode evidence; an absent or failed mode cannot count as a pass."""
    directory.mkdir(parents=True, exist_ok=True)
    result = {"status": "failed", "counts": {"passed": 0, "failed": 0, "skipped": 0}}
    modes = []
    for name in ("production-gates", "correctness"):
        path = directory / name / "run.json"
        if path.exists():
            mode = json.loads(path.read_text())
            modes.append(mode)
            for key in result["counts"]:
                result["counts"][key] += mode.get("counts", {}).get(key, 0)
            if "budgets" in mode:
                result["budgets"] = mode["budgets"]
    selection = directory / "pr-selection.json"
    if selection.exists():
        result["selection"] = json.loads(selection.read_text())
    if code == 0 and len(modes) == 2 and all(m["status"] == "passed" for m in modes) and selection.exists():
        result["status"] = "passed"
    (directory / "run.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def run(lane, batch_size, fast=False):
    started = time.monotonic()
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
    if fast:
        metadata["selection"] = {"discovered": 0, "production": 0, "correctness": 0,
                                 "missing": [], "unexpected": [], "overlap": [],
                                 "missing_entrypoints": [], "unexpected_entrypoints": [], "failed_batches": []}

    def persist():
        metadata["duration_seconds"] = round(time.monotonic() - started, 3)
        (output / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
        if fast:
            report = dict(metadata["selection"], status=metadata["status"], expected_entrypoints=len(expected),
                          completed_entrypoints=len(metadata["completed_entrypoints"]))
            (output.parent / "pr-selection.json").write_text(json.dumps(report, indent=2) + "\n")

    persist()
    for relative in expected:
        (test_root / relative).unlink()
    failure = 0
    try:
        for index, batch in enumerate(batches):
            batch_started = time.monotonic()
            label = f"batch-{index:03d}"
            expected_file = output / f"{label}-entrypoints.txt"
            expected_file.write_text("\n".join(batch) + "\n")
            metadata["active_batch"] = label
            persist()
            for relative in batch:
                shutil.copyfile(PACKAGE / "test" / relative, test_root / relative)
            print(f"[{lane}] {label} ({index + 1}/{len(batches)}): " + ", ".join(batch), flush=True)
            environment = dict(os.environ, PERPS_EXPECTED_ENTRYPOINTS=str(expected_file))
            command = [
                sys.executable, str(ROOT / "scripts/run-perps-recorded.py"), f"{lane}/{label}", "--",
                "forge", "test", "--offline", "--threads", "1", "-vvv", "--skip", "script",
                "--root", str(PACKAGE),
            ]
            if fast:
                environment["PERPS_ARTIFACT_DIR"] = str(output / label)
                environment["PERPS_REPLAY_ARTIFACT_DIR"] = os.environ["PERPS_ARTIFACT_DIR"]
                command = ["bash", str(ROOT / "scripts/run-perps-fast-batch.sh")]
            process = subprocess.Popen(command, cwd=ROOT, env=environment, start_new_session=True)
            try:
                code = process.wait()
            except BaseException:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
            result = fast_result(output / label, code) if fast else json.loads((output / label / "run.json").read_text())
            metadata["batches"].append({"lane": label, "entrypoints": batch, "exit_code": code,
                                        "status": result["status"],
                                        "duration_seconds": round(time.monotonic() - batch_started, 3)})
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
            if fast:
                for key, value in result.get("selection", {}).items():
                    metadata["selection"][key] += value
                if code or result["status"] != "passed":
                    metadata["selection"]["failed_batches"].append(label)
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
    if sys.argv[3:] not in ([], ["--fast"]):
        raise SystemExit("usage: run-perps-batched.py <lane> <batch size> [--fast]")
    raise SystemExit(run(sys.argv[1], int(sys.argv[2]), fast=bool(sys.argv[3:])))
