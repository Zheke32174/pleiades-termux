#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# pleiades-operator.sh — Operator identity discovery library.
# Source this file; do NOT execute it directly.
#
# Resolves PLEIADES_REPO_OWNER and PLEIADES_GITHUB_TOKEN for whichever
# operator has this system installed. Works on any machine, any account.
#
# Resolution order:
#   1. gh CLI auth  (preferred — whoever ran `gh auth login` IS the operator)
#   2. /etc/pleiades/operator.conf  (written by pleiades-setup on first install)
#   3. Environment variables already exported by the caller
#
# On success sets:
#   PLEIADES_REPO_OWNER     — GitHub username of the operator
#   PLEIADES_GITHUB_TOKEN   — GitHub PAT/OAuth token
#   PLEIADES_MAIN_REPO      — operator/pleiades  (overridable in conf)
#   PLEIADES_EVIDENCE_REPO  — operator/pleiades-evidence  (overridable in conf)
#   PLEIADES_DEAD_DROP_FILE — dead_drop/signal.json  (overridable in conf)
#   PLEIADES_CONTAINER_ROOT — path to root.x86_64/ (derived from script location)
#   PLEIADES_REPO_ROOT      — path to pleiades repo root (derived from script location)
#
# All path vars are overridable via environment before sourcing.
#
# On failure: prints error to stderr and returns 1

_pleiades_load_operator() {
    local conf="/etc/pleiades/operator.conf"

    # 1. Auto-discover via gh CLI
    if command -v gh &>/dev/null && gh auth status -h github.com &>/dev/null 2>&1; then
        PLEIADES_REPO_OWNER="${PLEIADES_REPO_OWNER:-$(gh api user --jq .login 2>/dev/null)}"
        PLEIADES_GITHUB_TOKEN="${PLEIADES_GITHUB_TOKEN:-$(gh auth token 2>/dev/null)}"
    fi

    # 2. Config file overrides / fills gaps
    if [[ -f "$conf" ]]; then
        # shellcheck source=/dev/null
        source "$conf"
    fi

    # 3. Validate — no owner means we cannot continue
    if [[ -z "${PLEIADES_REPO_OWNER:-}" ]]; then
        cat >&2 <<'ERR'
ERROR: Operator identity unknown.
  Option A: authenticate the gh CLI:   gh auth login
  Option B: run first-time setup:      bash pleiades-setup.sh
  Option C: export PLEIADES_REPO_OWNER=<your-github-username> before running
ERR
        return 1
    fi

    # 4. Derive repo names from owner (caller can override via conf/env)
    PLEIADES_MAIN_REPO="${PLEIADES_MAIN_REPO:-${PLEIADES_REPO_OWNER}/pleiades}"
    PLEIADES_EVIDENCE_REPO="${PLEIADES_EVIDENCE_REPO:-${PLEIADES_REPO_OWNER}/pleiades-evidence}"
    PLEIADES_DEAD_DROP_FILE="${PLEIADES_DEAD_DROP_FILE:-dead_drop/signal.json}"

    # 5. Derive filesystem roots from this file's location (scripts/ is inside root.x86_64/)
    local _self
    _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PLEIADES_CONTAINER_ROOT="${PLEIADES_CONTAINER_ROOT:-$(dirname "$_self")}"
    PLEIADES_REPO_ROOT="${PLEIADES_REPO_ROOT:-$(dirname "$PLEIADES_CONTAINER_ROOT")}"
}

_pleiades_load_operator
