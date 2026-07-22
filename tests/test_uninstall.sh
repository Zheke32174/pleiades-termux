#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/env/uninstall-termux.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
HOME_DIR="$TMP/home"
PREFIX_DIR="$TMP/com.termux/files/usr"
STATE_DIR="$HOME_DIR/.local/share/pleiades-edge"
mkdir -p "$HOME_DIR" "$PREFIX_DIR/bin" "$STATE_DIR/config" "$STATE_DIR/queue"
printf '{}\n' > "$STATE_DIR/config/node.json"
printf '{}\n' > "$STATE_DIR/config/capabilities.json"
: > "$STATE_DIR/queue/events.jsonl"

SOURCE_LINE="source '$ROOT/env/pleiades-env.sh'"
printf '# before\n# Pleiades Android edge node\n%s\n# after\n' "$SOURCE_LINE" > "$HOME_DIR/.bashrc"
ln -s "$ROOT/env/pleiades-termux-cli.sh" "$PREFIX_DIR/bin/pleiades"

run_uninstall() {
  env HOME="$HOME_DIR" PREFIX="$PREFIX_DIR" SHELL=/bin/bash PLEIADES_ROOT="$STATE_DIR" bash "$SCRIPT" "$@"
}

run_uninstall
[[ ! -e "$PREFIX_DIR/bin/pleiades" ]] || { echo "owned CLI symlink not removed" >&2; exit 1; }
[[ -d "$STATE_DIR" ]] || { echo "state was not preserved" >&2; exit 1; }
grep -Fq "$SOURCE_LINE" "$HOME_DIR/.bashrc"

ln -s "$ROOT/env/pleiades-termux-cli.sh" "$PREFIX_DIR/bin/pleiades"
run_uninstall --remove-shell-hook
[[ ! -e "$PREFIX_DIR/bin/pleiades" ]]
! grep -Fq "$SOURCE_LINE" "$HOME_DIR/.bashrc"
! grep -Fq '# Pleiades Android edge node' "$HOME_DIR/.bashrc"
grep -Fq '# before' "$HOME_DIR/.bashrc"
grep -Fq '# after' "$HOME_DIR/.bashrc"
[[ -d "$STATE_DIR" ]]

if run_uninstall --purge-state > "$TMP/purge-without-confirm.log" 2>&1; then
  echo "purge unexpectedly succeeded without --yes" >&2
  exit 1
fi
grep -Fq 'requires --yes' "$TMP/purge-without-confirm.log"
[[ -d "$STATE_DIR" ]]

run_uninstall --purge-state --yes
[[ ! -e "$STATE_DIR" ]] || { echo "recognized state was not purged" >&2; exit 1; }

mkdir -p "$STATE_DIR/config" "$STATE_DIR/queue"
printf '{}\n' > "$STATE_DIR/config/node.json"
printf '{}\n' > "$STATE_DIR/config/capabilities.json"
ln -s "$TMP/foreign-target" "$PREFIX_DIR/bin/pleiades"
if run_uninstall > "$TMP/foreign.log" 2>&1; then
  echo "foreign CLI symlink unexpectedly removed" >&2
  exit 1
fi
grep -Fq 'owned by another target' "$TMP/foreign.log"
[[ -L "$PREFIX_DIR/bin/pleiades" ]]

printf 'PASS: Termux uninstall ownership and retention policy\n'
