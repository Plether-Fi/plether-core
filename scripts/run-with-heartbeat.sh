#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 2
fi

interval="${HEARTBEAT_INTERVAL_SECONDS:-60}"
start="${SECONDS}"

"$@" &
cmd_pid="$!"

forward_signal() {
    kill "${cmd_pid}" 2>/dev/null || true
    wait "${cmd_pid}" 2>/dev/null || true
}

trap forward_signal INT TERM

while kill -0 "${cmd_pid}" 2>/dev/null; do
    sleep "${interval}"
    if kill -0 "${cmd_pid}" 2>/dev/null; then
        elapsed="$((SECONDS - start))"
        echo "[heartbeat] command still running after ${elapsed}s: $*"
    fi
done

wait "${cmd_pid}"
