#!/data/data/com.termux/files/usr/bin/env bash
# pleiades — Pleiades CLI for Termux
set -euo pipefail

PLEIADES_ROOT="${PLEIADES_ROOT:-${HOME}/pleiades}"

case "${1:-}" in
  info|status)
    echo "Pleiades (Termux)"
    echo "  Root:      ${PLEIADES_ROOT}"
    echo "  Scripts:   ${PLEIADES_SCRIPTS:-${PLEIADES_ROOT}/scripts}"
    echo "  Tools:     ${PLEIADES_TOOLS:-${PLEIADES_ROOT}/tools}"
    echo "  Config:    ${PLEIADES_CONFIG:-${PLEIADES_ROOT}/config}"
    echo "  Backups:   ${PLEIADES_BACKUP_DIR:-${PLEIADES_ROOT}/backups}"
    echo ""
    echo "Agent scripts:"
    for s in "${PLEIADES_SCRIPTS:-${PLEIADES_ROOT}/scripts}"/*.sh; do
      name="$(basename "$s" .sh)"
      echo "  - ${name} ($(wc -l < "$s") lines)"
    done 2>/dev/null || echo "  (none linked yet)"
    ;;
  tools)
    echo "Factory tools (${PLEIADES_TOOLS:-${PLEIADES_ROOT}/tools}):"
    for d in "${PLEIADES_TOOLS:-${PLEIADES_ROOT}/tools}"/*/; do
      name="$(basename "$d")"
      if [[ -d "${d}/.git" ]]; then
        head="$(git -C "$d" log -1 --format='%h' 2>/dev/null || echo '?')"
        echo "  - ${name} @ ${head}"
      else
        echo "  - ${name} (not cloned)"
      fi
    done 2>/dev/null || echo "  (no tools directory)"
    ;;
  source)
    echo "source ${PLEIADES_ROOT}/env/pleiades-env.sh"
    ;;
  help|--help|-h)
    echo "Usage: pleiades <command>"
    echo "  info     show environment status"
    echo "  tools    list cloned factory tools"
    echo "  source   print source command for shell rc"
    ;;
  *)
    if [[ -n "${1:-}" ]]; then
      echo "Unknown command: $1" >&2
    fi
    echo "Usage: pleiades <command> (try: pleiades info)" >&2
    exit 1
    ;;
esac
