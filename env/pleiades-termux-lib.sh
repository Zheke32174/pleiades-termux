#!/usr/bin/env bash
# Safe helper library for the Pleiades Android/Termux edge node.
#
# This library intentionally does not override systemctl, sudo, pgrep,
# nsenter, machinectl, or systemd-nspawn. Pretending those facilities exist
# hides failures and can cause desktop/server scripts to run in the wrong
# authority domain.

[[ -n "${_PLEIADES_TERMUX_LIB_LOADED:-}" ]] && return 0
_PLEIADES_TERMUX_LIB_LOADED=1

export PLEIADES_ENV="android-termux-edge"
: "${PLEIADES_ROOT:=${HOME}/.local/share/pleiades-edge}"
: "${PLEIADES_CONFIG:=${PLEIADES_ROOT}/config}"
: "${PLEIADES_STATE:=${PLEIADES_ROOT}/state}"
: "${PLEIADES_QUEUE:=${PLEIADES_ROOT}/queue}"
: "${PLEIADES_EXPORTS:=${PLEIADES_ROOT}/exports}"
: "${PLEIADES_TOOLS:=${PLEIADES_ROOT}/tools}"

export PLEIADES_ROOT PLEIADES_CONFIG PLEIADES_STATE PLEIADES_QUEUE PLEIADES_EXPORTS PLEIADES_TOOLS

pleiades_edge_mkdirs() {
  umask 077
  mkdir -p -- \
    "${PLEIADES_ROOT}" \
    "${PLEIADES_CONFIG}" \
    "${PLEIADES_STATE}" \
    "${PLEIADES_QUEUE}" \
    "${PLEIADES_EXPORTS}" \
    "${PLEIADES_TOOLS}"
  chmod 700 -- "${PLEIADES_ROOT}" "${PLEIADES_CONFIG}" "${PLEIADES_STATE}" \
    "${PLEIADES_QUEUE}" "${PLEIADES_EXPORTS}" "${PLEIADES_TOOLS}" 2>/dev/null || true
}

pleiades_edge_require_termux() {
  case "${PREFIX:-}" in
    *com.termux*/usr|*/usr) return 0 ;;
    *)
      echo "pleiades-edge: this adapter is intended for Termux on Android" >&2
      return 64
      ;;
  esac
}

pleiades_edge_cli() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  exec python3 "${repo_root}/bin/pleiades-edge.py" "$@"
}

pleiades_edge_mkdirs
