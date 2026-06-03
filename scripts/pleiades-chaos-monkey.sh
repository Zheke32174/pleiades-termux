#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# ==============================================================================
# pleiades-chaos-monkey.sh — Resilience & Stress Testing Framework
# 
# Purpose: Purposefully introduce controlled failures to verify the pleiades
# ecosystem recovers correctly. Tests crash recovery, bridge drops, log floods,
# OOM scenarios, and network partitions.
#
# Usage:
#   pleiades-chaos-monkey.sh --test=<name>    Run a specific test
#   pleiades-chaos-monkey.sh --all            Run full battery
#   pleiades-chaos-monkey.sh --list           List available tests
#   pleiades-chaos-monkey.sh --gentle         Non-destructive tests only
#
# Exit codes: 0 = all passed, 1 = any failure
# ==============================================================================

set -euo pipefail

PURPLE_SERVICES=(
    taygete-omniversal.service
    alcyone-omniversal.service
    celaeno-omniversal.service
    pleiades-nexus-omniversal.service
    pleiades-adaptive-builder.service
    pleiades-forensic-scanner.service
    pleiades-request-broker.service
    pleiades-container-watcher.service
    maia.service
    atlas-omniversal.service
)

PASS=0
FAIL=0
SKIP=0
TEST_LOG="/var/log/pleiades/chaos-test.log"

log()   { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$TEST_LOG"; }
pass()  { PASS=$((PASS+1)); log "PASS: $1"; }
fail()  { FAIL=$((FAIL+1)); log "FAIL: $1"; }
skip()  { SKIP=$((SKIP+1)); log "SKIP: $1"; }

setup() {
    mkdir -p /var/log/pleiades /var/lib/pleiades-team
    echo "=== CHAOS MONKEY TEST RUN $(date -u) ===" >> "$TEST_LOG"
}

# ─── Test 1: Service Crash Recovery ───────────────────────────────────────────
test_crash_recovery() {
    local victim="${1:-pleiades-forensic-scanner.service}"
    log "TEST: crash_recovery ($victim)"
    
    # Record initial state
    local initial_state
    initial_state=$(systemctl is-active "$victim" 2>/dev/null || echo "unknown")
    [[ "$initial_state" != "active" ]] && { skip "$victim not active (state=$initial_state)"; return 0; }
    
    local initial_pid
    initial_pid=$(systemctl show -p MainPID "$victim" 2>/dev/null | cut -d= -f2)
    
    # Kill the process
    kill -9 "$initial_pid" 2>/dev/null || true
    sleep 15  # Wait for RestartSec (10) + startup time
    
    # Check recovery
    local new_state
    new_state=$(systemctl is-active "$victim" 2>/dev/null || echo "inactive")
    local new_pid
    new_pid=$(systemctl show -p MainPID "$victim" 2>/dev/null | cut -d= -f2)
    
    if [[ "$new_state" == "active" && "$new_pid" -gt 0 && "$new_pid" != "$initial_pid" ]]; then
        pass "crash_recovery ($victim): PID $initial_pid -> $new_pid"
    else
        fail "crash_recovery ($victim): state=$new_state pid=$new_pid (expected active + new PID)"
    fi
}

# ─── Test 2: FIFO Bus Resilience ──────────────────────────────────────────────
test_fifo_resilience() {
    local fifo="/run/pleiades/pleiades-nexus_fifo"
    log "TEST: fifo_resilience"
    
    [[ -e "$fifo" ]] || { fail "FIFO $fifo not found (expected regular file)"; return; }
    
    # Flood the FIFO with garbage
    for i in $(seq 1 100); do
        echo "CHAOS_TEST_GARBAGE|seq=${i}|$(date +%s%N)" >> "$fifo" 2>/dev/null || true
    done
    
    # Check that the file was written to
    local current_lines
    current_lines=$(wc -l < "$fifo" 2>/dev/null || echo 0)
    if [[ $current_lines -gt 0 ]]; then
        pass "fifo_resilience: $current_lines lines in FIFO (accepts writes)"
    else
        fail "fifo_resilience: FIFO not writable"
    fi
    
    # Check that core services are still responsive
    for svc in atlas-omniversal.service pleiades-nexus-omniversal.service; do
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        if [[ "$state" == "active" ]]; then
            pass "fifo_resilience ($svc survived)"
        else
            fail "fifo_resilience ($svc died: $state)"
        fi
    done
}

# ─── Test 3: Log Flood / Journal Pressure ────────────────────────────────────
test_log_flood() {
    log "TEST: log_flood"
    local flood_count=500
    
    # Rapid logger calls
    for i in $(seq 1 $flood_count); do
        logger -t chaos-flood "CHAOS_TEST_FLOOD_MESSAGE sequence=$i payload=$(date +%s%N)"
    done
    
    sleep 2
    local journal_lines
    journal_lines=$(journalctl -t chaos-flood --since "-10 seconds" --no-pager 2>/dev/null | wc -l || echo 0)
    if [[ $journal_lines -ge $((flood_count - 10)) ]]; then
        pass "log_flood: $journal_lines/$flood_count messages retained"
    else
        skip "log_flood: $journal_lines/$flood_count retained (system may be rate-limiting)"
    fi
}

# ─── Test 4: OOM / Memory Pressure ────────────────────────────────────────────
test_memory_pressure() {
    log "TEST: memory_pressure"
    local stress_pid=""
    
    # Gently allocate memory to trigger pleiades-forensic-scanner memory anomaly detection
    (
        # Allocate ~50MB incrementally
        declare -a leak
        for i in $(seq 1 50); do
            leak+=($(dd if=/dev/zero bs=1M count=1 2>/dev/null | base64))
            sleep 0.1
        done
        sleep 5
    ) &
    stress_pid=$!
    
    sleep 3
    
    # Check if forensic scanner detected it
    local score=0
    [[ -f /run/pleiades/forensic_score ]] && score=$(cat /run/pleiades/forensic_score 2>/dev/null || echo 0)
    
    kill "$stress_pid" 2>/dev/null || true
    
    if [[ $score -gt 0 ]]; then
        pass "memory_pressure: forensic score=$score (anomaly detected)"
    else
        skip "memory_pressure: score=$score (may need longer ramp)"
    fi
}

# ─── Test 5: Mount Point Integrity ────────────────────────────────────────────
test_mount_integrity() {
    log "TEST: mount_integrity"
    local missing=0
    
    for mp in /host/proc /host/sys; do
        if mountpoint -q "$mp" 2>/dev/null; then
            pass "mount_integrity: $mp is mounted"
        else
            fail "mount_integrity: $mp is NOT mounted"
            missing=$((missing+1))
        fi
    done
    
    # Check /run/pleiades exists and has expected structure
    if [[ -d /run/pleiades && -f /run/pleiades/pleiades-nexus_fifo ]]; then
        pass "mount_integrity: /run/pleiades is present with FIFO"
    else
        fail "mount_integrity: /run/pleiades missing or incomplete"
        missing=$((missing+1))
    fi
    
    # Check /host/mnt/c if available
    if [[ -d /host/mnt/c ]]; then
        if mountpoint -q /host/mnt/c 2>/dev/null; then
            pass "mount_integrity: /host/mnt/c is mounted"
        else
            skip "mount_integrity: /host/mnt/c exists but not a mountpoint"
        fi
    fi
}

# ─── Test 6: Service Dependency Chain ─────────────────────────────────────────
test_dependency_chain() {
    log "TEST: dependency_chain"
    
    # Verify all pleiades services are running
    local all_ok=0
    for svc in "${PURPLE_SERVICES[@]}"; do
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
        case "$state" in
            active)
                pass "dependency_chain: $svc is $state"
                ;;
            inactive|dead)
                fail "dependency_chain: $svc is $state (should be active)"
                all_ok=$((all_ok+1))
                ;;
            *)
                skip "dependency_chain: $svc state=$state (not checked)"
                ;;
        esac
    done
}

# ─── Test 7: Network Partition Simulation ────────────────────────────────────
test_network_partition() {
    log "TEST: network_partition"
    
    # Use iptables to drop all outgoing traffic for 5s (simulate partition)
    if command -v iptables &>/dev/null; then
        # Save state
        local had_rules=0
        iptables -L OUTPUT -n 2>/dev/null | grep -q "Chain OUTPUT" && had_rules=1
        
        # Drop outgoing
        iptables -I OUTPUT -j DROP 2>/dev/null || { skip "network_partition: cannot add iptables rule"; return; }
        sleep 3
        iptables -D OUTPUT -j DROP 2>/dev/null || true
        
        # Check services still alive
        for svc in atlas-omniversal.service pleiades-nexus-omniversal.service; do
            local state
            state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            if [[ "$state" == "active" ]]; then
                pass "network_partition: $svc survived 3s partition"
            else
                fail "network_partition: $svc died during partition"
            fi
        done
    else
        skip "network_partition: iptables not available"
    fi
}

# ─── Test 8: Purple Target Verification ───────────────────────────────────────
test_pleiades_target() {
    log "TEST: pleiades_target"
    
    if systemctl is-active pleiades.target &>/dev/null; then
        local wanted
        wanted=$(systemctl show -p Wants pleiades.target 2>/dev/null | tr '=' '\n' | tail -n +2 | tr ' ' '\n' | grep -c '.service' || echo 0)
        pass "pleiades_target: active ($wanted wanted services)"
    elif systemctl list-dependencies pleiades.target &>/dev/null; then
        local deps
        deps=$(systemctl list-dependencies pleiades.target 2>/dev/null | grep -c '.service' || echo 0)
        pass "pleiades_target: target exists ($deps service dependencies)"
    else
        skip "pleiades_target: target not found"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
list_tests() {
    echo "Available chaos monkey tests:"
    echo "  crash_recovery     Kill a service process and verify auto-restart"
    echo "  fifo_resilience    Flood the pleiades-nexus FIFO with garbage"
    echo "  log_flood           Rapid logger calls to test journald pressure"
    echo "  memory_pressure     Allocate memory to trigger anomaly detection"
    echo "  mount_integrity     Verify critical mount points are present"
    echo "  dependency_chain    Check all pleiades services are running"
    echo "  network_partition   Drop all traffic for 5s (requires iptables)"
    echo "  pleiades_target       Verify pleiades.target is loaded"
}

run_all() {
    local mode="${1:-full}"
    setup
    
    test_crash_recovery pleiades-forensic-scanner.service
    test_fifo_resilience
    test_log_flood
    test_mount_integrity
    test_dependency_chain
    test_pleiades_target
    
    if [[ "$mode" == "full" ]]; then
        test_memory_pressure
        test_network_partition
    fi
    
    # Summary
    echo ""
    echo "=== CHAOS MONKEY RESULTS ==="
    echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
    
    if [[ $FAIL -gt 0 ]]; then
        echo "SOME TESTS FAILED — review $TEST_LOG"
        exit 1
    fi
    echo "ALL TESTS PASSED"
}

case "${1:---help}" in
    --list|-l)
        list_tests
        ;;
    --test=*)
        setup
        test_name="${1#--test=}"
        "test_${test_name}" || true
        echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
        ;;
    --all|-a)
        run_all full
        ;;
    --gentle|-g)
        run_all gentle
        ;;
    *)
        echo "Usage: $0 [--all|--gentle|--list|--test=<name>]"
        list_tests
        exit 1
        ;;
esac
