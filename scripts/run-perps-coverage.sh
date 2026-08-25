#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
coverage_work_dir="$(mktemp -d "${repo_root}/.coverage-perps.XXXXXX")"
shard_count="${PERPS_COVERAGE_SHARDS:-1}"

cleanup() {
    if [[ "${coverage_work_dir}" == "${repo_root}"/.coverage-perps.* ]]; then
        rm -rf -- "${coverage_work_dir}"
    fi
}
trap cleanup EXIT

if ! [[ "${shard_count}" =~ ^[1-9][0-9]*$ ]]; then
    echo "PERPS_COVERAGE_SHARDS must be a positive integer" >&2
    exit 2
fi

populate_test_shard() {
    local test_dir="$1"
    local shard_index="$2"
    local source_file
    local relative_file
    local test_index=0

    mkdir -p "${test_dir}"
    cp -R "${repo_root}/packages/perps/test/." "${test_dir}/"
    rm -rf -- "${test_dir}/perps/invariant"

    if [ "${shard_count}" -eq 1 ]; then
        return
    fi

    while IFS= read -r source_file; do
        relative_file="${source_file#"${repo_root}/packages/perps/test/"}"
        if [ "$((test_index % shard_count))" -ne "${shard_index}" ]; then
            rm -- "${test_dir}/${relative_file}"
        fi
        test_index="$((test_index + 1))"
    done < <(find "${repo_root}/packages/perps/test" -type f -name '*.t.sol' \
        ! -path '*/invariant/*' | LC_ALL=C sort)
}

if [ "${shard_count}" -eq 1 ]; then
    coverage_test_dir="${coverage_work_dir}/test"
    coverage_test_rel="${coverage_test_dir#"${repo_root}/"}"
    populate_test_shard "${coverage_test_dir}" 0

    cd "${repo_root}"
    FOUNDRY_SRC=packages/perps/src \
        FOUNDRY_TEST="${coverage_test_rel}" \
        FOUNDRY_SCRIPT=integration/src \
        forge coverage "$@"
    exit
fi

coverage_args=()
report_file=""
lcov_report=false
input_args=("$@")
for ((arg_index = 0; arg_index < ${#input_args[@]}; arg_index++)); do
    arg="${input_args[arg_index]}"
    case "${arg}" in
        --report-file | -r)
            arg_index="$((arg_index + 1))"
            if [ "${arg_index}" -ge "${#input_args[@]}" ]; then
                echo "${arg} requires a path" >&2
                exit 2
            fi
            report_file="${input_args[arg_index]}"
            ;;
        --report-file=*)
            report_file="${arg#--report-file=}"
            ;;
        --report)
            coverage_args+=("${arg}")
            arg_index="$((arg_index + 1))"
            if [ "${arg_index}" -ge "${#input_args[@]}" ]; then
                echo "--report requires a report type" >&2
                exit 2
            fi
            report_type="${input_args[arg_index]}"
            coverage_args+=("${report_type}")
            if [ "${report_type}" = "lcov" ]; then
                lcov_report=true
            fi
            ;;
        --report=lcov)
            coverage_args+=("${arg}")
            lcov_report=true
            ;;
        *)
            coverage_args+=("${arg}")
            ;;
    esac
done

if [ -z "${report_file}" ] || [ "${lcov_report}" != true ]; then
    echo "sharded perps coverage requires --report lcov and --report-file" >&2
    exit 2
fi
if ! command -v lcov >/dev/null 2>&1; then
    echo "sharded perps coverage requires lcov to merge shard reports" >&2
    exit 2
fi

shard_reports=()
for ((shard_index = 0; shard_index < shard_count; shard_index++)); do
    coverage_test_dir="${coverage_work_dir}/shard-${shard_index}/test"
    coverage_test_rel="${coverage_test_dir#"${repo_root}/"}"
    coverage_out_rel="${coverage_work_dir#"${repo_root}/"}/shard-${shard_index}/out"
    coverage_cache_rel="${coverage_work_dir#"${repo_root}/"}/shard-${shard_index}/cache"
    shard_report="${coverage_work_dir}/shard-${shard_index}.info"
    shard_reports+=("${shard_report}")
    populate_test_shard "${coverage_test_dir}" "${shard_index}"
    shard_test_count="$(find "${coverage_test_dir}" -type f -name '*.t.sol' | wc -l | tr -d ' ')"

    echo "Running perps coverage shard $((shard_index + 1))/${shard_count} (${shard_test_count} test files)"
    cd "${repo_root}"
    FOUNDRY_SRC=packages/perps/src \
        FOUNDRY_TEST="${coverage_test_rel}" \
        FOUNDRY_SCRIPT=integration/src \
        FOUNDRY_OUT="${coverage_out_rel}" \
        FOUNDRY_CACHE_PATH="${coverage_cache_rel}" \
        forge coverage "${coverage_args[@]}" --report-file "${shard_report}"
done

merge_args=()
for shard_report in "${shard_reports[@]}"; do
    merge_args+=(--add-tracefile "${shard_report}")
done
lcov --branch-coverage --no-checksum "${merge_args[@]}" --output-file "${report_file}"
