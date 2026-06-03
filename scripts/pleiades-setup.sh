#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# pleiades-setup.sh — First-run operator setup.
#
# Public-release safety note:
#   This script records only non-secret local configuration. It does not prompt
#   for, print, export, or store GitHub tokens or passwords. Use `gh auth login`
#   for GitHub operations and let the GitHub CLI manage credentials.
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

# ----------------------------------------------------------------
# 1. Discover or prompt for GitHub identity — username only
# ----------------------------------------------------------------
log "Detecting GitHub identity..."

OWNER=""

if command -v gh &>/dev/null && gh auth status -h github.com &>/dev/null 2>&1; then
    OWNER=$(gh api user --jq .login 2>/dev/null || true)
    [[ -n "$OWNER" ]] && log "Found gh auth user: $OWNER"
fi

if [[ -z "$OWNER" ]]; then
    echo
    echo "GitHub CLI user was not detected. Either:"
    echo "  1. Run: gh auth login   (recommended)"
    echo "  2. Enter your GitHub username below"
    echo
    read -rp "GitHub username: " OWNER
fi

[[ -z "$OWNER" ]] && die "No GitHub username provided."

# ----------------------------------------------------------------
# 2. Derive repo names (operator can customize after setup)
# ----------------------------------------------------------------
MAIN_REPO="${OWNER}/pleiades"
EVIDENCE_REPO="${OWNER}/pleiades-evidence"
DEAD_DROP_FILE="dead_drop/signal.json"

log "Operator:       $OWNER"
log "Main repo:      $MAIN_REPO"
log "Evidence repo:  $EVIDENCE_REPO"

# ----------------------------------------------------------------
# 3. Optional GitHub repo initialization via gh only
# ----------------------------------------------------------------
if command -v gh &>/dev/null && gh auth status -h github.com &>/dev/null 2>&1; then
    if ! gh repo view "$EVIDENCE_REPO" &>/dev/null 2>&1; then
        log "Evidence repo not found: $EVIDENCE_REPO"
        log "Skipping automatic repo creation in public-release mode."
        log "Create it manually if desired: gh repo create '$EVIDENCE_REPO' --private"
    else
        log "Evidence repo already exists: $EVIDENCE_REPO"
    fi

    if ! gh api "repos/${MAIN_REPO}/contents/${DEAD_DROP_FILE}" &>/dev/null 2>&1; then
        log "Dead-drop file not found: $MAIN_REPO/$DEAD_DROP_FILE"
        log "Skipping automatic dead-drop initialization in public-release mode."
    fi
fi

# ----------------------------------------------------------------
# 4. Write local operator.conf — no secrets
# ----------------------------------------------------------------
CONF_CONTENT="# Pleiades operator configuration — written by pleiades-setup
# This file must contain non-secret local settings only. Do not commit it.
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
log "Setup complete. Pleiades scripts will now run as operator: $OWNER"
log "To re-run after changing GitHub accounts: bash pleiades-setup.sh"
