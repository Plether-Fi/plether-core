#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_root="${PERPS_ARTIFACT_DIR:-${repo_root}/artifacts/perps/pre-audit}"
failed=0
for seed in 0xdeadbeef 0x1 0x2; do
    for shard in 0 1 2 3; do
        if ! FOUNDRY_PROFILE=audit FOUNDRY_VIA_IR=true FOUNDRY_FUZZ_SEED="${seed}" \
            PERPS_ARTIFACT_DIR="${artifact_root}/${seed}" \
            bash "${repo_root}/scripts/run-perps-package-tests.sh" "${shard}" 4; then
            failed=1
        fi
    done
done
exit "${failed}"
