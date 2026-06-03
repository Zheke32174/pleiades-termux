#!/data/data/com.termux/files/usr/bin/env bash
# pleiades-termux-lib.sh — Termux compatibility layer for Pleiades
# Source this at the top of any agent script when running in Termux.
#
# Provides:
#   - Writable path mappings for /var/, /run/, /etc/, /usr/local/
#   - Stub functions for systemd/systemctl/sudo/nsenter
#   - Logging and state management helpers

[[ -n "${_PLEIADES_TERMUX_LIB_LOADED:-}" ]] && return 0
_PLEIADES_TERMUX_LIB_LOADED=1

export PLEIADES_ENV="${PLEIADES_ENV:-termux}"

# ── Base directories (configurable) ─────────────────────────────────────────
: "${PLEIADES_RUN_DIR:=${TMPDIR}/pleiades/run}"
: "${PLEIADES_VAR_DIR:=${PREFIX}/var/pleiades}"
: "${PLEIADES_ETC_DIR:=${PLEIADES_CONFIG:-${HOME}/pleiades/config}}"
: "${PLEIADES_USR_LOCAL_DIR:=${PREFIX}/local}"
: "${PLEIADES_LOG_DIR:=${PLEIADES_VAR_DIR}/log}"
: "${PLEIADES_LIB_DIR:=${PLEIADES_VAR_DIR}/lib}"
: "${PLEIADES_STATE_DIR:=${PLEIADES_LIB_DIR}/pleiades-team}"
: "${PLEIADES_PLEIADES_DIR:=${PLEIADES_LIB_DIR}/pleiades}"
: "${PLEIADES_CAP_DIR:=${PLEIADES_RUN_DIR}/capabilities}"
: "${PLEIADES_FIFO:=${PLEIADES_RUN_DIR}/pleiades-nexus_fifo}"

# ── Create writable directory structure ─────────────────────────────────────
_pleiades_mkdirs() {
  mkdir -p \
    "${PLEIADES_RUN_DIR}" \
    "${PLEIADES_LOG_DIR}" \
    "${PLEIADES_LIB_DIR}" \
    "${PLEIADES_STATE_DIR}" \
    "${PLEIADES_PLEIADES_DIR}" \
    "${PLEIADES_CAP_DIR}" \
    "${PLEIADES_ETC_DIR}"
}
_pleiades_mkdirs

# ── Create FIFO if missing ──────────────────────────────────────────────────
if [[ ! -p "${PLEIADES_FIFO}" ]]; then
  mkfifo "${PLEIADES_FIFO}" 2>/dev/null || true
fi

# ── Path resolution helpers ─────────────────────────────────────────────────
pleiades_resolve_run()  { printf '%s' "${PLEIADES_RUN_DIR}/${1}"; }
pleiades_resolve_var()  { printf '%s' "${PLEIADES_VAR_DIR}/${1}"; }
pleiades_resolve_lib()  { printf '%s' "${PLEIADES_LIB_DIR}/${1}"; }
pleiades_resolve_log()  { printf '%s' "${PLEIADES_LOG_DIR}/${1}"; }
pleiades_resolve_state(){ printf '%s' "${PLEIADES_STATE_DIR}/${1}"; }

# ── Logging helper ──────────────────────────────────────────────────────────
pleiades_log() {
  local name="${1:-pleiades}" msg="${2:-}"
  local logfile="${PLEIADES_LOG_DIR}/${name}.log"
  local line="[$(date -u +%H:%M:%S)] [$$] ${msg}"
  echo "${line}" >> "${logfile}"
  echo "${line}"
}

# ── State file helpers ──────────────────────────────────────────────────────
pleiades_write_score() {
  local score="$1" msg="${2:-}"
  echo "${score}" > "${PLEIADES_RUN_DIR}/forensic_score"
  [[ -n "${msg}" ]] && echo "${msg}" >> "${PLEIADES_RUN_DIR}/forensic_anomalies"
}

pleiades_read_score() {
  cat "${PLEIADES_RUN_DIR}/forensic_score" 2>/dev/null || echo 0
}

pleiades_fifo_event() {
  printf '%s\n' "$1" >> "${PLEIADES_FIFO}" 2>/dev/null || true
}

# ── Stub: systemctl (not available in Termux) ───────────────────────────────
systemctl() {
  case "${1:-}" in
    is-active|is-enabled|status)
      echo "inactive" ;;
    is-system-running)
      echo "offline" ;;
    daemon-reload|enable|disable|start|stop|restart|reload)
      return 0 ;;
    list-units|list-unit-files|list-dependencies)
      echo "" ;;
    show)
      echo "" ;;
    *)
      return 1 ;;
  esac
}

# ── Stub: systemd-detect-virt ───────────────────────────────────────────────
systemd-detect-virt() {
  echo "none"
}

# ── Stub: systemd-nspawn ────────────────────────────────────────────────────
systemd-nspawn() {
  echo "[termux-stub] systemd-nspawn not available in Termux" >&2
  return 1
}

# ── Stub: nsenter ───────────────────────────────────────────────────────────
nsenter() {
  echo "[termux-stub] nsenter not available in Termux" >&2
  return 1
}

# ── Stub: machinectl ────────────────────────────────────────────────────────
machinectl() {
  echo "[termux-stub] machinectl not available in Termux" >&2
  return 1
}

# ── Stub: sudo (Termux has no real sudo) ────────────────────────────────────
sudo() {
  if [[ "$1" == "-E" ]]; then shift; fi
  if [[ "$1" == "-u" ]]; then shift 2; fi
  if [[ "$1" == "nsenter" ]]; then
    shift
    # Skip nsenter args
    while [[ "$1" == -* ]]; do shift; done
    # If remaining is bash -c, run it
    if [[ "$1" == "bash" && "$2" == "-c" ]]; then
      shift 2
      bash -c "$@"
    else
      "$@"
    fi
  else
    "$@"
  fi
}

# ── Stub: pgrep with systemd-nspawn filter ──────────────────────────────────
pgrep() {
  if [[ "$*" == *"systemd-nspawn"* ]]; then
    echo ""
    return 1
  fi
  command pgrep "$@"
}
