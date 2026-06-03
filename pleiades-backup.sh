#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# Shared backup helper for Pleiades project scripts and CLI harnesses.
# Usage: source this file, then call pleiades_backup_file /path/to/file [reason]

pleiades_backup_agent() {
    local agent="${PLEIADES_BACKUP_AGENT:-${CODEX_AGENT_NAME:-${CLAUDE_AGENT_NAME:-agent}}}"
    agent="${agent//[^A-Za-z0-9_.-]/_}"
    [[ -n "$agent" ]] || agent="agent"
    printf '%s' "$agent"
}

pleiades_backup_manifest_dir() {
    printf '%s' "${PLEIADES_BACKUP_MANIFEST_DIR:-${PLEIADES_ROOT:-${HOME}/pleiades}/data/backup-manifest}"
}

pleiades_backup_file() {
    local file="$1"
    local reason="${2:-manual-change}"
    local agent ts base candidate i manifest_dir manifest tmp

    [[ -e "$file" ]] || return 0
    [[ -f "$file" || -L "$file" ]] || {
        printf 'pleiades-backup: refusing non-file path: %s\n' "$file" >&2
        return 2
    }

    agent="$(pleiades_backup_agent)"
    ts="$(date +%s)"
    base="${file}.bak.${ts}"
    candidate="${base}.${agent}.$$"
    i=0
    while [[ -e "$candidate" ]]; do
        i=$((i + 1))
        candidate="${base}.${agent}.$$.$i"
    done

    cp -a -- "$file" "$candidate"

    manifest_dir="$(pleiades_backup_manifest_dir)"
    mkdir -p "$manifest_dir"
    manifest="${manifest_dir}/manifest.jsonl"
    tmp="${manifest_dir}/.manifest.$$.tmp"
    printf '{"timestamp":"%s","agent":"%s","pid":%s,"source":"%s","backup":"%s","reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$agent" \
        "$$" \
        "$file" \
        "$candidate" \
        "${reason//\"/\\\"}" > "$tmp"
    cat "$tmp" >> "$manifest"
    rm -f "$tmp"

    printf '%s\n' "$candidate"
}
