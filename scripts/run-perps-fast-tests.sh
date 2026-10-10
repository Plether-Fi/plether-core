#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${repo_root}/packages/perps"
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-quick}"
export PERPS_ARTIFACT_DIR="${PERPS_ARTIFACT_DIR:-${repo_root}/artifacts/perps}"
export PERPS_REPLAY_COMMAND="${PERPS_REPLAY_COMMAND:-bash scripts/run-perps-fast-tests.sh}"
# Code generation differs between lanes; profile fuzz/invariant budgets do not.
production_regex="$(python3 "${repo_root}/scripts/perps-test-inventory.py" --production-test-regex)"
fork_path='**/fork/**'
mkdir -p "${PERPS_ARTIFACT_DIR}"
python3 "${repo_root}/scripts/perps-test-inventory.py" > "${PERPS_ARTIFACT_DIR}/inventory.json"

# Capture the unfiltered discovery universe before partitioning by codegen.
# Shard callers supply expected source entrypoints; validate them across both lanes.
expected_entrypoints="${PERPS_EXPECTED_ENTRYPOINTS:-}"
unset PERPS_EXPECTED_ENTRYPOINTS
FOUNDRY_VIA_IR=true forge test --offline --threads 1 --root "${package_root}" \
    --no-match-path "${fork_path}" --list --json > "${PERPS_ARTIFACT_DIR}/all-tests.json"

FOUNDRY_VIA_IR=true \
    python3 "${repo_root}/scripts/run-perps-recorded.py" production-gates -- \
    forge test --offline --threads 1 -vvv --root "${package_root}" --no-match-path "${fork_path}" \
    --match-test "${production_regex}"

FOUNDRY_VIA_IR=false FOUNDRY_OUT=out-ci-fast FOUNDRY_CACHE_PATH=cache-ci-fast \
    python3 "${repo_root}/scripts/run-perps-recorded.py" correctness -- \
    forge test --offline --threads 1 -vvv --root "${package_root}" --no-match-path "${fork_path}" \
    --no-match-test "${production_regex}"

python3 "${repo_root}/scripts/check-perps-pr-selection.py" \
    "${PERPS_ARTIFACT_DIR}" "${package_root}" "${expected_entrypoints}"
