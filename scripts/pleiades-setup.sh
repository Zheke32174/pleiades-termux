#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# pleiades-setup.sh — First-run operator setup.
#
# Discovers or prompts for the operator's GitHub identity, creates the
# evidence and dead-drop repos if they don't exist, and writes
# /etc/pleiades/operator.conf so all other Pleiades scripts work
# without any hardcoded usernames.
#
# Usage:
#   bash pleiades-setup.sh            # interactive
#   bash pleiades-setup.sh --dry-run  # show what would be written

set -euo pipefail

CONF_DIR="/etc/pleiades"
CONF_FILE="$CONF_DIR/operator.conf"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log()  { echo "[pleiades-setup] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ----------------------------------------------------------------
# 1. Discover or prompt for GitHub identity
# ----------------------------------------------------------------
log "Detecting GitHub identity..."

OWNER=""
TOKEN=""

if command -v gh &>/dev/null && gh auth status -h github.com &>/dev/null 2>&1; then
    OWNER=$(gh api user --jq .login 2>/dev/null || true)
    TOKEN=$(gh auth token 2>/dev/null || true)
    log "Found gh auth: $OWNER"
fi

if [[ -z "$OWNER" ]]; then
    echo
    echo "GitHub CLI not authenticated. Either:"
    echo "  1. Run: gh auth login   (recommended)"
    echo "  2. Enter details manually below"
    echo
    read -rp "GitHub username: " OWNER
    read -rsp "GitHub personal access token (repo scope): " TOKEN
    echo
fi

[[ -z "$OWNER" ]] && die "No GitHub username provided."

# ----------------------------------------------------------------
# 2. Derive repo names (operator can customise after setup)
# ----------------------------------------------------------------
MAIN_REPO="${OWNER}/pleiades"
EVIDENCE_REPO="${OWNER}/pleiades-evidence"
DEAD_DROP_FILE="dead_drop/signal.json"

log "Operator:       $OWNER"
log "Main repo:      $MAIN_REPO"
log "Evidence repo:  $EVIDENCE_REPO"

# ----------------------------------------------------------------
# 3. Create evidence repo if missing (private, operator-owned)
# ----------------------------------------------------------------
if command -v gh &>/dev/null && [[ -n "$TOKEN" ]]; then
    if ! gh repo view "$EVIDENCE_REPO" &>/dev/null 2>&1; then
        log "Creating private evidence repo: $EVIDENCE_REPO"
        if ! $DRY_RUN; then
            gh repo create "$EVIDENCE_REPO" --private --description "Pleiades evidence archive" \
                || log "WARN: Could not create $EVIDENCE_REPO (may already exist or need permissions)"
        else
            log "[DRY-RUN] Would create private repo $EVIDENCE_REPO"
        fi
    else
        log "Evidence repo already exists: $EVIDENCE_REPO"
    fi
fi

# ----------------------------------------------------------------
# 4. Initialise dead-drop file in main repo if missing
# ----------------------------------------------------------------
if command -v gh &>/dev/null; then
    if ! gh api "repos/${MAIN_REPO}/contents/${DEAD_DROP_FILE}" &>/dev/null 2>&1; then
        log "Initialising dead-drop at $MAIN_REPO/$DEAD_DROP_FILE"
        if ! $DRY_RUN; then
            local_encoded=$(printf '{"status":"ready","ts":%d}' "$(date +%s)" | base64 -w0)
            gh api "repos/${MAIN_REPO}/contents/${DEAD_DROP_FILE}" \
                --method PUT \
                --field message="init: dead drop" \
                --field content="$local_encoded" \
                --silent 2>/dev/null \
                || log "WARN: Could not init dead-drop (repo may not exist yet)"
        else
            log "[DRY-RUN] Would initialise dead-drop file"
        fi
    fi
fi

# ----------------------------------------------------------------
# 5. Write /etc/pleiades/operator.conf
# ----------------------------------------------------------------
CONF_CONTENT="# Pleiades operator configuration — written by pleiades-setup
# Edit to override any value. Do not commit this file to git.
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
log "To re-run after changing GitHub accounts: bash pleiades-setup.sh"
