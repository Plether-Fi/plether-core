#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <zero-based shard index> <shard count>" >&2
    exit 2
fi

shard_index="$1"
shard_count="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${repo_root}/packages/perps"
shard_work_dir="$(mktemp -d "${package_root}/.package-test-shard.XXXXXX")"
shard_test_dir="${shard_work_dir}/test"

cleanup() {
    if [[ "${shard_work_dir}" == "${package_root}"/.package-test-shard.* ]]; then
        rm -rf -- "${shard_work_dir}"
    fi
}
trap cleanup EXIT

if ! [[ "${shard_index}" =~ ^[0-9]+$ && "${shard_count}" =~ ^[1-9][0-9]*$ ]]; then
    echo "shard index must be non-negative and shard count must be positive" >&2
    exit 2
fi
if [ "${shard_index}" -ge "${shard_count}" ]; then
    echo "shard index must be smaller than shard count" >&2
    exit 2
fi

while IFS= read -r source_file; do
    if grep -Eq '^[[:space:]]*import[^;]*\.t\.sol' "${source_file}"; then
        echo "physical perps test sharding does not support imports of .t.sol entrypoints: ${source_file}" >&2
        exit 2
    fi
done < <(find "${package_root}/test" -type f -name '*.sol')

cp -R "${package_root}/test/." "${shard_test_dir}/"

test_index=0
while IFS= read -r source_file; do
    relative_file="${source_file#"${package_root}/test/"}"
    if [ "$((test_index % shard_count))" -ne "${shard_index}" ]; then
        rm -- "${shard_test_dir}/${relative_file}"
    fi
    test_index="$((test_index + 1))"
done < <(find "${package_root}/test" -type f -name '*.t.sol' | LC_ALL=C sort)

shard_test_count="$(find "${shard_test_dir}" -type f -name '*.t.sol' | wc -l | tr -d ' ')"
if [ "${shard_test_count}" -eq 0 ]; then
    echo "perps package shard contains no test files" >&2
    exit 2
fi

shard_test_rel="${shard_test_dir#"${package_root}/"}"
echo "Running perps package shard $((shard_index + 1))/${shard_count} (${shard_test_count} test files)"

FOUNDRY_TEST="${shard_test_rel}" \
    forge test --offline -vvv --root "${package_root}" --match-test 'testFuzz_|invariant_'
FOUNDRY_TEST="${shard_test_rel}" \
    forge test --offline --root "${package_root}" --no-match-test 'testFuzz_|invariant_'
