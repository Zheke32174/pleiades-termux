#!/usr/bin/env bash
# bootstrap-container.sh — Build the Pleiades Gentoo nspawn container from scratch
#
# Works on: bare metal Linux, WSL2, VPS
# Requirements: systemd-nspawn, git, curl, tar, xz
#
# Usage:
#   sudo bash bootstrap-container.sh [--root /custom/path] [--dry-run]

set -euo pipefail

source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_ROOT="${PLEIADES_CONTAINER_ROOT:-${SCRIPT_DIR}/root.x86_64}"
# PLEIADES_REPO: set this to your fork URL, or rely on gh CLI detection below
if [[ -z "${PLEIADES_REPO:-}" ]]; then
    _owner="$(gh api user --jq .login 2>/dev/null || true)"
    PLEIADES_REPO="${_owner:+https://github.com/${_owner}/pleiades.git}"
    PLEIADES_REPO="${PLEIADES_REPO:-https://github.com/Zheke32174/pleiades.git}"
fi
STAGE3_MIRROR="${STAGE3_MIRROR:-https://distfiles.gentoo.org/releases/amd64/autobuilds}"
DRY_RUN=false

for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
    [[ "$arg" == "--root" ]]    && shift && CONTAINER_ROOT="$1"
done

log()  { echo "[pleiades-bootstrap] $*"; }
run()  { $DRY_RUN && echo "[DRY-RUN] $*" || "$@"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Termux guard: check before root/sudo requirements
if [[ "${PLEIADES_ENV:-}" == "termux" ]]; then
    log "Termux environment detected — skipping systemd-nspawn bootstrap"
    log "See pleiades/env/bootstrap-termux.sh for Termux setup"
    exit 0
fi

[[ "${EUID:-$(id -u)}" -ne 0 ]] && die "Run as root"
command -v systemd-nspawn &>/dev/null || die "systemd-nspawn required (install systemd-container)"

# ── Environment detection ────────────────────────────────────────────────────
if grep -qi microsoft /proc/version 2>/dev/null; then
    ENV="wsl"
elif systemd-detect-virt --container -q 2>/dev/null; then
    ENV="container"
else
    ENV="bare_metal"
fi
log "Environment: $ENV"

# ── Stage 3 bootstrap ────────────────────────────────────────────────────────
if [[ ! -d "$CONTAINER_ROOT/usr" ]]; then
    log "Fetching latest Gentoo stage3..."
    TMP_STAGE3="/tmp/_pleiades_stage3_$$"
    run mkdir -p "$TMP_STAGE3"

    if ! $DRY_RUN; then
        STAGE3_PATH=$(curl -fsSL "${STAGE3_MIRROR}/latest-stage3-amd64-systemd.txt" \
            | grep -v '^#' | awk '{print $1}' | head -1)
        [[ -z "$STAGE3_PATH" ]] && die "Could not resolve stage3 path from mirror"

        STAGE3_URL="${STAGE3_MIRROR}/${STAGE3_PATH}"
        log "Downloading: $STAGE3_URL"
        curl -fsSL "$STAGE3_URL" -o "$TMP_STAGE3/stage3.tar.xz"

        run mkdir -p "$CONTAINER_ROOT"
        tar xpf "$TMP_STAGE3/stage3.tar.xz" --xattrs-include='*.*' \
            --numeric-owner -C "$CONTAINER_ROOT"
        rm -rf "$TMP_STAGE3"
        log "Stage3 extracted to $CONTAINER_ROOT"
    fi
else
    log "Container root exists at $CONTAINER_ROOT — skipping stage3 extract"
fi

# ── Clone Pleiades scripts into container ────────────────────────────────────
SCRIPTS_DIR="$CONTAINER_ROOT/scripts"
if [[ ! -d "$SCRIPTS_DIR/.git" ]]; then
    TMP_CLONE="/tmp/_pleiades_clone_$$"
    log "Cloning Pleiades scripts..."
    run git clone --depth=1 "$PLEIADES_REPO" "$TMP_CLONE"
    run cp -r "${TMP_CLONE}/root.x86_64/scripts" "$SCRIPTS_DIR"
    run rm -rf "$TMP_CLONE"
    log "Scripts installed to $SCRIPTS_DIR"
else
    log "Pleiades scripts already present — pull to update: git -C $SCRIPTS_DIR pull"
fi

# ── Install host systemd services ────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for svc in "$REPO_DIR"/systemd/system/*.service; do
    name="$(basename "$svc")"
    dest="/etc/systemd/system/$name"
    if [[ ! -f "$dest" ]]; then
        log "Installing service: $name"
        run cp "$svc" "$dest"
    fi
done

if ! $DRY_RUN; then
    systemctl daemon-reload
fi

# ── WSL: write /etc/wsl.conf boot entry ──────────────────────────────────────
if [[ "$ENV" == "wsl" ]]; then
    WRAPPER="/usr/local/sbin/pleiades-runtime-monitor"
    if [[ ! -f /etc/wsl.conf ]] || ! grep -q "pleiades-runtime-monitor" /etc/wsl.conf; then
        log "Adding WSL boot entry..."
        if ! $DRY_RUN; then
            printf '\n[boot]\ncommand=%s\n' "$WRAPPER" >> /etc/wsl.conf
        fi
        log "NOTE: Run 'wsl --shutdown' then restart WSL to activate"
    fi
fi

# ── First-run operator setup ─────────────────────────────────────────────────
log ""
log "Container bootstrapped at: $CONTAINER_ROOT"
log ""
log "Next steps:"
log "  1. Authenticate GitHub CLI:   gh auth login"
log "  2. Configure operator:        sudo bash $SCRIPTS_DIR/pleiades-setup.sh"
log "  3. Start container:           bash $REPO_DIR/install-scripts/gentoo-up.sh"
log "  4. Shell into container:      bash $REPO_DIR/install-scripts/gentoo-shell.sh"
