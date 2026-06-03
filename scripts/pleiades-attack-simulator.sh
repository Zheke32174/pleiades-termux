#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# ==============================================================================
# pleiades-attack-simulator.sh — Defensive detection simulator
#
# Public-release safe behavior:
#   - default mode is dry-run / event-only
#   - no listener, scan, network change, memory pressure, or process stress runs
#     unless BOTH explicit CLI and environment consent are present
#   - intended only for systems you own or are explicitly authorized to test
#
# Active mode requires:
#   PLEIADES_LAB_MODE=1 PLEIADES_I_UNDERSTAND_LOCAL_TESTS=1 \
#     pleiades-attack-simulator.sh --run-active --sim=<name>
#
# Usage:
#   pleiades-attack-simulator.sh --list
#   pleiades-attack-simulator.sh --dry-run --sim=<name>
#   pleiades-attack-simulator.sh --run-active --sim=<name>   # gated
#   pleiades-attack-simulator.sh --score
# ==============================================================================

set -euo pipefail

RUN_ACTIVE=false
SIM_NAME=""
SIM_LOG="${PLEIADES_LOG_DIR:-${PREFIX:-/data/data/com.termux/files/usr}/var/pleiades/log}/attack-sim.log"
SCORE_FILE="${PLEIADES_RUN_DIR:-${TMPDIR:-/tmp}/pleiades/run}/forensic_score"
ANOMALY_FILE="${PLEIADES_RUN_DIR:-${TMPDIR:-/tmp}/pleiades/run}/forensic_anomalies"
FIFO="${PLEIADES_FIFO:-${PLEIADES_RUN_DIR:-${TMPDIR:-/tmp}/pleiades/run}/pleiades-nexus_fifo}"

mkdir -p "$(dirname "$SIM_LOG")" "$(dirname "$SCORE_FILE")"

log()   { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$SIM_LOG"; }
event() { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }

require_lab_mode() {
    if [[ "${PLEIADES_LAB_MODE:-0}" != "1" || "${PLEIADES_I_UNDERSTAND_LOCAL_TESTS:-0}" != "1" ]]; then
        cat >&2 <<'ERR'
Refusing active simulation.
Set BOTH variables only in an owned/authorized lab:
  export PLEIADES_LAB_MODE=1
  export PLEIADES_I_UNDERSTAND_LOCAL_TESTS=1
Then rerun with --run-active.
ERR
        exit 2
    fi
}

list_sims() {
    cat <<'LIST'
Available defensive simulations:
  new_listener      Dry-run event; active mode starts a temporary localhost listener
  port_scan         Dry-run event; active mode probes a tiny localhost port set
  memory_pressure   Dry-run event; active mode allocates a small temporary buffer
  fork_burst        Dry-run event; active mode creates short-lived child processes
  fifo_flood        Dry-run event; active mode writes test events to local FIFO

Default behavior is dry-run/event-only. Active mode is lab-gated.
LIST
}

dry_sim() {
    local name="$1"
    log "DRY-RUN simulation: $name"
    event "DEFENSIVE_SIMULATION_DRY_RUN|name=${name}|ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "dry_run=1 simulation=$name"
}

active_sim() {
    local name="$1"
    require_lab_mode
    log "ACTIVE LAB simulation: $name"
    case "$name" in
        new_listener)
            if command -v nc >/dev/null 2>&1; then
                ( nc -l -p 19999 -w 5 >/dev/null 2>&1 || true ) &
                pid=$!
                sleep 1
                kill "$pid" 2>/dev/null || true
                event "DEFENSIVE_SIMULATION_ACTIVE|name=new_listener|scope=localhost|port=19999"
            else
                log "SKIP: nc not installed"
            fi
            ;;
        port_scan)
            for port in 22 80 443 8080; do
                timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$port" 2>/dev/null || true
            done
            event "DEFENSIVE_SIMULATION_ACTIVE|name=port_scan|scope=127.0.0.1|ports=22,80,443,8080"
            ;;
        memory_pressure)
            python3 - <<'PY' 2>/dev/null || true
buf = bytearray(8 * 1024 * 1024)
PY
            event "DEFENSIVE_SIMULATION_ACTIVE|name=memory_pressure|size=8MiB"
            ;;
        fork_burst)
            for _ in $(seq 1 10); do (sleep 1) & done
            wait 2>/dev/null || true
            event "DEFENSIVE_SIMULATION_ACTIVE|name=fork_burst|children=10"
            ;;
        fifo_flood)
            for i in $(seq 1 25); do event "DEFENSIVE_SIMULATION_ACTIVE|name=fifo_flood|seq=$i"; done
            ;;
        *)
            echo "Unknown simulation: $name" >&2
            list_sims
            exit 1
            ;;
    esac
    echo "active_lab_run=1 simulation=$name"
}

for arg in "$@"; do
    case "$arg" in
        --run-active) RUN_ACTIVE=true ;;
        --dry-run) RUN_ACTIVE=false ;;
        --sim=*) SIM_NAME="${arg#--sim=}" ;;
        --list|-l) list_sims; exit 0 ;;
        --score)
            echo "Current forensic score: $(cat "$SCORE_FILE" 2>/dev/null || echo 'N/A')"
            echo "Current anomalies: $(cat "$ANOMALY_FILE" 2>/dev/null || echo 'None')"
            exit 0
            ;;
        --help|-h) list_sims; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; list_sims; exit 1 ;;
    esac
done

[[ -n "$SIM_NAME" ]] || { list_sims; exit 0; }

if $RUN_ACTIVE; then
    active_sim "$SIM_NAME"
else
    dry_sim "$SIM_NAME"
fi
