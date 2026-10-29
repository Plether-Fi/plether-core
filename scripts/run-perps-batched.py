#!/usr/bin/env python3
"""Compile a complete physical shard with bounded builds and isolated fast workers."""

import json
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/perps"


def run_fast(lane, batch_size):
    """Isolate each build so batches can overlap without evicting each other's cache."""
    started = time.monotonic()
    workers = int(os.environ.get("PERPS_FAST_WORKERS", "1"))
    if workers <= 0 or batch_size <= 0:
        raise ValueError("batch size and workers must be positive")
    test_root = PACKAGE / os.environ["FOUNDRY_TEST"]
    if test_root.parent.parent != PACKAGE or not test_root.parent.name.startswith(".package-test-shard."):
        raise ValueError("batching requires a disposable physical shard")
    expected = Path(os.environ["PERPS_EXPECTED_ENTRYPOINTS"]).read_text().splitlines()
    actual = {p.relative_to(test_root).as_posix() for p in test_root.rglob("*.t.sol")}
    if not expected or len(set(expected)) != len(expected) or set(expected) != actual:
        raise ValueError("batch inputs must exactly match the assigned shard entrypoints")
    output = Path(os.environ["PERPS_ARTIFACT_DIR"]) / lane
    output.mkdir(parents=True, exist_ok=True)
    batches = [expected[i:i + batch_size] for i in range(0, len(expected), batch_size)]
    metadata = {"status": "running", "batch_size": batch_size, "workers": workers,
                "production_batch_size": int(os.environ.get("PERPS_PRODUCTION_BATCH_SIZE", "4")),
                "expected_entrypoints": expected, "completed_entrypoints": [], "batches": [],
                "counts": {"passed": 0, "failed": 0, "skipped": 0},
                "selection": {"discovered": 0, "production": 0, "correctness": 0,
                              "missing": [], "unexpected": [], "overlap": [],
                              "missing_entrypoints": [], "unexpected_entrypoints": [], "failed_batches": []}}
    active = {}
    failure = 0

    def persist():
        metadata["duration_seconds"] = round(time.monotonic() - started, 3)
        metadata["active_batches"] = [job["label"] for job in active.values()]
        (output / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
        report = dict(metadata["selection"], status=metadata["status"], expected_entrypoints=len(expected),
                      completed_entrypoints=len(metadata["completed_entrypoints"]))
        (output.parent / "pr-selection.json").write_text(json.dumps(report, indent=2) + "\n")

    def launch(index):
        batch = batches[index]
        label = f"batch-{index:03d}"
        identity = hashlib.sha256(json.dumps(batch).encode()).hexdigest()[:16]
        scratch = test_root.parent.with_name(test_root.parent.name + "-" + identity)
        scratch.mkdir()  # Reject a live/abandoned tree; only compiler outputs persist.
        try:
            shutil.copytree(test_root, scratch / "test", ignore=shutil.ignore_patterns("*.t.sol"))
            for relative in batch:
                destination = scratch / "test" / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(PACKAGE / "test" / relative, destination)
            expected_file = output / f"{label}-entrypoints.txt"
            expected_file.write_text("\n".join(batch) + "\n")
            environment = dict(os.environ, PERPS_EXPECTED_ENTRYPOINTS=str(expected_file),
                               FOUNDRY_TEST=str((scratch / "test").relative_to(PACKAGE)),
                               PERPS_BATCH_BUILD_ROOT=str(PACKAGE / ".perps-test-build" / scratch.name),
                               PERPS_BATCH_LABEL=label, PERPS_ARTIFACT_DIR=str(output / label),
                               PERPS_REPLAY_ARTIFACT_DIR=os.environ["PERPS_ARTIFACT_DIR"])
            print(f"[{lane}] {label} ({index + 1}/{len(batches)}): " + ", ".join(batch), flush=True)
            # A pending interrupt must see the new worker in the cleanup registry.
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
            try:
                process = subprocess.Popen(["bash", str(ROOT / "scripts/run-perps-fast-batch.sh")],
                                           cwd=ROOT, env=environment, start_new_session=True,
                                           preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask))
                active[process.pid] = {"process": process, "scratch": scratch, "label": label,
                                       "batch": batch, "started": time.monotonic()}
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            metadata["active_batch"] = label
        except BaseException:
            if not any(job["scratch"] == scratch for job in active.values()):
                shutil.rmtree(scratch)
            raise

    persist()
    next_batch = 0
    try:
        while next_batch < len(batches) or active:
            while next_batch < len(batches) and len(active) < workers:
                launch(next_batch)
                next_batch += 1
                persist()
            finished = [pid for pid, job in active.items() if job["process"].poll() is not None]
            if not finished:
                time.sleep(0.1)
                continue
            for pid in finished:
                job = active[pid]
                code = job["process"].returncode
                result = fast_result(output / job["label"], code)
                duration = round(time.monotonic() - job["started"], 3)
                metadata["batches"].append({"lane": job["label"], "entrypoints": job["batch"],
                                            "exit_code": code, "status": result["status"],
                                            "duration_seconds": duration})
                metadata["batches"].sort(key=lambda b: b["lane"])
                for key in metadata["counts"]:
                    metadata["counts"][key] += result.get("counts", {}).get(key, 0)
                if "budgets" in result:
                    metadata["budgets"] = result["budgets"]
                for key, value in result.get("selection", {}).items():
                    metadata["selection"][key] += value
                if code == 0 and result["status"] == "passed":
                    metadata["completed_entrypoints"].extend(job["batch"])
                else:
                    failure = failure or code or 1
                    metadata["selection"]["failed_batches"].append(job["label"])
                shutil.rmtree(job["scratch"])
                del active[pid]
                persist()
                print(f"[{lane}] {job['label']} {result['status']} in {duration:.2f}s", flush=True)
        if set(metadata["completed_entrypoints"]) != set(expected):
            failure = failure or 1
        metadata.update(status="failed" if failure else "passed", exit_code=failure)
        persist()
    except BaseException as error:
        # Recorders forward termination to their separately grouped Forge children.
        for job in active.values():
            try:
                os.killpg(job["process"].pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 10
        for job in active.values():
            try:
                job["process"].wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                os.killpg(job["process"].pid, signal.SIGKILL)
                job["process"].wait()
            shutil.rmtree(job["scratch"], ignore_errors=True)
        active.clear()
        metadata.update(status="interrupted" if isinstance(error, KeyboardInterrupt) else "failed", exit_code=1)
        persist()
        raise
    print(f"[{lane}] {metadata['counts']}; batches={len(batches)}; workers={workers}; "
          f"duration={metadata['duration_seconds']:.2f}s; exit={failure}; artifacts={output}", flush=True)
    return failure


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
    if fast:
        return run_fast(lane, batch_size)
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
    def persist():
        metadata["duration_seconds"] = round(time.monotonic() - started, 3)
        (output / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")

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
            result = json.loads((output / label / "run.json").read_text())
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
            persist()
            print(f"[{lane}] {label} {result['status']} in "
                  f"{time.monotonic() - batch_started:.2f}s", flush=True)
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
