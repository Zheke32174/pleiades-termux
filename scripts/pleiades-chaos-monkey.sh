#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# ==============================================================================
# pleiades-chaos-monkey.sh — Defensive resilience test harness
#
# Public-release safe behavior:
#   - default mode is dry-run / event-only
#   - active stress behavior requires explicit lab consent
#   - no network partition, service kill, or destructive host action is performed
#     by this public-safe Termux variant
#
# Active mode requires:
#   PLEIADES_LAB_MODE=1 PLEIADES_I_UNDERSTAND_LOCAL_TESTS=1 \
#     pleiades-chaos-monkey.sh --run-active --test=<name>
# ==============================================================================

set -euo pipefail

RUN_ACTIVE=false
TEST_NAME=""
TEST_LOG="${PLEIADES_LOG_DIR:-${PREFIX:-/data/data/com.termux/files/usr}/var/pleiades/log}/chaos-test.log"
FIFO="${PLEIADES_FIFO:-${PLEIADES_RUN_DIR:-${TMPDIR:-/tmp}/pleiades/run}/pleiades-nexus_fifo}"

mkdir -p "$(dirname "$TEST_LOG")" "$(dirname "$FIFO")"

log()   { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$TEST_LOG"; }
event() { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }

require_lab_mode() {
    if [[ "${PLEIADES_LAB_MODE:-0}" != "1" || "${PLEIADES_I_UNDERSTAND_LOCAL_TESTS:-0}" != "1" ]]; then
        cat >&2 <<'ERR'
Refusing active chaos test.
Set BOTH variables only in an owned/authorized lab:
  export PLEIADES_LAB_MODE=1
  export PLEIADES_I_UNDERSTAND_LOCAL_TESTS=1
Then rerun with --run-active.
ERR
        exit 2
    fi
}

list_tests() {
    cat <<'LIST'
Available resilience tests:
  fifo_resilience    Dry-run event; active mode writes 25 local FIFO events
  log_flood          Dry-run event; active mode writes 25 local logger messages
  memory_pressure    Dry-run event; active mode allocates a temporary 8MiB buffer
  fork_burst         Dry-run event; active mode creates 10 short-lived child processes
  dependency_chain   Read-only service status check where available

Removed from the public-safe Termux variant:
  service_kill, iptables/network_partition, host mount mutation, root-only tests
LIST
}

dry_test() {
    local name="$1"
    log "DRY-RUN resilience test: $name"
    event "CHAOS_TEST_DRY_RUN|name=${name}|ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "dry_run=1 test=$name"
}

active_test() {
    local name="$1"
    require_lab_mode
    log "ACTIVE LAB resilience test: $name"
    case "$name" in
        fifo_resilience)
            for i in $(seq 1 25); do event "CHAOS_TEST_ACTIVE|name=fifo_resilience|seq=$i"; done
            ;;
        log_flood)
            for i in $(seq 1 25); do logger -t pleiades-chaos-test "sequence=$i" 2>/dev/null || true; done
            event "CHAOS_TEST_ACTIVE|name=log_flood|messages=25"
            ;;
        memory_pressure)
            python3 - <<'PY' 2>/dev/null || true
buf = bytearray(8 * 1024 * 1024)
PY
            event "CHAOS_TEST_ACTIVE|name=memory_pressure|size=8MiB"
            ;;
        fork_burst)
            for _ in $(seq 1 10); do (sleep 1) & done
            wait 2>/dev/null || true
            event "CHAOS_TEST_ACTIVE|name=fork_burst|children=10"
            ;;
        dependency_chain)
            for svc in pleiades-nexus-omniversal.service pleiades-forensic-scanner.service atlas-omniversal.service; do
                state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
                log "dependency_chain: $svc=$state"
            done
            ;;
        *)
            echo "Unknown test: $name" >&2
            list_tests
            exit 1
            ;;
    esac
    echo "active_lab_run=1 test=$name"
}

run_all() {
    local tests=(fifo_resilience log_flood memory_pressure fork_burst dependency_chain)
    for t in "${tests[@]}"; do
        if $RUN_ACTIVE; then active_test "$t"; else dry_test "$t"; fi
    done
}

for arg in "$@"; do
    case "$arg" in
        --run-active) RUN_ACTIVE=true ;;
        --dry-run|--gentle) RUN_ACTIVE=false ;;
        --test=*) TEST_NAME="${arg#--test=}" ;;
        --all|-a) TEST_NAME="__all__" ;;
        --list|-l|--help|-h) list_tests; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; list_tests; exit 1 ;;
    esac
done

[[ -n "$TEST_NAME" ]] || { list_tests; exit 0; }

if [[ "$TEST_NAME" == "__all__" ]]; then
    run_all
elif $RUN_ACTIVE; then
    active_test "$TEST_NAME"
else
    dry_test "$TEST_NAME"
fi
