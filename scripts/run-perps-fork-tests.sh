#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PERPS_REQUIRE_NO_SKIPS=1
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ci}"
export PERPS_ARTIFACT_DIR="${PERPS_ARTIFACT_DIR:-${repo_root}/artifacts/perps/fork}"
export PERPS_REPLAY_COMMAND='bash scripts/run-perps-fork-tests.sh'
mkdir -p "${PERPS_ARTIFACT_DIR}"
printf 'entrypoint\tstatus\tconfiguration\n' > "${PERPS_ARTIFACT_DIR}/configuration.tsv"
configured=0
while IFS= read -r path; do
    case "${path##*/}" in
        CfdSponsoredCloseFork.t.sol) variable=SPONSORED_CLOSE_FORK_RPC_URL ;;
        HistoricalCloseRegression.t.sol) variable=CLOSE_REGRESSION_ARCHIVE_RPC_URL ;;
        *) echo "Unclassified fork prerequisite: ${path}" >&2; exit 2 ;;
    esac
    if [ -z "${!variable:-}" ]; then
        printf '%s\tnot_run\t%s not configured\n' "${path}" "${variable}" >> "${PERPS_ARTIFACT_DIR}/configuration.tsv"
        continue
    fi
    configured="$((configured + 1))"
    printf '%s\tconfigured\t%s\n' "${path}" "${variable}" >> "${PERPS_ARTIFACT_DIR}/configuration.tsv"
    python3 "${repo_root}/scripts/run-perps-recorded.py" "${path##*/}" -- \
        forge test --offline -vvv --root "${repo_root}/packages/perps" --match-path "test/${path}"
done < <(python3 "${repo_root}/scripts/perps-test-inventory.py" --lane fork --format paths)
if [ "${configured}" -eq 0 ]; then
    echo 'Fork coverage NOT RUN: configure an RPC URL listed in configuration.tsv.' >&2
    exit 2
fi
