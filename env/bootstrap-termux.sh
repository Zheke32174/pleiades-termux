#!/data/data/com.termux/files/usr/bin/env bash
# Bootstrap the constrained Pleiades Android/Termux edge node.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SHELL_HOOK=false
DRY_RUN=false

usage() {
  cat <<'USAGE'
usage: bootstrap-termux.sh [--install-shell-hook] [--dry-run]

Initializes private edge-node state and installs the `pleiades` CLI shim.
It does not install desktop/server agents, fake system services, containers,
API keys, or third-party research tools.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-shell-hook) INSTALL_SHELL_HOOK=true ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "bootstrap-termux: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# shellcheck source=pleiades-termux-lib.sh
source "${SCRIPT_DIR}/pleiades-termux-lib.sh"
pleiades_edge_require_termux
command -v python3 >/dev/null 2>&1 || {
  echo "bootstrap-termux: python3 is required (pkg install python)" >&2
  exit 1
}

run() {
  if $DRY_RUN; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run pleiades_edge_mkdirs
run python3 "${REPO_ROOT}/bin/pleiades-edge.py" init

CLI_TARGET="${PREFIX}/bin/pleiades"
if $DRY_RUN; then
  echo "[dry-run] ln -sfn ${REPO_ROOT}/env/pleiades-termux-cli.sh ${CLI_TARGET}"
else
  chmod +x "${REPO_ROOT}/env/pleiades-termux-cli.sh" "${REPO_ROOT}/bin/pleiades-edge.py"
  ln -sfn "${REPO_ROOT}/env/pleiades-termux-cli.sh" "${CLI_TARGET}"
fi

if $INSTALL_SHELL_HOOK; then
  case "${SHELL:-}" in
    *zsh) RC_FILE="${HOME}/.zshrc" ;;
    *) RC_FILE="${HOME}/.bashrc" ;;
  esac
  SOURCE_LINE="source '${REPO_ROOT}/env/pleiades-env.sh'"
  if $DRY_RUN; then
    echo "[dry-run] append environment source to ${RC_FILE} when absent"
  elif ! grep -Fq -- "$SOURCE_LINE" "$RC_FILE" 2>/dev/null; then
    printf '\n# Pleiades Android edge node\n%s\n' "$SOURCE_LINE" >> "$RC_FILE"
  fi
fi

cat <<EOF
Pleiades Android edge node initialized.

Runtime:     ${PLEIADES_ROOT}
Queue:       ${PLEIADES_QUEUE}
CLI:         ${CLI_TARGET}
Authority:   none (observation and local queue only)

Run: pleiades doctor
EOF
