"""Shared fail-closed release evidence checks. This module never builds or broadcasts."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


GAS_CAP = 30_000_000
SCENARIOS = {
    "historical_single": ("executed", [2], 1, 1, 2),
    "shared_basket_batch": ("executed", [2, 2], 1, 1, 2),
    "distinct_basket_batch": ("executed", [2, 2], 2, 2, 4),
    "frozen_close": ("executed", [2], 0, 1, 1),
    "caught_target_failure": ("failed", [3], 1, 1, 2),
    "unavailable_immediate": ("pending", [1], 1, 0, 0),
    "unavailable_deferred": ("pending", [1], 1, 0, 0),
}
FIXTURE_NAMES = {"historicalA", "historicalB", "fridayOpening", "fridayClosing"}
PYTH = "0x0b73614636c855bf23f342f307fb981a3e47f42b"


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha256_file(path):
    return sha256_bytes(Path(path).read_bytes())


def _git(repo, *arguments):
    return subprocess.check_output(["git", *arguments], cwd=repo)


def source_fingerprint(repo, source_revision=None):
    """Fingerprint every tracked input and recursively pinned dependency, requiring clean inputs.

    Ignored build outputs may change; untracked nonignored inputs may not. File content is
    hashed instead of relying on git's timestamp/index optimizations. No file data is returned.
    """
    repo = Path(repo).resolve()
    revision = _git(repo, "rev-parse", "HEAD").decode().strip()
    if source_revision is not None and revision != source_revision:
        raise ValueError("Source revision changed or is not the requested immutable commit")
    if _git(repo, "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none").strip():
        raise ValueError("Commit all source, fixtures, tooling, templates and dependency changes before qualification")
    object_format = _git(repo, "rev-parse", "--show-object-format").decode().strip()
    entries = []
    dependencies = []
    for entry in _git(repo, "ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, object_id, stage = metadata.decode().split()
        if stage != "0":
            raise ValueError("Unmerged input cannot qualify")
        name = os.fsdecode(raw_path)
        path = repo / name
        if mode == "160000":
            if not (path / ".git").exists():
                raise ValueError("Initialize every pinned dependency before qualification")
            dependency = source_fingerprint(path, object_id)
            dependencies.append(dict(path=name, **dependency))
        else:
            content = os.fsencode(os.readlink(path)) if mode == "120000" else path.read_bytes()
            # git status may suppress assume-unchanged/skip-worktree edits. The bytes being
            # built must independently match the committed blob, including on the first run.
            blob = hashlib.new(object_format, b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
            if blob != object_id:
                raise ValueError("Tracked input bytes differ from the pinned revision")
            entries.append(dict(path=name, mode=mode, sha256=sha256_bytes(content)))
    record = dict(schemaVersion=1, sourceCommit=revision, files=entries, dependencies=dependencies)
    return dict(record, sha256=sha256_bytes(canonical_json(record).encode()))


def assert_unchanged(before, after):
    if before != after:
        raise ValueError("Qualification inputs changed during execution; evidence cannot pass")


def require_tracked_file(repo, path):
    path = Path(path).resolve()
    try:
        relative = path.relative_to(Path(repo).resolve())
    except ValueError as error:
        raise ValueError("Qualification fixtures and manifests must be committed in this repository") from error
    if not path.is_file():
        raise ValueError("Required fixture or manifest is missing")
    if not _git(repo, "ls-files", "--error-unmatch", "--", str(relative)).strip():
        raise ValueError("Fixture or manifest must be tracked")
    return path


def sanitize_log(output, environment=None):
    """Remove secrets and all URLs before a subprocess log reaches persistent evidence."""
    output = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output)
    environment = os.environ if environment is None else environment
    for name, value in sorted(environment.items(), key=lambda pair: len(pair[1]), reverse=True):
        if len(value) >= 4 and re.search(r"(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|RPC|URL)", name, re.I):
            output = output.replace(value, "[REDACTED]")
    return re.sub(r"https?://[^\s\"'<>]+", "[REDACTED_URL]", output)


def production_environment(environment=None):
    """Do not let shell-level Foundry overrides silently replace committed production settings."""
    environment = os.environ if environment is None else environment
    result = {name: value for name, value in environment.items()
              if not name.startswith(("FOUNDRY_", "DAPP_"))}
    result.update(FOUNDRY_PROFILE="ci", FOUNDRY_VIA_IR="true")
    return result


def integer(value, field):
    if type(value) is not int or value < 0:
        raise ValueError(f"{field} must be a nonnegative integer")
    return value


def _hex(value, length=None):
    if not isinstance(value, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", value):
        raise ValueError("Malformed hexadecimal fixture value")
    if length is not None and len(value) != 2 + 2 * length:
        raise ValueError("Unexpected hexadecimal fixture length")
    return value


def validate_fixture(fixture, require_mismatch=False, require_provenance=False):
    if fixture.get("schemaVersion") != 1 or fixture.get("chainId") != 421614:
        raise ValueError("Expected a version-1 Arbitrum Sepolia fixture")
    if str(fixture.get("pyth", "")).lower() != PYTH:
        raise ValueError("Unsupported Pyth deployment")
    ids = fixture["feedIds"]
    if not isinstance(ids, list) or len(ids) != 6 or len(set(ids)) != 6:
        raise ValueError("Expected six distinct configured feeds")
    for feed in ids:
        _hex(feed, 32)
    for field in ("publishTimes", "previousPublishTimes", "initialStoredPublishTimes", "quantities", "basePrices"):
        if not isinstance(fixture[field], list) or len(fixture[field]) != 6:
            raise ValueError(f"{field} must cover every feed")
        for value in fixture[field]:
            integer(value, field)
    if len(fixture["inversions"]) != 6 or any(type(value) is not bool for value in fixture["inversions"]):
        raise ValueError("Expected six inversion flags")
    commit = integer(fixture["commitTimestamp"], "commitTimestamp")
    execution = integer(fixture["executionTimestamp"], "executionTimestamp")
    fork_time = integer(fixture["forkTimestamp"], "forkTimestamp")
    fork_block = integer(fixture["forkBlockNumber"], "forkBlockNumber")
    execution_block = integer(fixture["executionBlock"], "executionBlock")
    _hex(fixture["forkBlockHash"], 32)
    if not fork_time <= commit < execution <= commit + 15 or execution_block <= fork_block:
        raise ValueError("Invalid fork, commit, execution chronology or settlement window")
    times = fixture["publishTimes"]
    if max(times) - min(times) > 5:
        raise ValueError("Fixture exceeds configured feed divergence")
    if not all(previous <= commit < tick <= execution for previous, tick in zip(fixture["previousPublishTimes"], times)):
        raise ValueError("Every feed must satisfy the unique-tick window")
    if require_mismatch and min(fixture["initialStoredPublishTimes"]) >= min(times):
        raise ValueError("Already-current storage cannot reproduce the regression")
    if require_mismatch and execution - min(fixture["initialStoredPublishTimes"]) > 60:
        raise ValueError("Initial storage cannot independently fail live freshness")
    data = fixture["updateData"]
    if not isinstance(data, list) or not data:
        raise ValueError("Exact signed payload bytes are required")
    for value in data:
        _hex(value)
    digest = sha256_bytes(json.dumps(data, separators=(",", ":")).encode())
    if digest != fixture.get("payloadSha256"):
        raise ValueError("Signed payload checksum mismatch")
    if require_provenance:
        provenance = fixture.get("payloadSource", {})
        _hex(provenance.get("transactionHash"), 32)
        integer(provenance.get("transactionBlock"), "transactionBlock")
        _hex(provenance.get("destination"), 20)
        _hex(provenance.get("selector"), 4)
    return fixture


def load_scenario_manifest(repo, path):
    path = require_tracked_file(repo, path)
    manifest = json.loads(path.read_text())
    if manifest.get("schemaVersion") != 1 or set(manifest.get("fixtures", {})) != FIXTURE_NAMES:
        raise ValueError("Scenario manifest must identify each required fixture exactly once")
    fixtures = {}
    for name, relative in manifest["fixtures"].items():
        if not isinstance(relative, str) or Path(relative).is_absolute():
            raise ValueError("Scenario fixture paths must be repository-relative")
        fixture_path = require_tracked_file(repo, Path(repo) / relative)
        fixture = validate_fixture(json.loads(fixture_path.read_text()), require_provenance=True)
        fixtures[name] = dict(path=relative, fileSha256=sha256_file(fixture_path), fixture=fixture)
    first, second = (fixtures[name]["fixture"] for name in ("historicalA", "historicalB"))
    if second["commitTimestamp"] < min(first["publishTimes"]):
        raise ValueError("Distinct baskets must prevent reuse of the first basket")
    if first["payloadSha256"] == second["payloadSha256"]:
        raise ValueError("Distinct baskets require different signed ticks")
    common = ("feedIds", "quantities", "basePrices", "inversions")
    if any(value["fixture"][field] != first[field] for value in fixtures.values() for field in common):
        raise ValueError("All scenarios must use the same configured basket")
    return dict(path=str(path.relative_to(Path(repo).resolve())), fileSha256=sha256_file(path), fixtures=fixtures)


def parse_scenario_records(output):
    records = []
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("oracle-sync-evidence:"):
            records.append(json.loads(line.split(":", 1)[1].strip()))
    return records


def validate_scenario_records(records, manifest=None):
    """Do not accept success-looking gas numbers without receipts, coverage and ETH accounting."""
    seen = set()
    fields = ("callGas", "gasCap", "quoteWei", "fundedWei", "pythFeeDeltaWei", "immediateRefundWei",
              "oracleDeferredWei", "routerDeferredWei", "oracleClaimedWei", "routerClaimedWei",
              "oracleCreditedWei", "routerCreditedWei", "terminalCount", "markTime", "markPrice",
              "expectedParseCalls", "expectedUpdateCalls", "payloadBytes", "executionTimestamp", "executionBlock")
    for record in records:
        scenario = record.get("scenarioId")
        if scenario not in SCENARIOS or scenario in seen:
            raise ValueError("Unknown or duplicate scenario evidence")
        seen.add(scenario)
        if (record.get("schemaVersion") != 1 or record.get("isolationMode") != "transaction"
                or record.get("isolationVerified") is not True):
            raise ValueError("Evidence must use transaction isolation")
        for field in fields:
            integer(record.get(field), field)
        if not 0 < record["callGas"] <= record["gasCap"] == GAS_CAP or not record["payloadBytes"]:
            raise ValueError("Missing payload, invalid gas cap or exceeded keeper gas limit")
        outcome, statuses, parses, updates, fee_multiplier = SCENARIOS[scenario]
        if record.get("outcome") != outcome or record.get("lifecycleStatuses") != statuses:
            raise ValueError("Receipt outcomes do not demonstrate the required execution progress")
        if record["terminalCount"] != sum(status != 1 for status in statuses):
            raise ValueError("Incorrect completed receipt count")
        order_ids, commits, deadlines = (record.get(field) for field in ("orderIds", "orderCommitTimes", "executionDeadlines"))
        if any(not isinstance(values, list) or len(values) != len(statuses) for values in (order_ids, commits, deadlines)):
            raise ValueError("Every measured order must record identity, commit time and execution deadline")
        if len(set(order_ids)) != len(order_ids) or not record["executionTimestamp"] or not record["executionBlock"]:
            raise ValueError("Duplicate order or missing execution timing")
        for order_id, commit, deadline in zip(order_ids, commits, deadlines):
            integer(order_id, "orderIds")
            integer(commit, "orderCommitTimes")
            integer(deadline, "executionDeadlines")
            if not commit <= record["executionTimestamp"] <= deadline:
                raise ValueError("Measured order is outside its execution deadline")
        if (record["expectedParseCalls"], record["expectedUpdateCalls"]) != (parses, updates):
            raise ValueError("Unexpected Pyth resolution paths")
        if record["pythFeeDeltaWei"] != fee_multiplier * record["quoteWei"]:
            raise ValueError("Pyth fees do not match the quoted scenario allocation")
        accounted = sum(record[field] for field in ("pythFeeDeltaWei", "immediateRefundWei", "oracleDeferredWei",
                        "routerDeferredWei", "oracleClaimedWei", "routerClaimedWei"))
        if record["fundedWei"] != accounted:
            raise ValueError("Scenario does not conserve keeper ETH")
        if record["oracleCreditedWei"] != record["oracleDeferredWei"] + record["oracleClaimedWei"]:
            raise ValueError("Oracle claim accounting mismatch")
        if record["routerCreditedWei"] != record["routerDeferredWei"] + record["routerClaimedWei"]:
            raise ValueError("Router claim accounting mismatch")
        stored, required = record.get("storedPublishTimes"), record.get("requiredPublishTimes")
        if not isinstance(stored, list) or not isinstance(required, list) or len(stored) != 6 or len(required) != 6:
            raise ValueError("Coverage must include all configured feeds")
        for observed, target in zip(stored, required):
            integer(observed, "storedPublishTimes")
            integer(target, "requiredPublishTimes")
            if observed < max(target, record["markTime"]):
                raise ValueError("Stored-feed coverage violation")
        if type(record.get("liveReadChecked")) is not bool:
            raise ValueError("Missing live-read evidence")
        if scenario == "historical_single" and (not record["liveReadChecked"] or not record["immediateRefundWei"]):
            raise ValueError("Historical single must prove an eligible live read and excess refund")
        if outcome != "pending" and (not record["markTime"] or not record["markPrice"]):
            raise ValueError("Missing synchronized mark")
        if scenario.startswith("unavailable_") and record["fundedWei"] < 2 * record["quoteWei"]:
            raise ValueError("Unavailable history must forward its full allocation")
        if scenario == "unavailable_immediate" and record["immediateRefundWei"] != record["fundedWei"]:
            raise ValueError("Unavailable immediate must refund all supplied ETH")
        if scenario == "unavailable_deferred" and (not record["oracleCreditedWei"] or not record["routerCreditedWei"]):
            raise ValueError("Unavailable deferred must exercise both refund ledgers")
        if manifest is not None:
            fixture_name = "historicalB" if scenario == "distinct_basket_batch" else (
                "fridayClosing" if scenario == "frozen_close" else "historicalA")
            fixture = manifest["fixtures"][fixture_name]["fixture"]
            expected_times = fixture["initialStoredPublishTimes"] if outcome == "pending" else fixture["publishTimes"]
            if required != expected_times:
                raise ValueError("Required coverage timestamps differ from the signed fixture")
            if outcome != "pending" and record["markTime"] != min(expected_times):
                raise ValueError("Installed mark timestamp differs from the signed fixture")
            if outcome == "pending" and stored != fixture["initialStoredPublishTimes"]:
                raise ValueError("Unavailable history unexpectedly changed Pyth storage")
            payloads = fixture["updateData"][:]
            if scenario == "distinct_basket_batch":
                payloads += manifest["fixtures"]["historicalA"]["fixture"]["updateData"]
            if record["payloadBytes"] != sum((len(value) - 2) // 2 for value in payloads):
                raise ValueError("Measured payload size differs from the exact signed payload")
    if seen != set(SCENARIOS):
        raise ValueError("Every mandatory real-Pyth scenario must appear exactly once")
    return records
