#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# pleiades-install-tools.sh — clone and integrate operator repos
# Task #12
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/pleiades-operator.sh" || exit 1
LOG_TAG="${PLEIADES_REPO_OWNER:-pleiades}"; log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
BASE="https://github.com/${PLEIADES_REPO_OWNER}"
EXT="${PLEIADES_REPO_ROOT}/external/${PLEIADES_REPO_OWNER}"
TOOLS="${PLEIADES_REPO_ROOT}/tools"
CAP_DIR="/run/pleiades/capabilities"
mkdir -p "$EXT" "$TOOLS" "$CAP_DIR"

clone_or_update() {
    local repo="$1" dest="$2"
    if [[ -d "$dest/.git" ]]; then git -C "$dest" pull --ff-only 2>/dev/null || true
    else git clone --depth=1 "$BASE/$repo.git" "$dest" || log "WARN: clone $repo failed"; fi
}

# Clone all four repos
for repo in alien scandroid Tracendroid underlode; do
    clone_or_update "$repo" "$EXT/$repo"
done

# Merge alien fork improvements into local alien-bsd
if [[ -d "$EXT/alien" ]]; then
    log "Diffing alien fork vs local alien-bsd"
    diff "$EXT/alien/alien-bsd" "${PLEIADES_REPO_ROOT}/alien-bsd" 2>/dev/null \
        >> "$EXT/MERGE_LOG.md" || true
    log "Diff written to MERGE_LOG.md (review and apply manually)"
fi

# Symlink analysis tools into tools/ and register capabilities
for repo in scandroid Tracendroid underlode; do
    [[ -d "$EXT/$repo" ]] && ln -sfn "$EXT/$repo" "$TOOLS/$repo" || true
done

# Register capabilities
declare -A DOMAINS=(["scandroid"]="reverse_engineering" ["Tracendroid"]="forensics" ["underlode"]="reverse_engineering")
for repo in scandroid Tracendroid underlode; do
    {
        echo "schema=pleiades-pleiades-swarm-capability-v1"
        echo "component=${repo,,}"
        echo "domain=${DOMAINS[$repo]}"
        echo "authority=policy-gated"
        echo "path=$TOOLS/$repo"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$CAP_DIR/${repo,,}.cap"
done

log "Operator (${PLEIADES_REPO_OWNER}) integration complete. Review $EXT/MERGE_LOG.md for alien merge."
