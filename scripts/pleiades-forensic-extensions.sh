#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# ==============================================================================
# pleiades-forensic-extensions.sh — Extended forensic checks
#
# Adds chkrootkit, unhide, and pspy scanning to the existing forensic scanner.
# Called by pleiades-forensic-scanner.sh, outputs anomaly lines to FIFO.
# All tools are /host aware — uses /host/proc where applicable.
# ==============================================================================

set -uo pipefail

SCORE_FILE="${1:-/run/pleiades/forensic_score}"
ANOMALY_FILE="${2:-/run/pleiades/forensic_anomalies}"
FIFO="/run/pleiades/pleiades-nexus_fifo"
SCORE=0
ANOMALIES=()

log_anomaly() {
    local msg="FORENSIC_EXT|$1|$(date +%s)"
    ANOMALIES+=("$msg")
    printf '%s\n' "$msg" >> "$FIFO" 2>/dev/null || true
    echo "$msg"
    SCORE=$((SCORE + ${2:-5}))
}

# ─── chkrootkit ────────────────────────────────────────────────────────────────
run_chkrootkit() {
    if command -v chkrootkit &>/dev/null; then
        local output
        output=$(chkrootkit -q 2>/dev/null) || true
        if [[ -n "$output" ]]; then
            log_anomaly "CHKROOTKIT: suspicious entries found — ${output:0:200}" 15
        fi
    fi
}

# ─── unhide ─────────────────────────────────────────────────────────────────────
run_unhide() {
    if command -v unhide &>/dev/null; then
        local output
        output=$(timeout 15 unhide proc 2>/dev/null | grep -i "hidden\|found\|suspicious" | head -5) || true
        if [[ -n "$output" ]]; then
            log_anomaly "UNHIDE: hidden processes — ${output:0:200}" 20
        fi
    fi
}

# ─── pspy (process monitor — brief capture) ────────────────────────────────────
run_pspy() {
    if command -v pspy &>/dev/null; then
        # Run pspy for 10 seconds, capture new process creation
        local pspy_out
        pspy_out=$(timeout 10 pspy -p /host/proc 2>/dev/null | grep -i "exec\|fork\|cmd" | head -10) || true
        if [[ -n "$pspy_out" ]]; then
            # Check for suspicious commands
            if echo "$pspy_out" | grep -qiE "nc -e|bash -i|/dev/tcp|chmod \+s|passwd|useradd|adduser"; then
                log_anomaly "PSPY_SUSPICIOUS: suspicious process activity" 25
            fi
        fi
    fi
}

# ─── auditd log check ──────────────────────────────────────────────────────────
run_audit_check() {
    if command -v ausearch &>/dev/null && [[ -d /var/log/audit ]]; then
        local suspicious
        suspicious=$(timeout 10 ausearch -ts recent -m USER_LOGIN,USER_AUTH,CRED_REFR 2>/dev/null | grep -i "fail" | tail -20) || true
        if [[ -n "$suspicious" ]]; then
            log_anomaly "AUDIT_FAIL: recent authentication failures detected" 10
        fi
    fi
}

# ─── Main ──────────────────────────────────────────────────────────────────────
run_chkrootkit
run_unhide
run_pspy
run_audit_check

# Append to anomaly log
if [[ $SCORE -gt 0 ]]; then
    {
        for a in "${ANOMALIES[@]}"; do
            echo "$a"
        done
        echo "FORENSIC_EXT_SCORE:$SCORE"
    } >> "$ANOMALY_FILE" 2>/dev/null || true
    
    # Initialize state
    cur=0
    [[ -f "$SCORE_FILE" ]] && cur=$(cat "$SCORE_FILE")
    echo $((cur + SCORE)) > "$SCORE_FILE"
fi

echo "FORENSIC_EXT: score=$SCORE anomalies=${#ANOMALIES[@]}"
exit 0
