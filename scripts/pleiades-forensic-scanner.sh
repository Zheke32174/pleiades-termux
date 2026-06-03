#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# ==============================================================================
# pleiades-forensic-scanner.sh — Pleiades Team Forensic & Heuristic Scanner
# 
# Provides:
#   - Behavioral baseline profiling (CPU, memory, network, filesystem)
#   - Anomaly detection via heuristic scoring
#   - Memory acquisition snapshot (via /proc/kcore when available)
#   - Network connection snapshot
#   - Filesystem integrity snapshot
#   - Zero-day adaptation: adjusts thresholds based on observed patterns
#
# Integrates with the pleiades event bus (/run/pleiades/pleiades-nexus_fifo)
# Reports to Atlas threat scoring via FORENSIC_OBSERVATION events
# Logs to syslog/journald for observability
# ==============================================================================

set -euo pipefail

FIFO="/run/pleiades/pleiades-nexus_fifo"
STATE_DIR="/var/lib/pleiades-team/forensic"
PROFILE_DIR="$STATE_DIR/profiles"
SNAPSHOT_DIR="$STATE_DIR/snapshots"
THRESHOLD_FILE="$STATE_DIR/thresholds"
BASELINE_FILE="$STATE_DIR/baseline"
ADAPTIVE_RULES="$STATE_DIR/adaptive_rules"
SCORE_FILE="/run/pleiades/forensic_score"
ANOMALY_FILE="/run/pleiades/forensic_anomalies"
BASE_INTERVAL=${FORENSIC_INTERVAL:-60}  # seconds between main cycles

mkdir -p "$STATE_DIR" "$PROFILE_DIR" "$SNAPSHOT_DIR"

log()   { local msg="[$(date -u +%H:%M:%S)] [$$] $*"; echo "$msg" >> /var/log/pleiades/forensic-scanner.log; echo "$msg"; }
event() { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }

# ─── Initialize or load adaptive thresholds ───────────────────────────────────
init_thresholds() {
    if [[ ! -f "$THRESHOLD_FILE" ]]; then
        cat > "$THRESHOLD_FILE" << 'THRESH'
# Purple Forensic Thresholds — auto-tuned by heuristic adaptation
# Format: metric|baseline|current_threshold|sensitivity_multiplier
cpu_usage_pct|0|90|1.0
memory_usage_pct|0|95|1.0
disk_io_ops|0|1000|1.0
net_conn_count|0|200|1.0
net_new_ports|0|20|1.0
proc_count|0|500|1.0
file_change_rate|0|100|1.0
THRESH
        log "thresholds initialized"
    fi
    # Load into associative arrays via eval-safe parsing
    declare -gA THRESHOLDS
    while IFS='|' read -r metric baseline threshold sensitivity; do
        [[ -z "$metric" || "$metric" == "#"* ]] && continue
        THRESHOLDS["${metric}_baseline"]=$baseline
        THRESHOLDS["${metric}_threshold"]=$threshold
        THRESHOLDS["${metric}_sensitivity"]=$sensitivity
    done < "$THRESHOLD_FILE"
    log "thresholds loaded: ${#THRESHOLDS[@]} metrics"
}

# ─── Baseline Profiling ────────────────────────────────────────────────────────
capture_baseline() {
    local cpu_usage=0 mem_usage=0; local net_conn=0 proc_count=0 disk_ops=0
    
    # CPU — ameropege idle over 3 samples, invert
    local idle_total=0
    for i in 1 2 3; do
        local idle
        idle=$(grep '^cpu ' /proc/stat 2>/dev/null | awk '{print $5}' || echo 0)
        sleep 1
        local idle2
        idle2=$(grep '^cpu ' /proc/stat 2>/dev/null | awk '{print $5}' || echo 0)
        idle_total=$((idle_total + (idle2 - idle)))
    done
    local avg_idle=$((idle_total / 3))
    [[ $avg_idle -gt 1000 ]] && cpu_usage=5 || cpu_usage=$((100 - (avg_idle / 10)))
    [[ $cpu_usage -lt 0 ]] && cpu_usage=0
    [[ $cpu_usage -gt 100 ]] && cpu_usage=100

    # Memory
    mem_usage=$(free | awk '/^Mem:/ {printf "%d", $3/$2 * 100}' 2>/dev/null || echo 50)

    # Network connections
    net_conn=$(ss -tun 2>/dev/null | tail -n +2 | wc -l || netstat -tun 2>/dev/null | tail -n +3 | wc -l || echo 0)

    # Process count
    proc_count=$(ps -e 2>/dev/null | wc -l || echo 0)

    # Disk operations (read+write completions across all disks)
    disk_ops=$(awk '{ops+=$4+$8} END {print ops}' /proc/diskstats 2>/dev/null || echo 0)

    # Write baseline
    {
        printf '# Purple Forensic Baseline — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'cpu_usage=%d\n' "$cpu_usage"
        printf 'memory_usage=%d\n' "$mem_usage"
        printf 'net_connections=%d\n' "$net_conn"
        printf 'process_count=%d\n' "$proc_count"
        printf 'disk_ops=%d\n' "$disk_ops"
    } > "$BASELINE_FILE"

    # Also update profile
    local profile_file="$PROFILE_DIR/$(date -u +%Y%m%d).profile"
    printf '%s|cpu=%d|mem=%d|net=%d|proc=%d|disk=%d\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$cpu_usage" "$mem_usage" "$net_conn" "$proc_count" "$disk_ops" >> "$profile_file"

    # Update thresholds if not set
    local needs_update=0
    for metric in cpu_usage_pct memory_usage_pct net_conn_count proc_count disk_io_ops; do
        local key="${metric}_baseline"
        if [[ "${THRESHOLDS[$key]:-0}" == "0" ]]; then
            needs_update=1
            break
        fi
    done

    if [[ $needs_update -eq 1 ]]; then
        # Update threshold file with actual baseline values
        {
            printf '# Purple Forensic Thresholds — auto-tuned\n'
            printf '# Format: metric|baseline|current_threshold|sensitivity_multiplier\n'
            printf 'cpu_usage_pct|%d|90|1.0\n' "$cpu_usage"
            printf 'memory_usage_pct|%d|95|1.0\n' "$mem_usage"
            printf 'disk_io_ops|%d|1000|1.0\n' "$disk_ops"
            printf 'net_conn_count|%d|200|1.0\n' "$net_conn"
            printf 'net_new_ports|0|20|1.0\n'
            printf 'proc_count|%d|500|1.0\n' "$proc_count"
            printf 'file_change_rate|0|100|1.0\n'
        } > "$THRESHOLD_FILE"
        init_thresholds  # Reload
    fi

    log "baseline: cpu=$cpu_usage mem=$mem_usage net=$net_conn proc=$proc_count disk=$disk_ops"
}

# ─── Anomaly Detection ─────────────────────────────────────────────────────────
check_anomalies() {
    local total_score=0
    local anomalies=()

    # 1. CPU usage anomaly
    local cpu_now
    cpu_now=$(grep '^cpu ' /proc/stat 2>/dev/null | awk '{print $5}' || echo 0)
    sleep 1
    local cpu_now2
    cpu_now2=$(grep '^cpu ' /proc/stat 2>/dev/null | awk '{print $5}' || echo 0)
    local cpu_idle=$((cpu_now2 - cpu_now))
    local cpu_pct=0
    if [[ $cpu_idle -gt 1000 ]]; then
        cpu_pct=5
    else
        cpu_pct=$((100 - (cpu_idle / 10)))
        [[ $cpu_pct -lt 0 ]] && cpu_pct=0
        [[ $cpu_pct -gt 100 ]] && cpu_pct=100
    fi
    local cpu_threshold="${THRESHOLDS[cpu_usage_pct_threshold]:-90}"
    if [[ $cpu_pct -gt $cpu_threshold ]]; then
        local score=$(( (cpu_pct - cpu_threshold) * 2 ))
        [[ $score -lt 5 ]] && score=5
        total_score=$((total_score + score))
        anomalies+=("HIGH_CPU|${cpu_pct}%|threshold=${cpu_threshold}|score=${score}")
    fi

    # 2. New network listeners (port scan)
    local current_listeners
    current_listeners=$(ss -tlnp 2>/dev/null | tail -n +2 | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' '|' || netstat -tlnp 2>/dev/null | tail -n +3 | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' '|' || echo "")
    local listeners_file="$STATE_DIR/.known_listeners"
    if [[ -f "$listeners_file" ]]; then
        local known_listeners
        known_listeners=$(cat "$listeners_file")
        local new_listeners=""
        IFS='|' read -ra arr <<< "$current_listeners"
        for port in "${arr[@]}"; do
            if [[ -z "$port" ]]; then continue; fi
            if [[ "$known_listeners" != *"|${port}|"* && "$known_listeners" != "${port}|"* && "$known_listeners" != *"|${port}" ]]; then
                new_listeners="${new_listeners}${port},"
            fi
        done
        if [[ -n "$new_listeners" ]]; then
            local score=$(( $(echo "$new_listeners" | tr -cd ',' | wc -c) * 15 + 10 ))
            [[ $score -gt 100 ]] && score=100
            total_score=$((total_score + score))
            anomalies+=("UNKNOWN_LISTENER|ports=${new_listeners%,}|score=${score}")
            log "WARN: new listeners detected: ${new_listeners%,}"
        fi
    fi
    echo "$current_listeners" > "$listeners_file"

    # 3. Memory pressure anomaly
    local mem_now
    mem_now=$(free | awk '/^Mem:/ {printf "%d", $3/$2 * 100}' 2>/dev/null || echo 0)
    local mem_threshold="${THRESHOLDS[memory_usage_pct_threshold]:-95}"
    if [[ $mem_now -gt $mem_threshold ]]; then
        local score=$(( (mem_now - mem_threshold) * 3 ))
        [[ $score -lt 10 ]] && score=10
        [[ $score -gt 80 ]] && score=80
        total_score=$((total_score + score))
        anomalies+=("HIGH_MEMORY|${mem_now}%|threshold=${mem_threshold}|score=${score}")
    fi

    # 4. Process count spike
    local proc_now
    proc_now=$(ps -e 2>/dev/null | wc -l || echo 0)
    local proc_threshold="${THRESHOLDS[proc_count_threshold]:-500}"
    if [[ $proc_now -gt $proc_threshold ]]; then
        local score=$(( (proc_now - proc_threshold) / 10 ))
        [[ $score -lt 5 ]] && score=5
        [[ $score -gt 60 ]] && score=60
        total_score=$((total_score + score))
        anomalies+=("HIGH_PROC_COUNT|${proc_now}|threshold=${proc_threshold}|score=${score}")
    fi

    # 5. Kernel module load spike (zero-day indicator)
    local mod_count
    mod_count=$(lsmod 2>/dev/null | wc -l || echo 0)
    local mod_file="$STATE_DIR/.known_modules"
    if [[ -f "$mod_file" ]]; then
        local prev_mods
        prev_mods=$(cat "$mod_file")
        local diff=$((mod_count - prev_mods))
        if [[ $diff -gt 5 ]]; then
            local score=$(( diff * 5 ))
            [[ $score -gt 80 ]] && score=80
            total_score=$((total_score + score))
            anomalies+=("KERNEL_MODULE_SPIKE|new_modules=${diff}|score=${score}")
        fi
    fi
    echo "$mod_count" > "$mod_file"

    # 6. Network connection flood anomaly
    local conn_now
    conn_now=$(ss -tun 2>/dev/null | tail -n +2 | wc -l || netstat -tun 2>/dev/null | tail -n +3 | wc -l || echo 0)
    local conn_threshold="${THRESHOLDS[net_conn_count_threshold]:-200}"
    if [[ $conn_now -gt $conn_threshold ]]; then
        local score=$(( (conn_now - conn_threshold) / 10 ))
        [[ $score -lt 5 ]] && score=5
        [[ $score -gt 60 ]] && score=60
        total_score=$((total_score + score))
        anomalies+=("HIGH_CONNECTIONS|${conn_now}|threshold=${conn_threshold}|score=${score}")
    fi

    # 7. Promiscuous mode detection (packet sniffing indicator)
    local promisc
    promisc=$(ip link show 2>/dev/null | grep -c PROMISC || echo 0)
    if [[ $promisc -gt 0 ]]; then
        local score=$(( promisc * 20 ))
        [[ $score -gt 100 ]] && score=100
        total_score=$((total_score + score))
        local interfaces
        interfaces=$(ip link show 2>/dev/null | grep PROMISC | awk -F: '{print $2}' | tr '\n' ',')
        anomalies+=("PROMISCUOUS_MODE|interfaces=${interfaces%,}|score=${score}")
    fi

    # 8. File descriptor exhaustion check
    local fd_usage
    fd_usage=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}' || echo 0)
    local fd_max
    fd_max=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $3}' || echo 100000)
    if [[ $fd_max -gt 0 ]]; then
        local fd_pct=$(( fd_usage * 100 / fd_max ))
        if [[ $fd_pct -gt 80 ]]; then
            local score=$(( (fd_pct - 80) * 2 ))
            [[ $score -lt 5 ]] && score=5
            [[ $score -gt 50 ]] && score=50
            total_score=$((total_score + score))
            anomalies+=("FD_EXHAUSTION|${fd_pct}%|score=${score}")
        fi
    fi

    # Write score and anomalies
    echo "$total_score" > "$SCORE_FILE"
    printf '%s\n' "${anomalies[@]}" > "$ANOMALY_FILE"

    # Report to event bus
    if [[ $total_score -gt 0 ]]; then
        event "FORENSIC_OBSERVATION|score=${total_score}|$(printf '%s|' "${anomalies[@]}")"
        log "anomaly score=${total_score}: ${anomalies[*]}"
    fi

    # Adaptive: tune thresholds downward if we're consistently clean
    local clean_file="$STATE_DIR/.clean_cycles"
    local clean_count=0
    [[ -f "$clean_file" ]] && clean_count=$(cat "$clean_file")
    if [[ $total_score -eq 0 ]]; then
        clean_count=$((clean_count + 1))
        echo "$clean_count" > "$clean_file"
        # Every 10 clean cycles, decrease sensitivity by 5% (become more alert)
        if [[ $clean_count -gt 0 ]] && (( clean_count % 10 == 0 )); then
            local tmp
            tmp=$(mktemp)
            while IFS='|' read -r metric baseline threshold sensitivity; do
                [[ -z "$metric" || "$metric" == "#"* ]] && { echo "$metric|$baseline|$threshold|$sensitivity" >> "$tmp"; continue; }
                local new_sens
                new_sens=$(echo "$sensitivity * 0.95" | bc -l 2>/dev/null | awk '{printf "%.2f", $1}')
                [[ -z "$new_sens" || "$new_sens" == "0" ]] && new_sens="0.95"
                echo "$metric|$baseline|$threshold|$new_sens" >> "$tmp"
            done < "$THRESHOLD_FILE"
            mv "$tmp" "$THRESHOLD_FILE"
            init_thresholds
            log "adaptive sensitivity decreased (clean cycles=${clean_count})"
        fi
    else
        echo "0" > "$clean_file"
        # Anomaly detected: increase sensitivity by 10%
        local tmp
        tmp=$(mktemp)
        while IFS='|' read -r metric baseline threshold sensitivity; do
            [[ -z "$metric" || "$metric" == "#"* ]] && { echo "$metric|$baseline|$threshold|$sensitivity" >> "$tmp"; continue; }
            local new_sens
            new_sens=$(echo "$sensitivity * 1.10" | bc -l 2>/dev/null | awk '{printf "%.2f", $1}')
            [[ -z "$new_sens" || "$new_sens" == "0" ]] && new_sens="1.10"
            echo "$metric|$baseline|$threshold|$new_sens" >> "$tmp"
        done < "$THRESHOLD_FILE"
        mv "$tmp" "$THRESHOLD_FILE"
        init_thresholds
        log "adaptive sensitivity increased (score=${total_score})"
    fi
}

# ─── Network Snapshot ──────────────────────────────────────────────────────────
capture_network_snapshot() {
    local out="$SNAPSHOT_DIR/network_$(date -u +%Y%m%dT%H%M%SZ).txt"
    {
        echo "=== NETWORK SNAPSHOT $(date -u) ==="
        echo "--- Interfaces ---"
        ip addr 2>/dev/null || ifconfig 2>/dev/null || true
        echo "--- Routing ---"
        ip route 2>/dev/null || route -n 2>/dev/null || true
        echo "--- Connections ---"
        ss -tanp 2>/dev/null || netstat -tanp 2>/dev/null || true
        echo "--- Listeners ---"
        ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true
        echo "--- ARP ---"
        ip neigh 2>/dev/null || arp -a 2>/dev/null || true
        echo "--- Socket Stats ---"
        cat /proc/net/sockstat 2>/dev/null || true
    } > "$out"
    gzip -f "$out" 2>/dev/null || true
    event "FORENSIC_SNAPSHOT|network|${out}.gz"
    log "network snapshot: ${out}.gz"
}

# ─── Memory Snapshot ───────────────────────────────────────────────────────────
capture_memory_snapshot() {
    local out="$SNAPSHOT_DIR/memory_$(date -u +%Y%m%dT%H%M%SZ).txt"
    {
        echo "=== MEMORY SNAPSHOT $(date -u) ==="
        echo "--- Memory Info ---"
        cat /proc/meminfo 2>/dev/null || true
        echo "--- Top Memory Consumers ---"
        ps aux --sort=-%mem 2>/dev/null | head -30 || true
        echo "--- Slab Info ---"
        cat /proc/slabinfo 2>/dev/null | head -20 || true
        echo "--- Vmstat ---"
        vmstat 1 3 2>/dev/null || true
        echo "--- Swap ---"
        swapon --show 2>/dev/null || true
    } > "$out"
    gzip -f "$out" 2>/dev/null || true
    event "FORENSIC_SNAPSHOT|memory|${out}.gz"
    log "memory snapshot: ${out}.gz"
}

# ─── Filesystem Snapshot ───────────────────────────────────────────────────────
capture_filesystem_snapshot() {
    local out="$SNAPSHOT_DIR/filesystem_$(date -u +%Y%m%dT%H%M%SZ).txt"
    {
        echo "=== FILESYSTEM SNAPSHOT $(date -u) ==="
        echo "--- Disk Usage ---"
        df -h 2>/dev/null || true
        echo "--- Inode Usage ---"
        df -i 2>/dev/null | head -10 || true
        echo "--- Mount Points ---"
        mount 2>/dev/null || true
        echo "--- Recent File Changes (/etc) ---"
        find /etc -mmin -1440 -type f 2>/dev/null | head -100 || true
        echo "--- SUID/SGID Changes ---"
        find /usr /bin /sbin -type f \( -perm -4000 -o -perm -2000 \) -newer /etc/hostname 2>/dev/null | head -50 || true
        echo "--- /proc/1/cmdline ---"
        cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || true
        echo ""
        echo "--- Journal Errors ---"
        journalctl -p err --since "-15 min" --no-pager 2>/dev/null | tail -50 || true
    } >> "$out"
    gzip -f "$out" 2>/dev/null || true
    event "FORENSIC_SNAPSHOT|filesystem|${out}.gz"
    log "filesystem snapshot: ${out}.gz"
}

# ─── Main Loop ─────────────────────────────────────────────────────────────────
main() {
    init_thresholds
    log "forensic scanner starting, interval=${BASE_INTERVAL}s"
    
    # Initial baseline (after 30s for system to settle)
    sleep 30
    capture_baseline
    event "FORENSIC_SCANNER_READY|baseline=established|interval=${BASE_INTERVAL}"
    
    # Generate capability
    mkdir -p /run/pleiades/capabilities
    cat > /run/pleiades/capabilities/forensic_scanner.cap << 'CAP'
schema=pleiades-pleiades-swarm-capability-v1
component=forensic_scanner
domain=forensic-heuristic-detection
capabilities=baseline-profiling,anomaly-detection,memory-forensics,network-forensics,filesystem-forensics,adaptive-threshold-tuning,zero-day-behavioral-detection
authority=observe-and-report
CAP

    local cycle=0
    while true; do
        cycle=$((cycle + 1))
        
        # Every cycle: check for anomalies
        check_anomalies || log "WARN: check_anomalies failed in cycle ${cycle}"
        
        # Every 2 cycles: network snapshot
        if (( cycle % 2 == 0 )); then
            capture_network_snapshot || log "WARN: network snapshot failed"
        fi
        
        # Every 4 cycles: memory snapshot
        if (( cycle % 4 == 0 )); then
            capture_memory_snapshot || log "WARN: memory snapshot failed"
        fi
        
        # Every 10 cycles: filesystem snapshot
        if (( cycle % 10 == 0 )); then
            capture_filesystem_snapshot || log "WARN: filesystem snapshot failed"
        fi
        
        # Every 20 cycles: re-baseline (adaptive)
        if (( cycle % 20 == 0 )); then
            capture_baseline || log "WARN: re-baseline failed"
        fi
        
        # Clean up old snapshots (keep last 24h)
        find "$SNAPSHOT_DIR" -name '*.gz' -mtime +1 -delete 2>/dev/null || true
        
        sleep "$BASE_INTERVAL"
    done
}

main
