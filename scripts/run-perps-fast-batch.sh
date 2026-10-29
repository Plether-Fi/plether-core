#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${repo_root}/packages/perps"
if [ -z "${FOUNDRY_TEST:-}" ] || [ -z "${PERPS_EXPECTED_ENTRYPOINTS:-}" ]; then
    echo "run-perps-fast-batch.sh requires a physical batch and its expected entrypoints" >&2
    exit 2
fi
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-quick}"
export PERPS_ARTIFACT_DIR="${PERPS_ARTIFACT_DIR:-${repo_root}/artifacts/perps}"
export PERPS_REPLAY_COMMAND="${PERPS_REPLAY_COMMAND:-bash scripts/run-perps-fast-tests.sh}"
# Code generation differs between lanes; profile fuzz/invariant budgets do not.
production_regex="$(python3 "${repo_root}/scripts/perps-test-inventory.py" --production-test-regex)"
fork_path='**/fork/**'
mkdir -p "${PERPS_ARTIFACT_DIR}"
python3 - "${PERPS_ARTIFACT_DIR}" <<'PY'
from pathlib import Path
import sys
directory = Path(sys.argv[1])
for name in ('run.json', 'pr-selection.json', 'production-gates/run.json', 'correctness/run.json'):
    (directory / name).unlink(missing_ok=True)
PY
python3 "${repo_root}/scripts/perps-test-inventory.py" > "${PERPS_ARTIFACT_DIR}/inventory.json"

# Capture the unfiltered discovery universe before partitioning by codegen.
# Shard callers supply expected source entrypoints; validate them across both lanes.
expected_entrypoints="${PERPS_EXPECTED_ENTRYPOINTS:-}"
unset PERPS_EXPECTED_ENTRYPOINTS
discovery_started=$SECONDS
FOUNDRY_VIA_IR=false FOUNDRY_OUT=out-ci-fast FOUNDRY_CACHE_PATH=cache-ci-fast \
    forge test --offline --threads 1 --root "${package_root}" \
    --skip script --no-match-path "${fork_path}" --list --json > "${PERPS_ARTIFACT_DIR}/all-tests.json"
echo "[fast] batch discovery completed in $((SECONDS - discovery_started))s"

# Function filters do not bound compiler memory. Exclude entrypoints without
# production tests from via-IR compilation, using actual discovery (including
# inherited tests), not source-text guesses. Shared .sol helpers remain available.
python3 - "${PERPS_ARTIFACT_DIR}/all-tests.json" "${production_regex}" \
    "${package_root}" "${FOUNDRY_TEST:-test}" > "${PERPS_ARTIFACT_DIR}/production-skip-files.txt" <<'PY'
import json, re, sys
from pathlib import Path
discovered = json.loads(Path(sys.argv[1]).read_text())
pattern = re.compile(sys.argv[2])
for lane, keep in [('production-gates', True), ('correctness', False)]:
    selected = {source: {contract: [name for name in names if bool(pattern.search(name)) == keep]
                         for contract, names in contracts.items()}
                for source, contracts in discovered.items()}
    Path(sys.argv[1]).with_name(lane + '-discovery.json').write_text(json.dumps(selected) + '\n')
required_names = {Path(source).name for source, contracts in discovered.items()
                  if any(pattern.search(name) for names in contracts.values() for name in names)}
test_root = Path(sys.argv[4])
if not test_root.is_absolute():
    test_root = Path(sys.argv[3]) / test_root
# Forge's --skip matches filename substrings. Retain collisions so ambiguous
# names can only cause extra compilation, never omission.
for name in sorted({p.name for p in test_root.rglob('*.t.sol')}):
    if not any(name in required for required in required_names):
        print(name)
PY
production_skip=(--skip script)
while IFS= read -r source; do
    production_skip+=(--skip "${source}")
done < "${PERPS_ARTIFACT_DIR}/production-skip-files.txt"

FOUNDRY_VIA_IR=true \
    python3 "${repo_root}/scripts/run-perps-recorded.py" --allow-empty-partition --trace-failures \
    --discovery-file "${PERPS_ARTIFACT_DIR}/production-gates-discovery.json" production-gates -- \
    forge test --offline --threads 1 --root "${package_root}" --no-match-path "${fork_path}" \
    --match-test "${production_regex}" "${production_skip[@]}"

FOUNDRY_VIA_IR=false FOUNDRY_OUT=out-ci-fast FOUNDRY_CACHE_PATH=cache-ci-fast \
    python3 "${repo_root}/scripts/run-perps-recorded.py" --allow-empty-partition --trace-failures \
    --discovery-file "${PERPS_ARTIFACT_DIR}/correctness-discovery.json" correctness -- \
    forge test --offline --threads 1 --skip script --root "${package_root}" --no-match-path "${fork_path}" \
    --no-match-test "${production_regex}"

python3 "${repo_root}/scripts/check-perps-pr-selection.py" \
    "${PERPS_ARTIFACT_DIR}" "${package_root}" "${expected_entrypoints}"
