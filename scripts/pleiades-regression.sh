#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# Purple-team regression harness — framework + syntax/systemd/port tests
# Usage: bash pleiades-regression.sh [--skip-container]
# Sources: pleiades-regression-lib.sh (advanced tests)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="/var/log/pleiades-regression"
PASS=0; FAIL=0; SKIP=0
SKIP_CONTAINER="${1:-}"

SCRIPTS=(Maia Taygete Alcyone Electra Celaeno Sterope Merope Atlas)
CONTAINER_PID=""

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP: $1"; }

run_group() {
    local name="$1"; shift
    echo ""
    echo "=== $name ==="
    "$@" || true
}

container_up() {
    # Prefer the machinectl leader PID (the container's init) over the nspawn
    # manager wrapper — nsenter on the manager enters the host namespace, not
    # the container's, so binary checks and ss/systemctl calls all fail.
    local leader
    leader="$(machinectl show pleiades-dr 2>/dev/null | awk -F= '/^Leader=/{print $2}')"
    if [[ -n "$leader" && "$leader" -gt 1 ]]; then
        CONTAINER_PID="$leader"
        return 0
    fi
    # Fallback: nspawn manager PID (works for pgrep presence check only)
    CONTAINER_PID="$(pgrep -x systemd-nspawn | head -1 2>/dev/null || true)"
    [[ -n "$CONTAINER_PID" ]]
}

in_container() {
    # Run a command inside the nspawn container via nsenter on the leader PID
    sudo nsenter -t "$CONTAINER_PID" -m -u -i -n -p -- bash -c "$1" 2>/dev/null
}

summary() {
    echo ""
    echo "════════════════════════════════════"
    echo "  PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    echo "════════════════════════════════════"
    mkdir -p "$REPORT_DIR"
    cat > "$REPORT_DIR/last-run.json" <<JSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pass": $PASS,
  "fail": $FAIL,
  "skip": $SKIP,
  "result": "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"
}
JSON
    echo "  Report: $REPORT_DIR/last-run.json"
    [[ "$FAIL" -eq 0 ]]
}

# ── subtask 2: syntax validation + systemd unit verification ─────────────────

test_syntax_and_units() {
    echo "-- bash -n on 8 scripts --"
    for name in "${SCRIPTS[@]}"; do
        local f="$SCRIPT_DIR/${name}.sh"
        if [[ ! -f "$f" ]]; then
            fail "missing script: ${name}.sh"
            continue
        fi
        if bash -n "$f" 2>/dev/null; then
            pass "bash -n ${name}.sh"
        else
            fail "bash -n ${name}.sh"
        fi
    done

    echo "-- systemd-analyze verify --"
    if ! container_up || [[ "$SKIP_CONTAINER" == "--skip-container" ]]; then
        skip "systemd verify (container down)"
        return
    fi

    local units
    units="$(in_container "systemctl list-unit-files --state=enabled,static \
        | awk '{print \$1}' \
        | grep -E '(-omniversal|pleiades-|maia|host-bridge-monitor|windows-host-bridge-monitor)\.service' \
        | tr '\n' ' '")" || true

    if [[ -z "$units" ]]; then
        skip "systemd verify (no matching units found)"
        return
    fi

    for u in $units; do
        if in_container "systemd-analyze verify '$u'" 2>/dev/null; then
            pass "systemd-analyze verify $u"
        else
            fail "systemd-analyze verify $u"
        fi
    done
}

# ── subtask 3: decoy port liveness + Taygete concurrency cap ────────────────

test_ports_and_concurrency() {
    if ! container_up || [[ "$SKIP_CONTAINER" == "--skip-container" ]]; then
        skip "port liveness (container down)"
        skip "Taygete concurrency cap (container down)"
        return
    fi

    echo "-- decoy port liveness --"
    for port in 2222 2223 2224; do
        if in_container "ss -tlnp | grep -q ':${port} '" 2>/dev/null; then
            pass "port ${port} listening"
        else
            fail "port ${port} not listening"
        fi
    done

    # owner-helper: loopback only inside container
    if in_container "ss -tlnp | grep -q '127.0.0.1:18080'" 2>/dev/null; then
        pass "port 18080 (owner-helper loopback)"
    else
        fail "port 18080 (owner-helper) not listening on loopback"
    fi

    echo "-- Taygete concurrency cap (MAX_CONNS_PER_IP=8) --"
    # Run all 12 connections inside the container in one nsenter call so they are
    # truly concurrent from 127.0.0.1.  Keep stdin alive with (sleep 5) so
    # connections persist long enough for the cap to be measured before any close.
    local banner_count=0
    banner_count="$(in_container '
        pids=()
        for i in $(seq 1 12); do
            { (sleep 5) | timeout 6 nc -w 5 127.0.0.1 2222 > /tmp/_cap_test_${i}.out 2>/dev/null; } &
            pids+=($!)
        done
        sleep 1
        for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
        count=0
        for i in $(seq 1 12); do
            [ -s /tmp/_cap_test_${i}.out ] && count=$((count+1))
        done
        echo $count
        rm -f /tmp/_cap_test_*.out 2>/dev/null
    ' 2>/dev/null)" || banner_count=0
    banner_count="${banner_count//[^0-9]/}"
    banner_count="${banner_count:-0}"

    if [[ "$banner_count" -le 8 ]]; then
        pass "Taygete concurrency cap: ${banner_count}/12 got banner (≤8 expected)"
    else
        fail "Taygete concurrency cap: ${banner_count}/12 got banner (>8 — cap not enforced)"
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────

mkdir -p "$REPORT_DIR"
echo "Purple-team regression harness — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
container_up && echo "Container PID: $CONTAINER_PID" || echo "Container: DOWN"

run_group "Syntax validation + systemd units" test_syntax_and_units

# --- ADVANCED TESTS SOURCED FROM pleiades-regression-lib.sh ---
# Recon replay runs BEFORE concurrency cap: the cap test floods 127.0.0.1 with
# connections which elevates hitCount and can trigger AGGRESSIVE mode, interfering
# with telemetry checks that follow.
LIB="$SCRIPT_DIR/pleiades-regression-lib.sh"
if [[ -f "$LIB" ]]; then
    # shellcheck source=pleiades-regression-lib.sh
    source "$LIB"
    run_group "Hostile-recon replay"         test_recon_replay
    run_group "Policy broker deny matrix"    test_broker_deny_matrix
    run_group "Host-bridge + Windows telemetry" test_host_bridge
    run_group "Celaeno liveness"         test_celaeno_alive
    run_group "Maia crypto round-trip"     test_maia_crypto
    run_group "LLM stack (task #30)"         test_llm_stack
    run_group "RE pipeline (task #31)"       test_re_pipeline
    # Concurrency cap runs last — floods 127.0.0.1 and may trigger AGGRESSIVE mode
    run_group "Decoy port liveness + Taygete concurrency" test_ports_and_concurrency
else
    run_group "Decoy port liveness + Taygete concurrency" test_ports_and_concurrency
    skip "Advanced tests (pleiades-regression-lib.sh not found)"
fi

summary
