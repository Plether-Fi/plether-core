#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
coverage_test_dir="$(mktemp -d "${repo_root}/.coverage-perps.XXXXXX")"
coverage_test_rel="${coverage_test_dir#"${repo_root}/"}"

cleanup() {
    if [[ "${coverage_test_dir}" == "${repo_root}"/.coverage-perps.* ]]; then
        rm -rf -- "${coverage_test_dir}"
    fi
}
trap cleanup EXIT

cp -R "${repo_root}/packages/perps/test/." "${coverage_test_dir}/"
rm -rf -- "${coverage_test_dir}/perps/invariant"

cd "${repo_root}"
FOUNDRY_SRC=packages/perps/src \
    FOUNDRY_TEST="${coverage_test_rel}" \
    FOUNDRY_SCRIPT=integration/src \
    forge coverage "$@"
