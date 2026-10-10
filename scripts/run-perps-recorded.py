#!/usr/bin/env python3
"""Run one Forge lane, preserving enough evidence to classify and replay it."""

import argparse
import datetime
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from perps_forge_json import compact

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/perps"
# Explicit allowlist: never serialize RPC URLs, credentials, or the entire environment.
CONFIG_ENV = ("FOUNDRY_PROFILE", "FOUNDRY_VIA_IR", "FOUNDRY_OUT", "FOUNDRY_CACHE_PATH",
              "FOUNDRY_TEST", "FOUNDRY_FUZZ_SEED", "FOUNDRY_FUZZ_RUNS",
              "FOUNDRY_INVARIANT_RUNS", "FOUNDRY_INVARIANT_DEPTH",
              "FOUNDRY_FUZZ_FAILURE_PERSIST_DIR", "FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR",
              "FOUNDRY_FUZZ_CORPUS_DIR", "FOUNDRY_INVARIANT_CORPUS_DIR")
ACTIVE_METADATA = None
ACTIVE_OUTPUT = None
AUTO_PERSIST_ENV = set()
SECRET_CONFIG_FIELDS = {"eth_rpc_url", "eth_rpc_jwt", "eth_rpc_headers", "etherscan_api_key",
                        "rpc_endpoints", "etherscan", "private_key", "private_keys", "mnemonic", "mnemonics"}


def redact_config(value):
    if isinstance(value, dict):
        return {key: ("<redacted>" if key in SECRET_CONFIG_FIELDS and item else redact_config(item))
                for key, item in value.items()}
    if isinstance(value, list):
        return [redact_config(item) for item in value]
    return value


def persist():
    if ACTIVE_METADATA is not None and ACTIVE_OUTPUT is not None:
        (ACTIVE_OUTPUT / "run.json").write_text(json.dumps(ACTIVE_METADATA, indent=2) + "\n")


def interrupt(signum, _frame):
    if ACTIVE_METADATA is not None:
        ACTIVE_METADATA.update(status="interrupted", signal=signum)
        persist()
    raise KeyboardInterrupt


def preserve_corpus(output):
    try:
        config = json.loads((output / "config.json").read_text())
    except (OSError, json.JSONDecodeError):
        return
    locations = []
    for name in ("fuzz", "invariant"):
        for setting, suffix in (("failure_persist_dir", name), ("corpus_dir", name + "-inputs")):
            configured = config.get(name, {}).get(setting)
            if not configured:
                continue
            source = Path(configured)
            if not source.is_absolute():
                source = ROOT / source  # Forge resolves these from its process cwd, not --root/cache_path.
            target = output / "corpus" / suffix
            locations.append({"campaign": name, "setting": setting, "source": str(source),
                              "artifact": str(target), "present": source.exists()})
            if source.exists() and source.resolve() != target.resolve():
                shutil.copytree(source, target, dirs_exist_ok=True)
    (output / "corpus-locations.json").write_text(json.dumps(locations, indent=2) + "\n")


def write_replay(output, command, settings):
    wrapper = os.environ.get("PERPS_REPLAY_COMMAND")
    portable_command = [part.removeprefix(str(ROOT) + "/") for part in command]
    replay = wrapper or shlex.join(portable_command)
    # A wrapper regenerates its scratch paths; direct invocations must retain
    # explicit selection and cache overrides instead of silently losing them.
    replay_settings = {key: value for key, value in settings.items()
                       if key not in AUTO_PERSIST_ENV and
                       (not wrapper or key not in ("FOUNDRY_TEST", "FOUNDRY_OUT", "FOUNDRY_CACHE_PATH"))}
    def portable_setting(value):
        if value == str(ROOT):
            return '"${PWD}"'
        if value.startswith(str(ROOT) + "/"):
            return '"${PWD}"' + shlex.quote(value[len(str(ROOT)):])
        return shlex.quote(value)
    exports = "\n".join(f"export {key}={portable_setting(value)}" for key, value in replay_settings.items())
    if not wrapper:
        for key in sorted(AUTO_PERSIST_ENV):
            suffix = "fuzz" if "_FUZZ_" in key else "invariant"
            exports += f'\nexport {key}="${{replay_dir}}/corpus/{suffix}"'
    (output / "replay.sh").write_text(
        "#!/usr/bin/env bash\nset -euo pipefail\n"
        "# Run from the repository root at commit.txt.\n"
        "# Auto-generated failure_persist_dir paths follow this artifact's corpus/ directory.\n"
        "# Restore explicit external failure_persist_dir/corpus_dir paths from corpus-locations.json if needed.\n"
        'replay_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        'export PERPS_ARTIFACT_DIR="$(dirname "${replay_dir}")"\n'
        + exports + "\n" + replay + "\n")


def selected_ids(discovered):
    return {f"{source}:{contract}::{name.split('(', 1)[0]}"
            for source, contracts in discovered.items()
            for contract, tests in contracts.items() for name in tests}


def capture(command, path):
    secrets = [(key, value) for key, value in os.environ.items()
               if key.endswith(("RPC_URL", "API_KEY", "PRIVATE_KEY", "TOKEN", "SECRET", "JWT"))
               and len(value) >= 8]
    stream_errors = []
    def redact(text):
        for key, value in secrets:
            text = text.replace(value, f"<redacted:{key}>")
        return text
    # Flush each output line as it arrives so timeout/cancellation retains diagnostics.
    def pump(stream, target):
        if command[:2] == ["forge", "test"] and "--list" not in command and target == path:
            with target.open("w") as output, path.with_suffix(".preamble.log").open("w") as diagnostics:
                try:
                    removed = compact(stream, output, diagnostics, redact)
                    path.with_suffix(".trace-compaction.json").write_text(json.dumps({
                        "successful_trace_fields_removed": removed, "failure_traces_preserved": True}) + "\n")
                except (ValueError, OSError) as error:
                    stream_errors.append(str(error))
                    # Drain remaining compiler/tool output to avoid blocking the child.
                    for line in stream:
                        diagnostics.write(redact(line))
            return
        if command[:2] == ["forge", "config"] and target == path:
            # Config may resolve secrets from dotenv/global TOML that are absent
            # from this process's environment. Never write unsanitized config.
            raw = stream.read()
            try:
                target.write_text(json.dumps(redact_config(json.loads(raw)), indent=2) + "\n")
            except json.JSONDecodeError:
                target.write_text("Invalid configuration output; raw text suppressed.\n")
            return
        with target.open("w") as output:
            for line in stream:
                output.write(redact(line))
                output.flush()
    process = subprocess.Popen(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    writers = [threading.Thread(target=pump, args=(process.stdout, path)),
               threading.Thread(target=pump, args=(process.stderr, path.with_suffix(path.suffix + ".stderr")))]
    for writer in writers:
        writer.start()
    try:
        code = process.wait()
    except BaseException:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    finally:
        for writer in writers:
            writer.join()
    if stream_errors:
        path.with_suffix(".capture-error.txt").write_text("\n".join(stream_errors) + "\n")
        return code or 1
    return code


def main():
    global ACTIVE_METADATA, ACTIVE_OUTPUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if command[:2] != ["forge", "test"]:
        parser.error("command must start with forge test")
    output = Path(os.environ.get("PERPS_ARTIFACT_DIR", str(ROOT / "artifacts/perps"))) / args.lane
    output.mkdir(parents=True, exist_ok=True)
    for campaign in ("fuzz", "invariant"):
        key = f"FOUNDRY_{campaign.upper()}_FAILURE_PERSIST_DIR"
        if key not in os.environ:
            os.environ[key] = str(output.resolve() / "corpus" / campaign)
            AUTO_PERSIST_ENV.add(key)
    started = time.time()
    settings = {key: os.environ[key] for key in CONFIG_ENV if key in os.environ}
    metadata = {"lane": args.lane, "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "command": command, "environment": settings, "status": "discovering"}
    ACTIVE_METADATA, ACTIVE_OUTPUT = metadata, output
    persist()
    write_replay(output, command, settings)
    capture(["git", "rev-parse", "HEAD"], output / "commit.txt")
    capture(["git", "status", "--short"], output / "working-tree.txt")
    capture(["forge", "--version"], output / "toolchain.txt")
    if capture(["forge", "config", "--json", "--root", str(PACKAGE)], output / "config.json"):
        metadata.update(status="configuration_failed")
        persist()
        raise SystemExit("cannot capture effective Forge configuration")
    try:
        config = json.loads((output / "config.json").read_text())
    except json.JSONDecodeError as error:
        metadata.update(status="configuration_failed")
        persist()
        raise SystemExit("Forge returned invalid effective configuration") from error
    metadata["budgets"] = {key: config.get(key) for key in ("fuzz", "invariant")}
    metadata["compiler"] = {key: config.get(key) for key in ("solc", "optimizer", "optimizer_runs", "via_ir")}
    persist()
    # Listing verifies the actual executable tests, not just source filenames.
    list_command = [part for part in command if not (part.startswith("-v") or part == "--json")]
    list_command += ["--list", "--json"]
    print(f"[{args.lane}] recording discovered tests", flush=True)
    list_status = capture(list_command, output / "selected-tests.json")
    if list_status:
        metadata.update(status="discovery_failed", exit_code=list_status)
        persist()
        sys.stderr.write((output / "selected-tests.json").read_text())
        sys.stderr.write((output / "selected-tests.json.stderr").read_text())
        raise SystemExit(list_status)
    try:
        discovered = json.loads((output / "selected-tests.json").read_text())
        selected = selected_ids(discovered)
    except (json.JSONDecodeError, AttributeError, TypeError) as error:
        metadata.update(status="discovery_failed", exit_code=1)
        persist()
        raise SystemExit("Forge returned invalid discovery inventory") from error
    metadata["selected_count"] = len(selected)
    expected_inventory = os.environ.get("PERPS_EXPECTED_ENTRYPOINTS")
    if expected_inventory:
        expected = set(Path(expected_inventory).read_text().splitlines())
        test_root = Path(config.get("test", "test"))
        if not test_root.is_absolute():
            test_root = PACKAGE / test_root
        actual = set()
        for source, contracts in discovered.items():
            if not any(contracts.values()):
                continue
            path = Path(source)
            if not path.is_absolute():
                path = PACKAGE / path
            try:
                actual.add(path.relative_to(test_root).as_posix())
            except ValueError:
                continue
        absent = sorted(expected - actual)
        metadata["entrypoint_discovery"] = {"expected": len(expected), "discovered": len(actual), "missing": absent}
        if absent:
            metadata.update(status="discovery_failed", exit_code=1)
            persist()
            raise SystemExit("Assigned entrypoints did not expose executable tests: " + ", ".join(absent))
    print(f"[{args.lane}] {shlex.join(command)}", flush=True)
    metadata.update(status="running", tests_started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
    persist()
    # JSON contains per-test status, skip/failure reason, timings, counterexamples,
    # and invariant handler call/revert/discard statistics. Keep raw output too.
    run_command = list(command)
    if "--json" not in run_command:
        run_command.append("--json")
    if "--suppress-successful-traces" not in run_command and "-s" not in run_command:
        run_command.append("--suppress-successful-traces")
    metadata["execution_command"] = run_command
    persist()
    code = capture(run_command, output / "results.json")
    suites = {}
    try:
        suites = json.loads((output / "results.json").read_text())
    except json.JSONDecodeError:
        # Compiler/tool failure is retained verbatim and must fail the lane.
        if code == 0:
            code = 1
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    test_times = []
    executed = set()
    for suite, data in suites.items():
        for test, result in data.get("test_results", {}).items():
            executed.add(f"{suite}::{test.split('(', 1)[0]}")
            status = {"Success": "passed", "Failure": "failed", "Skipped": "skipped"}.get(result.get("status"))
            if status:
                counts[status] += 1
            else:
                code = 1
            test_times.append({"suite": suite, "test": test, "duration": result.get("duration"),
                               "status": result.get("status"), "reason": result.get("reason")})
            if status in ("failed", "skipped"):
                print(f'{status.upper()}: {suite}::{test}: {result.get("reason")}', flush=True)
    if counts["failed"]:
        code = code or 1  # --allow-failure / FORGE_ALLOW_FAILURE cannot turn this gate green.
    if not test_times and code == 0:
        print("No tests executed; refusing a vacuous success.", file=sys.stderr)
        code = 1
    if os.environ.get("PERPS_REQUIRE_NO_SKIPS") == "1" and counts["skipped"]:
        print("Configured integration coverage must not skip tests.", file=sys.stderr)
        code = 1
    missing, unexpected = sorted(selected - executed), sorted(executed - selected)
    (output / "execution-coverage.json").write_text(json.dumps({
        "selected": len(selected), "executed": len(executed),
        "not_run": missing, "unexpected_results": unexpected}, indent=2) + "\n")
    if missing or unexpected:
        print(f"Discovery/result mismatch: {len(missing)} selected tests not run, "
              f"{len(unexpected)} unexpected results.", file=sys.stderr)
        code = 1
    (output / "test-durations.json").write_text(json.dumps(test_times, indent=2) + "\n")
    preserve_corpus(output)
    metadata.update(status="passed" if code == 0 else "failed", exit_code=code,
                    duration_seconds=round(time.time() - started, 3), counts=counts)
    persist()
    print(f"[{args.lane}] {counts}; exit={code}; artifacts={output}", flush=True)
    if code:
        sys.stderr.write((output / "results.json.stderr").read_text())
    raise SystemExit(code)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        if len(sys.argv) >= 3 and sys.argv[1] == "--config-only":
            raise SystemExit(capture(["forge", "config", "--json", "--root", str(PACKAGE), *sys.argv[3:]], Path(sys.argv[2])))
        else:
            main()
    except KeyboardInterrupt:
        if ACTIVE_METADATA is not None:
            ACTIVE_METADATA.update(status="interrupted")
            persist()
            preserve_corpus(ACTIVE_OUTPUT)
        raise SystemExit(130)
