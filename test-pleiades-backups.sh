#!/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pleiades-backup.sh
source "$ROOT/pleiades-backup.sh"

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

export PURPLE_BACKUP_MANIFEST_DIR="$tmpdir/manifest"
target="$tmpdir/shared.txt"
printf 'known-good\n' > "$target"

run_agent_backup() {
    local agent="$1"
    PURPLE_BACKUP_AGENT="$agent" pleiades_backup_file "$target" "test-${agent}" >/dev/null
}

run_agent_backup codex &
run_agent_backup claude &
run_agent_backup gemini &
run_agent_backup octopus &
wait

count="$(find "$tmpdir" -maxdepth 1 -type f -name 'shared.txt.bak.*' | wc -l | tr -d ' ')"
if [[ "$count" != "4" ]]; then
    echo "FAIL: expected 4 unique backups, got $count" >&2
    find "$tmpdir" -maxdepth 1 -type f -print >&2
    exit 1
fi

while IFS= read -r backup; do
    if ! cmp -s "$target" "$backup"; then
        echo "FAIL: backup content mismatch: $backup" >&2
        exit 1
    fi
done < <(find "$tmpdir" -maxdepth 1 -type f -name 'shared.txt.bak.*' | sort)

manifest_lines="$(wc -l < "$PURPLE_BACKUP_MANIFEST_DIR/manifest.jsonl" | tr -d ' ')"
if [[ "$manifest_lines" != "4" ]]; then
    echo "FAIL: expected 4 manifest entries, got $manifest_lines" >&2
    cat "$PURPLE_BACKUP_MANIFEST_DIR/manifest.jsonl" >&2
    exit 1
fi

echo "PASS: multi-agent backup helper created 4 unique backups and 4 manifest entries"
