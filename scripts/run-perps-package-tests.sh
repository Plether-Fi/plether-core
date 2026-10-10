#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ] || ! [[ "$1" =~ ^[0-3]$ ]] || [ "$2" != 4 ]; then
    echo "usage: $0 <zero-based shard index 0..3> 4" >&2
    exit 2
fi
shard_index="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${repo_root}/packages/perps"
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-quick}"
export PERPS_ARTIFACT_DIR="${PERPS_ARTIFACT_DIR:-${repo_root}/artifacts/perps}"

if [ "${PERPS_SHARD_LIST_ONLY:-0}" = 1 ]; then
    python3 "${repo_root}/scripts/perps-test-inventory.py" --lane correctness --shard "${shard_index}" --format paths
    exit 0
fi

mkdir -p "${PERPS_ARTIFACT_DIR}"
python3 "${repo_root}/scripts/perps-test-inventory.py" > "${PERPS_ARTIFACT_DIR}/inventory.json"
# Stable source names keep compiled test/handler metadata identical on replay.
# mkdir atomically rejects a concurrent or interrupted run with the same identity.
scratch_id="$(python3 - "${FOUNDRY_PROFILE}" "${FOUNDRY_FUZZ_SEED:-0xdeadbeef}" "${shard_index}" "${FOUNDRY_VIA_IR:-true}" <<'PY'
import hashlib, json, sys
print(hashlib.sha256(json.dumps(sys.argv[1:]).encode()).hexdigest()[:20])
PY
)"
shard_work_dir="${package_root}/.package-test-shard.${scratch_id}"
if ! mkdir "${shard_work_dir}"; then
    echo "Shard scratch already exists (concurrent run or interrupted cleanup): ${shard_work_dir}" >&2
    exit 2
fi
cleanup() {
    if [[ "${shard_work_dir}" == "${package_root}"/.package-test-shard.* ]]; then
        rm -rf -- "${shard_work_dir}"
    fi
}
trap cleanup EXIT
printf '%s\n' "${shard_work_dir#"${package_root}/"}" > "${PERPS_ARTIFACT_DIR}/shard-${shard_index}-scratch.txt"
shard_test_dir="${shard_work_dir}/test"
cp -R "${package_root}/test" "${shard_test_dir}"
# Delete unselected entrypoints, preserving .sol fixtures at their original depth.
python3 "${repo_root}/scripts/perps-test-inventory.py" --format tsv > "${shard_work_dir}/assignments.tsv"
while IFS=$'\t' read -r assigned_shard relative_file; do
    if [ "${assigned_shard}" != "${shard_index}" ]; then
        rm -- "${shard_test_dir}/${relative_file}"
    fi
done < "${shard_work_dir}/assignments.tsv"
cp "${shard_work_dir}/assignments.tsv" "${PERPS_ARTIFACT_DIR}/assignments.tsv"
export PERPS_EXPECTED_ENTRYPOINTS="${PERPS_ARTIFACT_DIR}/shard-${shard_index}-entrypoints.txt"
awk -F '\t' -v shard="${shard_index}" '$1 == shard { print $2 }' "${shard_work_dir}/assignments.tsv" \
    > "${PERPS_EXPECTED_ENTRYPOINTS}"
export FOUNDRY_TEST="${shard_test_dir#"${package_root}/"}"
export PERPS_REPLAY_COMMAND="bash scripts/run-perps-package-tests.sh ${shard_index} 4"
# A single invocation saves the complete per-test result and invariant call statistics.
python3 "${repo_root}/scripts/run-perps-recorded.py" "shard-${shard_index}" -- \
    forge test --offline -vvv --root "${package_root}"
