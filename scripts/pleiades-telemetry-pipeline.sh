#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# ==============================================================================
# pleiades-telemetry-pipeline.sh — Log Aggregation & Forwarding Pipeline
#
# Aggregates logs from all pleiades ecosystem components, enriches them with
# container context, and forwards them to:
#   - /var/log/pleiades/aggregated/ (rotated, compressed)
#   - /host/mnt/c/Users/<WIN_USER>/AppData/Roaming/pleiades-logs/ (Windows bridge, WSL only)
#   - journald (structured metadata)
#
# Provides a real-time dashboard that can be tailed with:
#   journalctl -f -t pleiades-telemetry
# ==============================================================================

set -euo pipefail

AGG_DIR="/var/log/pleiades/aggregated"
# Derive Windows bridge path from current user if on WSL; no-op otherwise
if grep -qi microsoft /proc/version 2>/dev/null; then
    _win_user="$(cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r' || true)"
    WIN_BRIDGE="${WIN_BRIDGE:-/host/mnt/c/Users/${_win_user}/AppData/Roaming/pleiades-logs}"
else
    WIN_BRIDGE="${WIN_BRIDGE:-}"
fi
MAX_LOG_AGE_HOURS=72
CLEAN_INTERVAL=3600  # clean up old logs every hour

mkdir -p "$AGG_DIR"

log()  { local msg="[$(date -u +%H:%M:%S)] [$$] $*"; echo "$msg" >> /var/log/pleiades/telemetry-pipeline.log; echo "$msg"; }

# ─── Gather component status ──────────────────────────────────────────────────
gather_component_status() {
    local out="$AGG_DIR/components_$(date -u +%Y%m%dT%H%M%SZ).json"
    
    # Build a structured JSON summary
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"container\": {"
        echo "    \"hostname\": \"$(hostname)\","
        echo "    \"uptime_seconds\": $(awk '{print $1}' /proc/uptime 2>/dev/null | cut -d. -f1),"
        echo "    \"boot_id\": \"$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)\""
        echo "  },"
        echo "  \"services\": ["
        local first=true
        for svc in $(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -E 'pleiades|atlas|taygete|pleiades-nexus|maia|alcyone|electra|little' | head -20); do
            $first || echo ","
            first=false
            local pid memory cpu
            pid=$(systemctl show -p MainPID "$svc" 2>/dev/null | cut -d= -f2)
            memory=$(systemctl show -p MemoryCurrent "$svc" 2>/dev/null | cut -d= -f2)
            cpu=$(systemctl show -p CPUUsageNSec "$svc" 2>/dev/null | cut -d= -f2)
            printf '    { "name": "%s", "pid": %s, "memory_bytes": %s, "cpu_nsec": %s }' \
                "$svc" "${pid:-0}" "${memory:-0}" "${cpu:-0}"
        done
        echo ""
        echo "  ],"
        echo "  "aggregated_at": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
        echo "}"
    } > "$out"
    
    gzip -f "$out" 2>/dev/null || true
    log "component snapshot: ${out}.gz"
}

# ─── Forward to Windows host ──────────────────────────────────────────────────
bridge_to_windows() {
    if [[ -d "$WIN_BRIDGE" ]]; then
        # Copy recent logs
        find "$AGG_DIR" -name '*.gz' -mmin -5 -exec cp {} "$WIN_BRIDGE/" \; 2>/dev/null || true
        # Also copy forensic score + anomalies
        if [[ -f /run/pleiades/forensic_score ]]; then
            cp /run/pleiades/forensic_score "$WIN_BRIDGE/forensic_score.live" 2>/dev/null || true
        fi
        if [[ -f /run/pleiades/forensic_anomalies ]]; then
            cp /run/pleiades/forensic_anomalies "$WIN_BRIDGE/forensic_anomalies.live" 2>/dev/null || true
        fi
        log "bridge: logs forwarded to $WIN_BRIDGE"
    fi
}

# ─── Rotate old logs ──────────────────────────────────────────────────────────
rotate_logs() {
    find "$AGG_DIR" -name '*.gz' -mmin "+$((MAX_LOG_AGE_HOURS * 60))" -delete 2>/dev/null || true
    find "$AGG_DIR" -name '*.json' -mmin "+$((MAX_LOG_AGE_HOURS * 60))" -delete 2>/dev/null || true
    log "rotation: cleaned logs older than ${MAX_LOG_AGE_HOURS}h"
}

# ─── Main loop ────────────────────────────────────────────────────────────────
main() {
    log "telemetry pipeline starting"
    mkdir -p "$AGG_DIR"
    
    # Try to create Windows bridge directory (WSL only; skipped if WIN_BRIDGE is unset)
    [[ -n "${WIN_BRIDGE:-}" ]] && { mkdir -p "$WIN_BRIDGE" 2>/dev/null || log "warn: cannot create Windows bridge (host may not be mounted)"; }
    
    local cycle=0
    while true; do
        # Gather component status every 60s
        gather_component_status
        
        # Bridge to Windows every 2 cycles
        if (( cycle % 2 == 0 )); then
            bridge_to_windows
        fi
        
        # Rotate old logs every 60 cycles (~hourly)
        if (( cycle % 60 == 0 )); then
            rotate_logs
        fi
        
        # Brief telemetry heartbeat to indicate the pipeline is alive
        log "heartbeat: cycle=${cycle} agg_dir=$(find "$AGG_DIR" -name '*.gz' | wc -l) files"
        
        sleep 60
        cycle=$((cycle + 1))
    done
}

main
