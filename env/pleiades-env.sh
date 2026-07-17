#!/usr/bin/env bash
# Source this file to expose the Pleiades Android/Termux edge-node CLI.

_PLEIADES_TERMUX_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLEIADES_ENV="android-termux-edge"
export PLEIADES_ROOT="${PLEIADES_ROOT:-${HOME}/.local/share/pleiades-edge}"
export PLEIADES_CONFIG="${PLEIADES_CONFIG:-${PLEIADES_ROOT}/config}"
export PLEIADES_STATE="${PLEIADES_STATE:-${PLEIADES_ROOT}/state}"
export PLEIADES_QUEUE="${PLEIADES_QUEUE:-${PLEIADES_ROOT}/queue}"
export PLEIADES_EXPORTS="${PLEIADES_EXPORTS:-${PLEIADES_ROOT}/exports}"
export PLEIADES_TOOLS="${PLEIADES_TOOLS:-${PLEIADES_ROOT}/tools}"
export PLEIADES_TERMUX_LIB="${_PLEIADES_TERMUX_REPO}/env/pleiades-termux-lib.sh"
export PATH="${_PLEIADES_TERMUX_REPO}/bin:${PATH}"

# Local overrides may change storage paths, but should not contain API keys or
# private SSH material. Use the relevant application's secret store instead.
if [[ -r "${PLEIADES_CONFIG}/local.sh" ]]; then
  # shellcheck source=/dev/null
  source "${PLEIADES_CONFIG}/local.sh"
fi

pleiades_info() {
  python3 "${_PLEIADES_TERMUX_REPO}/bin/pleiades-edge.py" info
}
