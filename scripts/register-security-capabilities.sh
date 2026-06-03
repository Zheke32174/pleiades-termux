#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# register-security-capabilities.sh — register all 32 security baseline tools
# Task #20: Wire security tools into Pleiades Team capability registry
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLEIADES_CONTAINER_ROOT="${PLEIADES_CONTAINER_ROOT:-$(dirname "$SCRIPT_DIR")}"
PLEIADES_REPO_ROOT="${PLEIADES_REPO_ROOT:-$(dirname "$PLEIADES_CONTAINER_ROOT")}"
LOG_TAG="sec-caps"; log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
CAP_DIR="/run/pleiades/capabilities"
BASELINE="${PLEIADES_REPO_ROOT}/security-baseline.json"
mkdir -p "$CAP_DIR"

[[ -f "$BASELINE" ]] || { log "ERROR: $BASELINE not found — run task #17 first"; exit 1; }

# Domain → authority mapping
declare -A AUTHORITY=(
    ["cryptography"]="policy-gated"
    ["forensics"]="policy-gated"
    ["network"]="policy-gated"
    ["firewall"]="owner-only"
    ["vpn"]="policy-gated"
    ["anonymity"]="policy-gated"
    ["ids"]="policy-gated"
    ["offensive"]="owner-only"
    ["hardening"]="policy-gated"
    ["re"]="policy-gated"
)

# Parse JSON and write .cap files
python3 - << PYEOF
import json, os, time
from pathlib import Path

baseline = json.loads(Path("$BASELINE").read_text())
cap_dir = Path("$CAP_DIR")
cap_dir.mkdir(parents=True, exist_ok=True)
authority_map = {
    "cryptography": "policy-gated",
    "forensics":    "policy-gated",
    "network":      "policy-gated",
    "firewall":     "owner-only",
    "vpn":          "policy-gated",
    "anonymity":    "policy-gated",
    "ids":          "policy-gated",
    "offensive":    "owner-only",
    "hardening":    "policy-gated",
    "re":           "policy-gated",
}

registered = 0
for tool in baseline["atoms"]:
    name = tool["binary"].replace("-", "_").replace("+", "p")
    cat = tool["category"]
    cap_file = cap_dir / f"{name}.cap"
    binary_path = os.popen(f"command -v {tool['binary']} 2>/dev/null").read().strip()
    cap_file.write_text(
        f"schema=pleiades-pleiades-swarm-capability-v1\n"
        f"component={name}\n"
        f"domain={cat}\n"
        f"capabilities={tool['binary']}_exec\n"
        f"authority={authority_map.get(cat, 'policy-gated')}\n"
        f"atom={tool['atom']}\n"
        f"binary={binary_path or 'not_installed'}\n"
        f"desc={tool['desc']}\n"
        f"updated_utc={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n"
    )
    registered += 1

print(f"Registered {registered} capability files in {cap_dir}")
PYEOF

# purplectl domain shortcuts
PURPLECTL_PLUGIN="/run/pleiades/purplectl-plugins/security-tools.sh"
mkdir -p "$(dirname "$PURPLECTL_PLUGIN")"
cat > "$PURPLECTL_PLUGIN" << 'PLUGIN'
#!/usr/bin/env bash
# purplectl plugin: security-tools
# Usage: purplectl <domain> <tool> [args...]
_check_policy() {
    local auth="$1"
    if [[ "$auth" == "owner-only" ]]; then
        [[ "$(id -u)" == "0" ]] || { echo "ERROR: owner-only tool — must run as root" >&2; exit 1; }
    fi
}
security_tool_cmd() {
    local domain="${1:-}"; shift || true
    local tool="${1:-}"; shift || true
    [[ -z "$domain" || -z "$tool" ]] && { echo "Usage: purplectl <crypto|forensics|network|offensive|re> <tool> [args]" >&2; exit 1; }
    [[ "$domain" == "offensive" ]] && _check_policy "owner-only"
    command -v "$tool" &>/dev/null || { echo "purplectl: $tool not installed (emerge ${domain}/${tool})" >&2; exit 1; }
    exec "$tool" "$@"
}
security_tool_cmd "$@"
PLUGIN
chmod +x "$PURPLECTL_PLUGIN"

log "Security capabilities registered. Plugin: $PURPLECTL_PLUGIN"
log "List capabilities: ls $CAP_DIR/*.cap | wc -l"
