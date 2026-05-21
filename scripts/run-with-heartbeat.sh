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

heartbeat_pid=""

forward_signal() {
    kill "${cmd_pid}" 2>/dev/null || true
    if [ -n "${heartbeat_pid}" ]; then
        kill "${heartbeat_pid}" 2>/dev/null || true
    fi
    wait "${cmd_pid}" 2>/dev/null || true
    if [ -n "${heartbeat_pid}" ]; then
        wait "${heartbeat_pid}" 2>/dev/null || true
    fi
}

trap forward_signal INT TERM

while kill -0 "${cmd_pid}" 2>/dev/null; do
    sleep "${interval}"
    if kill -0 "${cmd_pid}" 2>/dev/null; then
        elapsed="$((SECONDS - start))"
        echo "[heartbeat] command still running after ${elapsed}s: $*"
    fi
done &
heartbeat_pid="$!"

wait "${cmd_pid}"
status="$?"

kill "${heartbeat_pid}" 2>/dev/null || true
wait "${heartbeat_pid}" 2>/dev/null || true
exit "${status}"
