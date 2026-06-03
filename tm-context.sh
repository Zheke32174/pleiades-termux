#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# Task Master context bridge — outputs pending/in-progress task summary for Codex session injection.
# Called by SessionStart hook in ~/.codex/hooks.json.
# This intentionally reads tasks.json directly; the task-master CLI can be slow
# or block on host-bridge I/O, and session startup must stay bounded.

TASKS_FILE="${PLEIADES_TASKS_FILE:-${PLEIADES_ROOT:-${HOME}/pleiades}/data/tasks/tasks.json}"

[[ ! -f "$TASKS_FILE" ]] && exit 0

# Check jq available
command -v jq &>/dev/null || exit 0

# Extract pending and in-progress tasks
SUMMARY="$(jq -r '
  .master.tasks[]
  | select(.status == "pending" or .status == "in-progress")
  | "  [\(.status | ascii_upcase)] #\(.id) [\(.priority)] \(.title)"
' "$TASKS_FILE" 2>/dev/null)"

[[ -z "$SUMMARY" ]] && exit 0

TOTAL_PENDING="$(jq '[.master.tasks[] | select(.status == "pending")] | length' "$TASKS_FILE" 2>/dev/null)"
TOTAL_INPROG="$(jq '[.master.tasks[] | select(.status == "in-progress")] | length' "$TASKS_FILE" 2>/dev/null)"

cat <<EOF
## Task Master — /workspaces/gentoo
Active: ${TOTAL_INPROG} in-progress, ${TOTAL_PENDING} pending

${SUMMARY}

To update: task-master set-status --id=<N> --status=done
Tasks file: ${TASKS_FILE}
EOF
