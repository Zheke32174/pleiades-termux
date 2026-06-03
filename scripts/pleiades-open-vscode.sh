#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# Launch VS Code with the pleiades workspace from WSL
# Run this from WSL to open the pleiades ecosystem workspace in VS Code.

_detect_win_user() {
    cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r' || echo ""
}
_detect_vscode_bin() {
    local win_user; win_user="$(_detect_win_user)"
    local candidates=(
        "${PLEIADES_VSCODE_BIN:-}"
        "/mnt/c/Users/${win_user}/AppData/Local/Programs/Microsoft VS Code Insiders/bin/code-insiders"
        "/mnt/c/Users/${win_user}/AppData/Local/Programs/Microsoft VS Code/bin/code"
        "$(command -v code-insiders 2>/dev/null || true)"
        "$(command -v code 2>/dev/null || true)"
    )
    for c in "${candidates[@]}"; do
        [[ -n "$c" && -x "$c" ]] && { echo "$c"; return; }
    done
    echo ""
}

WIN_USER="$(_detect_win_user)"
VSCODE="$(_detect_vscode_bin)"
WORKSPACE="${PLEIADES_VSCODE_WORKSPACE:-/mnt/c/Users/${WIN_USER}/AppData/Roaming/pleiades-workspace/pleiades-ecosystem.code-workspace}"

if [[ -z "$VSCODE" ]]; then
    echo "Error: VS Code not found. Install VS Code or set PLEIADES_VSCODE_BIN to its path."
    exit 1
fi

if [[ -f "$WORKSPACE" ]]; then
    echo "Opening $WORKSPACE in VS Code..."
    "$VSCODE" "$WORKSPACE" --new-window
    echo "VS Code launched."
else
    echo "Workspace not found at $WORKSPACE"
    echo "Run pleiades-vscode-bridge.sh setup first to generate it, or set PLEIADES_VSCODE_WORKSPACE."
    exit 1
fi
