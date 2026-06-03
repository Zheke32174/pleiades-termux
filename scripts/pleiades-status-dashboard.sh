#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# Quick pleiades ecosystem status from host
# Usage: pleiades-status.sh [--watch]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLEIADES_CONTAINER_ROOT="${PLEIADES_CONTAINER_ROOT:-$(dirname "$SCRIPT_DIR")}"
PID_FILE="${PLEIADES_CONTAINER_ROOT}/run/pleiades/container_pid"
if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
else
    PID=$(pgrep -f 'systemd-nspawn.*gentoo-undercity' 2>/dev/null | head -1)
fi

if [[ -z "$PID" ]]; then
    echo "Container not running"
    exit 1
fi

echo "=== Purple Ecosystem Status ==="
echo "Container PID: $PID"
echo ""

# Services
echo "--- Services ---"
sudo nsenter -t $PID -m -u -i -n -p -- systemctl list-units --type=service --state=running --no-legend 2>/dev/null | grep -E 'pleiades|atlas|taygete|pleiades-nexus|maia|alcyone|electra|little' | awk '{printf "  %-40s %s\n", $1, $3}'

echo ""
echo "--- Forensic Score ---"
SCORE=$(sudo nsenter -t $PID -m -u -i -n -p -- cat /run/pleiades/forensic_score 2>/dev/null || echo "N/A")
echo "  Score: $SCORE"

echo ""
echo "--- Anomalies ---"
sudo nsenter -t $PID -m -u -i -n -p -- cat /run/pleiades/forensic_anomalies 2>/dev/null || echo "  None detected"

echo ""
echo "--- Telemetry Log (last 5) ---"
sudo nsenter -t $PID -m -u -i -n -p -- tail -5 /var/log/pleiades/telemetry-pipeline.log 2>/dev/null || echo "  N/A"

echo ""
echo "--- Baseline ---"
sudo nsenter -t $PID -m -u -i -n -p -- cat /var/lib/pleiades-team/forensic/baseline 2>/dev/null || echo "  N/A"

echo ""
echo "--- Purple Target ---"
sudo nsenter -t $PID -m -u -i -n -p -- systemctl list-dependencies pleiades.target 2>/dev/null | head -20 || echo "  N/A"

if [[ "$1" == "--watch" ]]; then
    echo ""
    echo "Watching forensic score (Ctrl+C to exit)..."
    while true; do
        SCORE=$(sudo nsenter -t $PID -m -u -i -n -p -- cat /run/pleiades/forensic_score 2>/dev/null || echo "?")
        ANOMALIES=$(sudo nsenter -t $PID -m -u -i -n -p -- cat /run/pleiades/forensic_anomalies 2>/dev/null || echo "none")
        echo "[$(date +%H:%M:%S)] Score: $SCORE | Anomalies: $ANOMALIES"
        sleep 10
    done
fi
