#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# pleiades-operator.sh — Operator identity discovery library.
# Source this file; do NOT execute it directly.
#
# Public-release safety note:
#   This file resolves the operator's GitHub username only. It deliberately does
#   not export `gh auth token` or request/store a personal access token. Callers
#   that need GitHub access should invoke `gh` directly and let GitHub CLI manage
#   credentials in its own protected store.
#
# Resolution order:
#   1. gh CLI auth  (preferred — whoever ran `gh auth login` IS the operator)
#   2. Termux/local config file at $PREFIX/etc/pleiades/operator.conf
#   3. Environment variables already exported by the caller
#
# On success sets:
#   PLEIADES_REPO_OWNER     — GitHub username of the operator
#   PLEIADES_MAIN_REPO      — operator/pleiades  (overridable in conf)
#   PLEIADES_EVIDENCE_REPO  — operator/pleiades-evidence  (overridable in conf)
#   PLEIADES_DEAD_DROP_FILE — dead_drop/signal.json  (overridable in conf)
#   PLEIADES_CONTAINER_ROOT — path to the container/adapted root
#   PLEIADES_REPO_ROOT      — path to pleiades repo root
#
# On failure: prints error to stderr and returns 1

_pleiades_load_operator() {
    local conf="${PLEIADES_OPERATOR_CONF:-${PREFIX:-/data/data/com.termux/files/usr}/etc/pleiades/operator.conf}"

    # 1. Auto-discover via gh CLI without exporting tokens.
    if command -v gh &>/dev/null && gh auth status -h github.com &>/dev/null 2>&1; then
        PLEIADES_REPO_OWNER="${PLEIADES_REPO_OWNER:-$(gh api user --jq .login 2>/dev/null || true)}"
    fi

    # 2. Config file overrides / fills gaps. Config must not contain secrets.
    if [[ -f "$conf" ]]; then
        # shellcheck source=/dev/null
        source "$conf"
    fi

    # 3. Validate — no owner means we cannot continue.
    if [[ -z "${PLEIADES_REPO_OWNER:-}" ]]; then
        cat >&2 <<'ERR'
ERROR: Operator identity unknown.
  Option A: authenticate the GitHub CLI: gh auth login
  Option B: run first-time setup:          bash pleiades-setup.sh
  Option C: export PLEIADES_REPO_OWNER=<your-github-username> before running
ERR
        return 1
    fi

    # 4. Derive repo names from owner; callers can override via conf/env.
    PLEIADES_MAIN_REPO="${PLEIADES_MAIN_REPO:-${PLEIADES_REPO_OWNER}/pleiades}"
    PLEIADES_EVIDENCE_REPO="${PLEIADES_EVIDENCE_REPO:-${PLEIADES_REPO_OWNER}/pleiades-evidence}"
    PLEIADES_DEAD_DROP_FILE="${PLEIADES_DEAD_DROP_FILE:-dead_drop/signal.json}"

    # 5. Derive filesystem roots from this file's location.
    local _self
    _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PLEIADES_CONTAINER_ROOT="${PLEIADES_CONTAINER_ROOT:-$(dirname "$_self")}"
    PLEIADES_REPO_ROOT="${PLEIADES_REPO_ROOT:-$(dirname "$PLEIADES_CONTAINER_ROOT")}"
}

_pleiades_load_operator
