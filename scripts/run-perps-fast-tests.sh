#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${repo_root}/packages/perps"
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-quick}"
export PERPS_ARTIFACT_DIR="${PERPS_ARTIFACT_DIR:-${repo_root}/artifacts/perps}"
export PERPS_REPLAY_COMMAND="${PERPS_REPLAY_COMMAND:-bash scripts/run-perps-fast-tests.sh}"
batch_size="${PERPS_COMPILE_BATCH_SIZE:-4}"
if ! [[ "${batch_size}" =~ ^[1-9][0-9]*$ ]]; then
    echo "PERPS_COMPILE_BATCH_SIZE must be a positive integer" >&2
    exit 2
fi
export PERPS_REPLAY_COMMAND="PERPS_COMPILE_BATCH_SIZE=${batch_size} ${PERPS_REPLAY_COMMAND}"
mkdir -p "${PERPS_ARTIFACT_DIR}"

# PR callers already own a physical shard. Local make targets need the same
# bounded path, rather than an initial compile of the entire package for discovery.
if [ -z "${PERPS_EXPECTED_ENTRYPOINTS:-}" ]; then
    if [ -n "${FOUNDRY_TEST:-}" ] && [ "${FOUNDRY_TEST}" != test ]; then
        echo "Custom FOUNDRY_TEST requires PERPS_EXPECTED_ENTRYPOINTS" >&2
        exit 2
    fi
    scratch_id="$(python3 - "${FOUNDRY_PROFILE}" "${FOUNDRY_FUZZ_SEED:-0xdeadbeef}" "${batch_size}" <<'PY'
import hashlib, json, sys
print(hashlib.sha256(json.dumps(['fast-local', *sys.argv[1:]]).encode()).hexdigest()[:20])
PY
)"
    scratch="${package_root}/.package-test-shard.${scratch_id}"
    if ! mkdir "${scratch}"; then
        echo "Fast test scratch already exists (concurrent run or interrupted cleanup): ${scratch}" >&2
        exit 2
    fi
    cleanup() { rm -rf -- "${scratch}"; }
    trap cleanup EXIT
    cp -R "${package_root}/test" "${scratch}/test"
    export PERPS_EXPECTED_ENTRYPOINTS="${PERPS_ARTIFACT_DIR}/fast-entrypoints.txt"
    python3 "${repo_root}/scripts/perps-test-inventory.py" --lane correctness --format paths \
        > "${PERPS_EXPECTED_ENTRYPOINTS}"
    # Shared .sol fixtures retain their relative paths; only non-fork entrypoints remain.
    find "${scratch}/test" -type f -name '*.t.sol' -delete
    while IFS= read -r source; do
        cp "${package_root}/test/${source}" "${scratch}/test/${source}"
    done < "${PERPS_EXPECTED_ENTRYPOINTS}"
    export FOUNDRY_TEST="${scratch#"${package_root}/"}/test"
fi
python3 "${repo_root}/scripts/run-perps-batched.py" fast "${batch_size}" --fast
