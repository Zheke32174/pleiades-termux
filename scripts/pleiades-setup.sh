#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# pleiades-setup.sh — First-run operator setup.
#
# Public-release safe behavior:
#   - discovers the GitHub username through gh CLI when available
#   - optionally prompts only for a username, never for a token
#   - writes non-secret operator config under Termux-safe $PREFIX/etc/pleiades
#   - does not create repos or write dead-drop files automatically
#
# Usage:
#   bash pleiades-setup.sh            # interactive
#   bash pleiades-setup.sh --dry-run  # show what would be written

set -euo pipefail

CONF_DIR="${PLEIADES_CONF_DIR:-${PREFIX:-/data/data/com.termux/files/usr}/etc/pleiades}"
CONF_FILE="$CONF_DIR/operator.conf"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log()  { echo "[pleiades-setup] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

log "Detecting GitHub identity..."

OWNER="${PLEIADES_REPO_OWNER:-}"

if [[ -z "$OWNER" ]] && command -v gh &>/dev/null && gh auth status -h github.com &>/dev/null 2>&1; then
    OWNER=$(gh api user --jq .login 2>/dev/null || true)
    [[ -n "$OWNER" ]] && log "Found gh auth user: $OWNER"
fi

if [[ -z "$OWNER" ]]; then
    echo
    echo "GitHub username is needed to derive default repo names."
    echo "No token is requested or stored by this setup script."
    echo
    read -rp "GitHub username: " OWNER
fi

[[ -z "$OWNER" ]] && die "No GitHub username provided."

MAIN_REPO="${PLEIADES_MAIN_REPO:-${OWNER}/pleiades}"
EVIDENCE_REPO="${PLEIADES_EVIDENCE_REPO:-${OWNER}/pleiades-evidence}"
DEAD_DROP_FILE="${PLEIADES_DEAD_DROP_FILE:-dead_drop/signal.json}"

log "Operator:       $OWNER"
log "Main repo:      $MAIN_REPO"
log "Evidence repo:  $EVIDENCE_REPO"

CONF_CONTENT="# Pleiades operator configuration — written by pleiades-setup
# Edit to override any value. Do not commit this file to git.
# This file must contain no tokens, passwords, or private keys.
PLEIADES_REPO_OWNER=\"${OWNER}\"
PLEIADES_MAIN_REPO=\"${MAIN_REPO}\"
PLEIADES_EVIDENCE_REPO=\"${EVIDENCE_REPO}\"
PLEIADES_DEAD_DROP_FILE=\"${DEAD_DROP_FILE}\"
"

if $DRY_RUN; then
    echo
    echo "--- Would write $CONF_FILE ---"
    echo "$CONF_CONTENT"
else
    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"
    printf '%s' "$CONF_CONTENT" > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    log "Written: $CONF_FILE"
fi

echo
log "Setup complete. All Pleiades scripts will now run as operator: $OWNER"
log "GitHub operations should use gh directly; credentials remain managed by gh."
