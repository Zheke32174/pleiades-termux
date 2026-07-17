#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

ADAPTER_ROOT="${PLEIADES_FACTORY_STACK_TERMUX_ROOT:-${HOME}/src/pleiades-factory-stack-termux}"
ADAPTER="${ADAPTER_ROOT}/scripts/pleiades-factory-tools.sh"

if [[ ! -x "$ADAPTER" ]]; then
  cat >&2 <<EOF
pleiades-factory-tools: canonical Termux adapter not found.

Expected: ${ADAPTER}
Set PLEIADES_FACTORY_STACK_TERMUX_ROOT to the checked-out
pleiades-factory-stack-termux repository.

This edge repository no longer carries a second hardcoded tool list or directly
executes unreviewed third-party source.
EOF
  exit 69
fi

exec "$ADAPTER" "$@"
