#!/usr/bin/env bash
# pleiades-env.sh — Source this to set Pleiades environment for Termux
#
# Usage:  source /path/to/pleiades/env/pleiades-env.sh
#         or symlink to ~/.zshrc / ~/.bashrc

export PLEIADES_ROOT="${PLEIADES_ROOT:-${HOME}/pleiades}"
export PLEIADES_CONTAINER_ROOT="${PLEIADES_CONTAINER_ROOT:-${PLEIADES_ROOT}/rootfs}"
export PLEIADES_SCRIPTS="${PLEIADES_SCRIPTS:-${PLEIADES_ROOT}/scripts}"
export PLEIADES_TOOLS="${PLEIADES_TOOLS:-${PLEIADES_ROOT}/tools}"
export PLEIADES_CONFIG="${PLEIADES_CONFIG:-${PLEIADES_ROOT}/config}"
export PLEIADES_DATA="${PLEIADES_DATA:-${PLEIADES_ROOT}/data}"
export PLEIADES_ENV="${PLEIADES_ENV:-termux}"

export PLEIADES_BACKUP_DIR="${PLEIADES_BACKUP_DIR:-${PLEIADES_ROOT}/backups}"
export PLEIADES_BACKUP_MANIFEST_DIR="${PLEIADES_BACKUP_MANIFEST_DIR:-${PLEIADES_ROOT}/data/backup-manifest}"
export PLEIADES_TASKS_DIR="${PLEIADES_TASKS_DIR:-${PLEIADES_ROOT}/data/tasks}"

export PATH="${PLEIADES_ROOT}/bin:${PLEIADES_SCRIPTS}:${PATH}"

# Termux compatibility library path
export PLEIADES_TERMUX_LIB="${PLEIADES_ROOT}/env/pleiades-termux-lib.sh"

pleiades_info() {
  echo "Pleiades Environment (${PLEIADES_ENV})"
  echo "  Root:       ${PLEIADES_ROOT}"
  echo "  Scripts:    ${PLEIADES_SCRIPTS}"
  echo "  Tools:      ${PLEIADES_TOOLS}"
  echo "  Config:     ${PLEIADES_CONFIG}"
  echo "  Container:  ${PLEIADES_CONTAINER_ROOT}"
}

pleiades_source() {
  local f="${PLEIADES_CONFIG}/${1}"
  [[ -f "$f" ]] && source "$f" || echo "pleiades: warning: ${f} not found" >&2
}

# Load config overrides if present
pleiades_source "local.sh"
