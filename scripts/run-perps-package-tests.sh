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
entrypoint_file="${shard_work_dir}/entrypoints.txt"
assignment_file="${shard_work_dir}/assignments.tsv"

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
if [ "${shard_count}" -ne 4 ]; then
    echo "perps package tests require exactly 4 shards" >&2
    exit 2
fi

: > "${entrypoint_file}"
: > "${assignment_file}"

while IFS= read -r source_file; do
    if awk '
        /^[[:space:]]*import([[:space:]]|["{*])/ { in_import = 1 }
        in_import && /\.t\.sol/ { imports_test = 1 }
        in_import && /;/ { in_import = 0 }
        END { exit(imports_test ? 0 : 1) }
    ' "${source_file}"; then
        echo "physical perps test sharding does not support imports of .t.sol entrypoints: ${source_file}" >&2
        exit 2
    fi
done < <(find "${package_root}/test" -type f -name '*.sol')

fallback_index=0
while IFS= read -r source_file; do
    relative_file="${source_file#"${package_root}/test/"}"
    case "${relative_file}" in
        perps/invariant/PerpAccountingInvariant.t.sol)
            assigned_shard=0
            ;;
        perps/PerpInvariant.t.sol)
            assigned_shard=1
            ;;
        perps/invariant/PerpEconomicConservationInvariant.t.sol | perps/invariant/PerpValueConservationInvariant.t.sol)
            assigned_shard=2
            ;;
        perps/invariant/PerpPreviewInvariant.t.sol | perps/invariant/PerpClosePreviewParityInvariant.t.sol | perps/invariant/PerpMultiAccountInvariant.t.sol | perps/invariant/PerpHousePoolLifecycleInvariant.t.sol)
            assigned_shard=3
            ;;
        *)
            assigned_shard="$((fallback_index % shard_count))"
            fallback_index="$((fallback_index + 1))"
            ;;
    esac

    if ! [[ "${assigned_shard}" =~ ^[0-9]+$ ]] || [ "${assigned_shard}" -ge "${shard_count}" ]; then
        echo "invalid shard assignment for perps test entrypoint: ${relative_file}" >&2
        exit 2
    fi

    printf '%s\n' "${relative_file}" >> "${entrypoint_file}"
    printf '%s\t%s\n' "${assigned_shard}" "${relative_file}" >> "${assignment_file}"
done < <(find "${package_root}/test" -type f -name '*.t.sol' | LC_ALL=C sort)

test_count="$(wc -l < "${entrypoint_file}" | tr -d ' ')"
if [ "${test_count}" -eq 0 ]; then
    echo "perps package contains no test entrypoints" >&2
    exit 2
fi

assignment_count="$(wc -l < "${assignment_file}" | tr -d ' ')"
if [ "${assignment_count}" -ne "${test_count}" ]; then
    echo "every perps test entrypoint must have exactly one shard assignment" >&2
    exit 2
fi

duplicate_entrypoint="$(cut -f2 "${assignment_file}" | LC_ALL=C sort | uniq -d | head -n 1)"
if [ -n "${duplicate_entrypoint}" ]; then
    echo "duplicate perps test shard assignment: ${duplicate_entrypoint}" >&2
    exit 2
fi

assignment_difference="$(comm -3 "${entrypoint_file}" <(cut -f2 "${assignment_file}" | LC_ALL=C sort) | head -n 1)"
if [ -n "${assignment_difference}" ]; then
    echo "perps test shard assignments do not cover every entrypoint exactly once: ${assignment_difference}" >&2
    exit 2
fi

for pinned_entrypoint in \
    perps/invariant/PerpAccountingInvariant.t.sol \
    perps/PerpInvariant.t.sol \
    perps/invariant/PerpEconomicConservationInvariant.t.sol \
    perps/invariant/PerpValueConservationInvariant.t.sol \
    perps/invariant/PerpPreviewInvariant.t.sol \
    perps/invariant/PerpClosePreviewParityInvariant.t.sol \
    perps/invariant/PerpMultiAccountInvariant.t.sol \
    perps/invariant/PerpHousePoolLifecycleInvariant.t.sol; do
    if ! grep -Fxq "${pinned_entrypoint}" "${entrypoint_file}"; then
        echo "required pinned perps test entrypoint is missing: ${pinned_entrypoint}" >&2
        exit 2
    fi
done

validation_shard=0
while [ "${validation_shard}" -lt "${shard_count}" ]; do
    validation_count="$(awk -F '\t' -v shard="${validation_shard}" '$1 == shard { count++ } END { print count + 0 }' "${assignment_file}")"
    if [ "${validation_count}" -eq 0 ]; then
        echo "perps package shard $((validation_shard + 1))/${shard_count} contains no test files" >&2
        exit 2
    fi
    validation_shard="$((validation_shard + 1))"
done

shard_test_count="$(awk -F '\t' -v shard="${shard_index}" '$1 == shard { count++ } END { print count + 0 }' "${assignment_file}")"
if [ "${shard_test_count}" -eq 0 ]; then
    echo "perps package shard contains no test files" >&2
    exit 2
fi

if [ "${PERPS_SHARD_LIST_ONLY:-0}" = 1 ]; then
    awk -F '\t' -v shard="${shard_index}" '$1 == shard { print $2 }' "${assignment_file}"
    exit 0
fi

cp -R "${package_root}/test/." "${shard_test_dir}/"
while IFS=$'\t' read -r assigned_shard relative_file; do
    if [ "${assigned_shard}" -ne "${shard_index}" ]; then
        rm -- "${shard_test_dir}/${relative_file}"
    fi
done < "${assignment_file}"

shard_test_rel="${shard_test_dir#"${package_root}/"}"
echo "Running perps package shard $((shard_index + 1))/${shard_count} (${shard_test_count} test files)"

FOUNDRY_TEST="${shard_test_rel}" \
    forge test --offline -vvv --root "${package_root}" --match-test 'testFuzz_|invariant_'
FOUNDRY_TEST="${shard_test_rel}" \
    forge test --offline --root "${package_root}" --no-match-test 'testFuzz_|invariant_'
