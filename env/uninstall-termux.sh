#!/data/data/com.termux/files/usr/bin/env bash
# Remove the Pleiades Android edge CLI while preserving queued observations by default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REMOVE_SHELL_HOOK=false
PURGE_STATE=false
CONFIRM_PURGE=false
DRY_RUN=false

usage() {
  cat <<'EOF'
usage: uninstall-termux.sh [OPTIONS]

Options:
  --remove-shell-hook  Remove this checkout's exact environment source line
  --purge-state        Delete recognized local edge state and queued events
  --yes                Confirm destructive --purge-state
  --dry-run            Validate and print intended changes
  -h, --help           Show this help

Default behavior removes only the owned `pleiades` CLI symlink. Durable queue
and identity state are preserved unless both --purge-state and --yes are used.
EOF
}

while (($#)); do
  case "$1" in
    --remove-shell-hook) REMOVE_SHELL_HOOK=true ;;
    --purge-state) PURGE_STATE=true ;;
    --yes) CONFIRM_PURGE=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "uninstall-termux: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# shellcheck source=pleiades-termux-lib.sh
source "$SCRIPT_DIR/pleiades-termux-lib.sh"
pleiades_edge_require_termux

run() {
  if $DRY_RUN; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

CLI_TARGET="${PREFIX}/bin/pleiades"
OWNED_CLI="${REPO_ROOT}/env/pleiades-termux-cli.sh"
if [[ -L "$CLI_TARGET" ]]; then
  ACTUAL_TARGET="$(realpath -m -- "$CLI_TARGET")"
  if [[ "$ACTUAL_TARGET" == "$OWNED_CLI" ]]; then
    run rm -f -- "$CLI_TARGET"
  else
    echo "uninstall-termux: refusing to remove CLI symlink owned by another target: $ACTUAL_TARGET" >&2
    exit 1
  fi
elif [[ -e "$CLI_TARGET" ]]; then
  echo "uninstall-termux: refusing to remove non-symlink CLI path: $CLI_TARGET" >&2
  exit 1
fi

if $REMOVE_SHELL_HOOK; then
  case "${SHELL:-}" in
    *zsh) RC_FILE="${HOME}/.zshrc" ;;
    *) RC_FILE="${HOME}/.bashrc" ;;
  esac
  SOURCE_LINE="source '${REPO_ROOT}/env/pleiades-env.sh'"
  if [[ -f "$RC_FILE" ]] && grep -Fq -- "$SOURCE_LINE" "$RC_FILE"; then
    if $DRY_RUN; then
      echo "[dry-run] remove exact Pleiades source line from ${RC_FILE}"
    else
      TMP_RC="$(mktemp "${RC_FILE}.pleiades.XXXXXX")"
      cleanup_rc() { [[ ! -e "$TMP_RC" ]] || rm -f -- "$TMP_RC"; }
      trap cleanup_rc EXIT INT TERM HUP
      python3 - "$RC_FILE" "$TMP_RC" "$SOURCE_LINE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
needle = sys.argv[3]
lines = source.read_text(encoding="utf-8").splitlines()
result = []
for line in lines:
    if line == needle:
        if result and result[-1] == "# Pleiades Android edge node":
            result.pop()
        continue
    result.append(line)
target.write_text("\n".join(result).rstrip() + "\n", encoding="utf-8")
PY
      chmod --reference="$RC_FILE" "$TMP_RC" 2>/dev/null || chmod 600 "$TMP_RC"
      mv -- "$TMP_RC" "$RC_FILE"
      TMP_RC=""
      trap - EXIT INT TERM HUP
    fi
  fi
fi

if $PURGE_STATE; then
  $CONFIRM_PURGE || {
    echo "uninstall-termux: --purge-state requires --yes because it deletes queued events" >&2
    exit 2
  }
  command -v realpath >/dev/null 2>&1 || {
    echo "uninstall-termux: realpath is required for state purge" >&2
    exit 1
  }
  SAFE_ROOT="$(realpath -m -- "$PLEIADES_ROOT")"
  SAFE_HOME="$(realpath -m -- "$HOME")"
  case "$SAFE_ROOT" in
    "$SAFE_HOME"/*) ;;
    *) echo "uninstall-termux: refusing to purge state outside HOME: $SAFE_ROOT" >&2; exit 1 ;;
  esac
  [[ "$SAFE_ROOT" != "$SAFE_HOME" && "$SAFE_ROOT" != "$PREFIX" && "$SAFE_ROOT" != / ]] || {
    echo "uninstall-termux: refusing unsafe purge root: $SAFE_ROOT" >&2
    exit 1
  }
  [[ -f "$SAFE_ROOT/config/node.json" && -f "$SAFE_ROOT/config/capabilities.json" && -d "$SAFE_ROOT/queue" ]] || {
    echo "uninstall-termux: refusing unrecognized edge-state tree: $SAFE_ROOT" >&2
    exit 1
  }
  run rm -rf -- "$SAFE_ROOT"
fi

cat <<EOF
Pleiades Android edge CLI removal complete.
State: $($PURGE_STATE && echo purged || echo preserved at "$PLEIADES_ROOT")
Shell hook: $($REMOVE_SHELL_HOOK && echo reviewed || echo preserved)
EOF
