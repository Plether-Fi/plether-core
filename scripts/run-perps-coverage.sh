#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${repo_root}/packages/perps"
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-quick}"
export PERPS_ARTIFACT_DIR="${PERPS_ARTIFACT_DIR:-${repo_root}/artifacts/perps/coverage}"
coverage_exclusion_regex="$(python3 "${repo_root}/scripts/perps-test-inventory.py" --coverage-exclusion-regex)"
# A caller cannot silently replace the centrally reviewed exclusions.
for arg in "$@"; do
    case "${arg}" in
        --no-match-test*) echo "coverage exclusions are owned by perps-test-inventory.py" >&2; exit 2 ;;
    esac
done
if [ "${PERPS_COVERAGE_LIST_ONLY:-0}" = 1 ]; then
    python3 "${repo_root}/scripts/perps-test-inventory.py" --lane coverage --format paths
    exit 0
fi
mkdir -p "${PERPS_ARTIFACT_DIR}"
python3 "${repo_root}/scripts/perps-test-inventory.py" > "${PERPS_ARTIFACT_DIR}/inventory.json"
forge --version > "${PERPS_ARTIFACT_DIR}/toolchain.txt"
git -C "${repo_root}" rev-parse HEAD > "${PERPS_ARTIFACT_DIR}/commit.txt"
coverage_work_dir="$(mktemp -d "${package_root}/.coverage-perps.XXXXXX")"
shard_count="${PERPS_COVERAGE_SHARDS:-1}"

cleanup() {
    if [[ "${coverage_work_dir}" == "${package_root}"/.coverage-perps.* ]]; then
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
    local relative_file
    local test_index=0
    : > "${PERPS_ARTIFACT_DIR}/shard-${shard_index}-entrypoints.txt"
    mkdir -p "${test_dir}"
    cp -R "${package_root}/test/." "${test_dir}/"
    python3 "${repo_root}/scripts/perps-test-inventory.py" --lane coverage --format paths \
        > "${coverage_work_dir}/eligible.txt"
    # Remove every entrypoint first; copy back the exhaustive selected partition.
    find "${test_dir}" -type f -name '*.t.sol' -delete
    while IFS= read -r relative_file; do
        if [ "$((test_index % shard_count))" -eq "${shard_index}" ]; then
            cp "${package_root}/test/${relative_file}" "${test_dir}/${relative_file}"
            printf '%s\n' "${relative_file}" >> "${PERPS_ARTIFACT_DIR}/shard-${shard_index}-entrypoints.txt"
        fi
        test_index="$((test_index + 1))"
    done < "${coverage_work_dir}/eligible.txt"
}


coverage_args=()
config_args=()
report_file=""
lcov_report=false
input_args=("$@")
for ((arg_index = 0; arg_index < ${#input_args[@]}; arg_index++)); do
    arg="${input_args[arg_index]}"
    case "${arg}" in
        --remappings | -R | --remappings-env)
            config_args+=("${arg}")
            arg_index="$((arg_index + 1))"
            if [ "${arg_index}" -ge "${#input_args[@]}" ]; then
                echo "${arg} requires a value" >&2
                exit 2
            fi
            config_args+=("${input_args[arg_index]}")
            ;;
        --remappings=* | --remappings-env=*)
            config_args+=("${arg}")
            ;;
        --out | -o | --cache-path | --use | --evm-version | --optimizer-runs)
            config_args+=("${arg}")
            coverage_args+=("${arg}")
            arg_index="$((arg_index + 1))"
            if [ "${arg_index}" -ge "${#input_args[@]}" ]; then
                echo "${arg} requires a value" >&2
                exit 2
            fi
            config_args+=("${input_args[arg_index]}")
            coverage_args+=("${input_args[arg_index]}")
            ;;
        --out=* | --cache-path=* | --use=* | --evm-version=* | --optimizer-runs=*)
            config_args+=("${arg}")
            coverage_args+=("${arg}")
            ;;
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

# Solar's coverage analysis cannot resolve the package's ../shared and ../../lib
# remappings reliably. Normalize the effective targets for this invocation only.
python3 "${repo_root}/scripts/run-perps-recorded.py" --config-only \
    "${PERPS_ARTIFACT_DIR}/config.original.json" ${config_args[@]+"${config_args[@]}"}
python3 "${repo_root}/scripts/perps_coverage_config.py" \
    "${PERPS_ARTIFACT_DIR}/config.original.json" "${package_root}" > "${coverage_work_dir}/remappings.txt"
coverage_remappings=()
while IFS= read -r remapping; do
    coverage_remappings+=(--remappings "${remapping}")
done < "${coverage_work_dir}/remappings.txt"

record_coverage_settings() {
    local label="$1"
    shift
    python3 "${repo_root}/scripts/run-perps-recorded.py" --config-only \
        "${PERPS_ARTIFACT_DIR}/${label}-config.json" ${config_args[@]+"${config_args[@]}"} "${coverage_remappings[@]}"
    python3 - "${PERPS_ARTIFACT_DIR}/${label}-command.json" "$@" <<'PY_COMMAND'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    'command': sys.argv[2:],
    'coverage_instrumentation': 'Forge --ir-minimum transforms compiler optimization when requested; the companion config records configured paths, remappings, and profile.'
}, indent=2) + '\n')
PY_COMMAND
}

# Forge with a package --root emits package-relative SF paths. Normalize them
# before passing LCOV to repository-root filters and Codecov.
normalize_lcov() {
    python3 - "$1" "${package_root}" "${repo_root}" <<'PY_LCOV'
from pathlib import Path
import sys
report, package, repo = map(Path, sys.argv[1:])
lines = report.read_text().splitlines()
for index, line in enumerate(lines):
    if line.startswith('SF:'):
        path = Path(line[3:])
        if not path.is_absolute():
            path = (repo / path) if path.parts[:1] == ('packages',) else (package / path)
        try:
            lines[index] = 'SF:' + path.resolve().relative_to(repo).as_posix()
        except ValueError:
            pass
report.write_text('\n'.join(lines) + '\n')
PY_LCOV
}

if [ "${shard_count}" -eq 1 ]; then
    coverage_test_dir="${coverage_work_dir}/test"
    coverage_test_rel="${coverage_test_dir#"${package_root}/"}"
    populate_test_shard "${coverage_test_dir}" 0
    if [ -n "${report_file}" ]; then
        coverage_args+=(--report-file "${report_file}")
    fi
    FOUNDRY_TEST="${coverage_test_rel}" record_coverage_settings coverage \
        forge coverage --root "${package_root}" --no-match-test "${coverage_exclusion_regex}" \
        ${coverage_args[@]+"${coverage_args[@]}"} "${coverage_remappings[@]}"
    FOUNDRY_TEST="${coverage_test_rel}" \
        forge coverage --root "${package_root}" --no-match-test "${coverage_exclusion_regex}" \
        ${coverage_args[@]+"${coverage_args[@]}"} "${coverage_remappings[@]}" \
        2>&1 | tee "${PERPS_ARTIFACT_DIR}/coverage.log"
    if [ "${lcov_report}" = true ]; then
        normalize_lcov "${report_file:-${package_root}/lcov.info}"
    fi
    exit 0
fi

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
    coverage_test_rel="${coverage_test_dir#"${package_root}/"}"
    coverage_out_rel="${coverage_work_dir#"${package_root}/"}/shard-${shard_index}/out"
    coverage_cache_rel="${coverage_work_dir#"${package_root}/"}/shard-${shard_index}/cache"
    shard_report="${coverage_work_dir}/shard-${shard_index}.info"
    shard_reports+=("${shard_report}")
    populate_test_shard "${coverage_test_dir}" "${shard_index}"
    shard_test_count="$(find "${coverage_test_dir}" -type f -name '*.t.sol' | wc -l | tr -d ' ')"

    echo "Running perps coverage shard $((shard_index + 1))/${shard_count} (${shard_test_count} test files)"
    FOUNDRY_TEST="${coverage_test_rel}" FOUNDRY_OUT="${coverage_out_rel}" FOUNDRY_CACHE_PATH="${coverage_cache_rel}" \
        record_coverage_settings "shard-${shard_index}" \
        forge coverage --root "${package_root}" --no-match-test "${coverage_exclusion_regex}" \
        ${coverage_args[@]+"${coverage_args[@]}"} --report-file "${shard_report}" "${coverage_remappings[@]}"
    FOUNDRY_TEST="${coverage_test_rel}" \
        FOUNDRY_OUT="${coverage_out_rel}" \
        FOUNDRY_CACHE_PATH="${coverage_cache_rel}" \
        forge coverage --root "${package_root}" --no-match-test "${coverage_exclusion_regex}" \
        ${coverage_args[@]+"${coverage_args[@]}"} --report-file "${shard_report}" "${coverage_remappings[@]}" \
        2>&1 | tee "${PERPS_ARTIFACT_DIR}/shard-${shard_index}.log"
    normalize_lcov "${shard_report}"
done

merge_args=()
for shard_report in "${shard_reports[@]}"; do
    merge_args+=(--add-tracefile "${shard_report}")
done
lcov --branch-coverage --no-checksum --ignore-errors inconsistent,corrupt \
    "${merge_args[@]}" --output-file "${report_file}"
