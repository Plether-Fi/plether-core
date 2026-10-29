#!/usr/bin/env python3
"""Discover a correctness batch, then run its exact partition with bounded IR builds."""

from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/perps"
LABEL = os.environ.get("PERPS_BATCH_LABEL", "batch")


def announce(message):
    print(f"[fast] {LABEL} {message}", flush=True)


def execute(command, environment, output=None):
    """Forward interruption before callers restore/delete the child's source tree."""
    with ExitStack() as files:
        stdout = files.enter_context(output.open("w")) if output else subprocess.PIPE
        stderr = files.enter_context(output.with_suffix(output.suffix + ".stderr").open("w")) if output else subprocess.STDOUT
        process = subprocess.Popen(command, cwd=ROOT, env=environment, text=True,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            if not output:
                for line in process.stdout:
                    print(f"[{LABEL}] {line.rstrip()}", flush=True)
            return process.wait()
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def ids(discovery):
    return {f"{source}:{contract}::{name.split('(', 1)[0]}"
            for source, contracts in discovery.items()
            for contract, names in contracts.items() for name in names}


def aggregate_production(directory, parts, discovery):
    """Keep the same parent evidence contract as a single recorded production lane."""
    runs = [json.loads((p / "run.json").read_text()) for p in parts]
    metadata = dict(runs[0], lane="production-gates", parts=[p.name for p in parts],
                    selected_count=len(ids(discovery)),
                    status="passed" if all(r.get("status") == "passed" for r in runs) else "failed",
                    exit_code=next((r.get("exit_code", 1) for r in runs if r.get("status") != "passed"), 0),
                    duration_seconds=round(sum(r.get("duration_seconds", 0) for r in runs), 3),
                    execution_capture_seconds=round(sum(r.get("execution_capture_seconds", 0) for r in runs), 3),
                    counts={key: sum(r.get("counts", {}).get(key, 0) for r in runs)
                            for key in ("passed", "failed", "skipped")})
    write_json(directory / "selected-tests.json", discovery)
    results = {}
    test_times = []
    corpora = []
    for part in parts:
        path = part / "results.json"
        if path.exists():
            try:
                data = json.loads(path.read_text())
            except json.JSONDecodeError:
                data = {}  # The failed child retains the compiler/tool diagnostics.
            if results.keys() & data.keys():
                raise ValueError("production subbatches overlap")
            results.update(data)
        for name, target in (("test-durations.json", test_times), ("corpus-locations.json", corpora)):
            path = part / name
            if path.exists():
                target.extend(json.loads(path.read_text()))
    selected = ids(discovery)
    executed = {f"{suite}::{test.split('(', 1)[0]}" for suite, data in results.items()
                for test in data.get("test_results", {})}
    coverage = {"selected": len(selected), "executed": len(executed),
                "not_run": sorted(selected - executed), "unexpected_results": sorted(executed - selected)}
    if coverage["not_run"] or coverage["unexpected_results"]:
        metadata.update(status="failed", exit_code=1)
    metadata["aggregate"] = True
    metadata["part_runs"] = [part.name + "/run.json" for part in parts]
    for key in ("command", "execution_command", "environment", "discovery_source"):
        metadata.pop(key, None)  # Each part records its own exact command/settings.
    write_json(directory / "run.json", metadata)
    write_json(directory / "results.json", results)
    write_json(directory / "execution-coverage.json", coverage)
    write_json(directory / "test-durations.json", test_times)
    write_json(directory / "corpus-locations.json", corpora)
    for name in ("config.json", "commit.txt", "toolchain.txt", "working-tree.txt"):
        shutil.copyfile(parts[0] / name, directory / name)
    # Child replay paths are relative to part-NNN; adjust when exposing the parent replay.
    artifact_root = Path(os.environ["PERPS_REPLAY_ARTIFACT_DIR"]).resolve()
    relative = shlex.quote(os.path.relpath(artifact_root, directory.resolve()))
    replay = (parts[0] / "replay.sh").read_text().splitlines()
    (directory / "replay.sh").write_text("\n".join(
        'export PERPS_ARTIFACT_DIR="$(cd "${replay_dir}"/' + relative + ' && pwd)"'
        if line.startswith("export PERPS_ARTIFACT_DIR=") else line for line in replay) + "\n")


def main():
    required = ("FOUNDRY_TEST", "PERPS_EXPECTED_ENTRYPOINTS", "PERPS_BATCH_BUILD_ROOT")
    if any(not os.environ.get(key) for key in required):
        raise ValueError("run-perps-fast-batch requires a physical batch, build root and expected entrypoints")
    test_root = PACKAGE / os.environ["FOUNDRY_TEST"]
    if test_root.parent.parent != PACKAGE or not test_root.parent.name.startswith(".package-test-shard."):
        raise ValueError("fast batches require an owned disposable physical tree")
    production_size = int(os.environ.get("PERPS_PRODUCTION_BATCH_SIZE", "4"))
    if production_size <= 0:
        raise ValueError("production batch size must be positive")
    output = Path(os.environ["PERPS_ARTIFACT_DIR"])
    output.mkdir(parents=True, exist_ok=True)
    for name in ("run.json", "pr-selection.json", "production-gates/run.json", "correctness/run.json"):
        (output / name).unlink(missing_ok=True)
    build_root = Path(os.environ["PERPS_BATCH_BUILD_ROOT"])
    environment = dict(os.environ)
    environment.pop("PERPS_EXPECTED_ENTRYPOINTS", None)
    environment.setdefault("FOUNDRY_PROFILE", "quick")

    def build_environment(name, via_ir):
        build = build_root / name
        return dict(environment, FOUNDRY_VIA_IR=str(via_ir).lower(),
                    FOUNDRY_OUT=str(build / "out"), FOUNDRY_CACHE_PATH=str(build / "cache"))

    def recorded(lane, discovery, settings):
        return execute([sys.executable, str(ROOT / "scripts/run-perps-recorded.py"),
                        "--allow-empty-partition", "--trace-failures", "--discovery-file", str(discovery),
                        lane, "--", "forge", "test", "--offline", "--threads", "1", "--skip", "script",
                        "--root", str(PACKAGE), "--no-match-path", "**/fork/**",
                        "--match-test" if settings["FOUNDRY_VIA_IR"] == "true" else "--no-match-test",
                        production_regex], settings)

    inventory = subprocess.check_output([sys.executable, str(ROOT / "scripts/perps-test-inventory.py")], cwd=ROOT)
    (output / "inventory.json").write_bytes(inventory)
    production_regex = subprocess.check_output(
        [sys.executable, str(ROOT / "scripts/perps-test-inventory.py"), "--production-test-regex"], cwd=ROOT, text=True).strip()
    pattern = re.compile(production_regex)
    correctness_environment = build_environment("correctness", False)
    announce("discovering tests (ordinary compilation)")
    started = time.monotonic()
    code = execute(["forge", "test", "--offline", "--threads", "1", "--root", str(PACKAGE),
                    "--skip", "script", "--no-match-path", "**/fork/**", "--list", "--json"],
                   correctness_environment, output / "all-tests.json")
    elapsed = round(time.monotonic() - started, 3)
    write_json(output / "discovery-timing.json", {"duration_seconds": elapsed, "exit_code": code})
    announce(f"discovery completed in {elapsed:.2f}s")
    if code:
        for name in ("all-tests.json", "all-tests.json.stderr"):
            print((output / name).read_text()[-12000:], file=sys.stderr)
        return code
    discovered = json.loads((output / "all-tests.json").read_text())
    selections = {}
    for lane, keep in (("production-gates", True), ("correctness", False)):
        selections[lane] = {source: {contract: [n for n in names if bool(pattern.search(n)) == keep]
                                     for contract, names in contracts.items()}
                            for source, contracts in discovered.items()}
        write_json(output / (lane + "-discovery.json"), selections[lane])

    # Reject omissions/extra cached sources before any test can be counted as a pass.
    actual = set()
    for source, contracts in discovered.items():
        if any(contracts.values()):
            path = Path(source)
            path = path if path.is_absolute() else PACKAGE / path
            try:
                actual.add(path.relative_to(test_root).as_posix())
            except ValueError:
                actual.add(str(path))
    expected = set(Path(os.environ["PERPS_EXPECTED_ENTRYPOINTS"]).read_text().splitlines())
    partition = {"discovered": len(ids(discovered)), "production": len(ids(selections["production-gates"])),
                 "correctness": len(ids(selections["correctness"])), "missing": [], "unexpected": [], "overlap": [],
                 "missing_entrypoints": sorted(expected - actual), "unexpected_entrypoints": sorted(actual - expected)}
    write_json(output / "pr-selection.json", partition)
    if not partition["discovered"] or expected != actual:
        raise ValueError("PR lanes are not an exact discovery partition: " + json.dumps(partition))

    production = selections["production-gates"]
    sources = [source for source, contracts in production.items() if any(contracts.values())]
    groups = [sources[i:i + production_size] for i in range(0, len(sources), production_size)] or [[]]
    original = {p.relative_to(test_root): p.read_bytes() for p in test_root.rglob("*.t.sol")}

    def restore(selected):
        for path in test_root.rglob("*.t.sol"):
            path.unlink()
        for relative, contents in original.items():
            if relative in selected:
                (test_root / relative).write_bytes(contents)

    failure = 0
    parts = []
    try:
        for index, group in enumerate(groups):
            lane = "production-gates" if len(groups) == 1 else f"production-gates/part-{index:03d}"
            selected = {source: production[source] for source in group}
            if group:
                relatives = {(Path(source) if Path(source).is_absolute() else PACKAGE / source).relative_to(test_root)
                             for source in group}
                restore(relatives)
            discovery = output / f"production-{index:03d}-discovery.json"
            write_json(discovery, selected)
            announce(f"production part {index + 1}/{len(groups)}: {len(group)} source files")
            code = recorded(lane, discovery, build_environment(f"production-{index:03d}", True))
            failure = failure or code
            parts.append(output / lane)
    finally:
        restore(set(original))
    if len(parts) > 1:
        aggregate_production(output / "production-gates", parts, production)
    code = recorded("correctness", output / "correctness-discovery.json", correctness_environment)
    failure = failure or code
    code = execute([sys.executable, str(ROOT / "scripts/check-perps-pr-selection.py"),
                    str(output), str(PACKAGE), os.environ["PERPS_EXPECTED_ENTRYPOINTS"]], environment)
    return failure or code


if __name__ == "__main__":
    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    raise SystemExit(main())
