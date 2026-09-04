#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${repo_root}/packages/perps"
deployment_size_regex='RuntimeFitsEip170|FitsEip3860|FitDeploymentLimits|test_Runtime_'
production_test_regex='GasBudget|test_Gas_'
fuzz_invariant_regex='testFuzz_|invariant_'
regular_exclusion_regex="${deployment_size_regex}|${production_test_regex}|${fuzz_invariant_regex}"

echo "Running production-codegen gas and runtime gates with via-IR"
FOUNDRY_PROFILE=ci \
    forge test --offline -vvv --root "${package_root}" --match-test "${production_test_regex}"

echo "Running regular perps tests without via-IR"
FOUNDRY_PROFILE=ci \
    FOUNDRY_VIA_IR=false \
    FOUNDRY_OUT=out-ci-fast \
    FOUNDRY_CACHE_PATH=cache-ci-fast \
    forge test --offline --root "${package_root}" --no-match-test "${regular_exclusion_regex}"

echo "Running deterministic perps fuzz and invariant smoke tests without via-IR"
FOUNDRY_PROFILE=ci \
    FOUNDRY_VIA_IR=false \
    FOUNDRY_OUT=out-ci-fast \
    FOUNDRY_CACHE_PATH=cache-ci-fast \
    FOUNDRY_FUZZ_SEED=0xdeadbeef \
    FOUNDRY_FUZZ_RUNS=4 \
    FOUNDRY_INVARIANT_RUNS=4 \
    FOUNDRY_INVARIANT_DEPTH=128 \
    forge test --offline -vvv --root "${package_root}" \
        --match-test "${fuzz_invariant_regex}" \
        --no-match-test "${deployment_size_regex}|${production_test_regex}"
