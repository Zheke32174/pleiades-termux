#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# ==============================================================================
# pleiades-quick-check.sh — Fast auxiliary scanner (15s cycle)
#
# Catches transient attacks that the 60s main scanner might miss:
#   - Journald auth failures (SSH brute force)
#   - Process spawn rate (fork bombs)
#   - Memory change rate (rapid allocation)
#   - FD change rate
#   - FIFO health monitoring
#
# Runs independently from the main forensic scanner.
# Reports via FIFO event bus.
# ==============================================================================

set -euo pipefail

SCORE_FILE="${PREFIX:-/data/data/com.termux/files/usr}/var/run/pleiades/forensic_score"
ANOMALY_FILE="${PREFIX:-/data/data/com.termux/files/usr}/var/run/pleiades/forensic_anomalies"
FIFO="${PREFIX:-/data/data/com.termux/files/usr}/var/run/pleiades/pleiades-nexus_fifo"
STATE_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/pleiades-team/forensic"
LOG_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/log/pleiades"
INTERVAL=15

mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$FIFO")"

event()  { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }
log()    { echo "[$(date -u +%H:%M:%S)] [quick] $*" >> "$LOG_DIR/quick-check.log"; }

score_incr() {
    local amount=$1 msg="$2"
    local cur=0
    [[ -f "$SCORE_FILE" ]] && cur=$(cat "$SCORE_FILE")
    echo $((cur + amount)) > "$SCORE_FILE"
    echo "$msg" >> "$ANOMALY_FILE"
    event "QUICK_CHECK|${msg}"
    log "score +${amount}: ${msg}"
}

# ─── 1. Auth failure detection ──────────────────────────────────────────────────
check_auth_journal() {
    local auth_counter="${PREFIX:-/data/data/com.termux/files/usr}/var/run/pleiades/auth_fail_count"
    local count=0

    # Read any auth alerts from the decisions directory
    if [[ -d "${PREFIX:-/data/data/com.termux/files/usr}/var/run/pleiades/decisions" ]]; then
        count=$(find "${PREFIX:-/data/data/com.termux/files/usr}/var/run/pleiades/decisions" -name "*.auth_alert" 2>/dev/null | wc -l)
    fi

    
    # Write to the counter file for the main scanner
    echo "$count" > "$auth_counter" 2>/dev/null || true
}

# ─── 2. Rapid process spawn detection (every 15s) ───────────────────────────────
check_proc_spawn() {
    local proc_file="$STATE_DIR/.proc_count_15s"
    local now
    now=$(ps -e 2>/dev/null | wc -l || echo 0)
    
    if [[ -f "$proc_file" ]]; then
        local prev
        prev=$(cat "$proc_file")
        local delta=$(( now - prev ))
        if [[ $delta -gt 20 ]]; then
            score_incr $(( delta * 2 )) "RAPID_PROC_SPAWN|delta=${delta}|now=${now}"
        fi
    fi
    echo "$now" > "$proc_file"
}

# ─── 3. Rapid memory change ─────────────────────────────────────────────────────
check_mem_spawn() {
    local mem_file="$STATE_DIR/.mem_15s"
    local now
    now=$(free | awk '/^Mem:/ {printf "%d", $3/$2 * 100}' 2>/dev/null || echo 0)
    
    if [[ -f "$mem_file" ]]; then
        local prev
        prev=$(cat "$mem_file")
        local delta=$(( now - prev ))
        if [[ $delta -gt 8 ]]; then
            score_incr $(( delta * 3 )) "RAPID_MEM_ALLOC|delta=${delta}pts|now=${now}%"
        fi
    fi
    echo "$now" > "$mem_file"
}

# ─── 4. FIFO health check ──────────────────────────────────────────────────────
check_fifo_health() {
    local fifo_size=0
    [[ -p "$FIFO" ]] && fifo_size=$(stat -c%s "$FIFO" 2>/dev/null || echo 0)
    
    if [[ "$fifo_size" -gt 10240 ]]; then
        score_incr 15 "FIFO_BACKLOG|size=${fifo_size}"
    fi
    
    # Check if we can write to FIFO
    if ! printf '' >> "$FIFO" 2>/dev/null; then
        score_incr 30 "FIFO_BROKEN|cannot_write"
    fi
}

# ─── 5. Listener check (every cycle catches transient listeners) ────────────────
check_listeners() {
    local listener_count
    listener_count=$(ss -tlnp 2>/dev/null | tail -n +2 | wc -l || echo 0)
    local prev_file="$STATE_DIR/.listener_count_15s"
    
    if [[ -f "$prev_file" ]]; then
        local prev
        prev=$(cat "$prev_file")
        if [[ "$listener_count" -gt "$prev" ]]; then
            local new_listeners
            new_listeners=$(ss -tlnp 2>/dev/null | tail -n +2 | awk '{print $4}' | sed 's/.*://' | tr '\n' ',' | sed 's/,$//')
            score_incr 10 "NEW_LISTENER_QUICK|ports=${new_listeners}"
        fi
    fi
    echo "$listener_count" > "$prev_file"
}

# ─── Main loop ──────────────────────────────────────────────────────────────────
log "quick-check starting (interval=${INTERVAL}s)"

while true; do
    check_auth_journal
    check_proc_spawn
    check_mem_spawn
    check_fifo_health
    check_listeners
    
    sleep "$INTERVAL"
done
