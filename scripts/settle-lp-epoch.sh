#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
keeper=(forge script script/LpEpochKeeper.s.sol --tc LpEpochKeeper)

# A failed or stalled order pass must not make settlement depend on order progress.
if ! "${keeper[@]}" --sig 'processOrders()' "$@"; then
    echo 'Order pass failed. Checking LP settlement independently.' >&2
fi

exec "${keeper[@]}" "$@"
