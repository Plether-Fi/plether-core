#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 2
fi

interval="${HEARTBEAT_INTERVAL_SECONDS:-60}"
start="${SECONDS}"

# Opt-in diagnostics stay in the job log even if the runner disappears before
# artifacts can be uploaded. Never change the wrapped command's exit status.
report_resources() {
    [ "${HEARTBEAT_RESOURCE_DIAGNOSTICS:-0}" = 1 ] || return 0
    echo "[resources] $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [ -r /proc/meminfo ]; then
        awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/' /proc/meminfo
    fi
    df -h . 2>/dev/null || true
    for file in /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max \
        /sys/fs/cgroup/memory.events /proc/pressure/memory; do
        if [ -r "${file}" ]; then
            echo "[resources] ${file}"
            cat "${file}" || true
        fi
    done
    # Linux hosted runners: command names only, avoiding arguments or secrets.
    ps -eo pid,ppid,pcpu,rss,comm --sort=-rss 2>/dev/null | head -n 9 || true
    return 0
}
report_resources

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
        report_resources
    fi
done &
heartbeat_pid="$!"

wait "${cmd_pid}"
status="$?"

kill "${heartbeat_pid}" 2>/dev/null || true
wait "${heartbeat_pid}" 2>/dev/null || true
report_resources
exit "${status}"
