#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# install-ai-agents.sh — install Aider + OpenHands as operator-assist tools
# Task #13: Evaluate and stage AI coding agents
#
# Third-party tools installed by this script (cloned or pip-installed from upstream):
#   Aider         paul-gauthier (Paul Gauthier)  Apache-2.0  https://github.com/paul-gauthier/aider
#   OpenHands     All-Hands-AI                   MIT         https://github.com/All-Hands-AI/OpenHands
#
# No source from either project is vendored or modified here.
# Both are installed from their official upstream sources.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLEIADES_CONTAINER_ROOT="${PLEIADES_CONTAINER_ROOT:-$(dirname "$SCRIPT_DIR")}"
PLEIADES_REPO_ROOT="${PLEIADES_REPO_ROOT:-$(dirname "$PLEIADES_CONTAINER_ROOT")}"

LOG_TAG="ai-agents"
log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

CONF_DIR="/etc/pleiades/ai-agents"
CAP_DIR="/run/pleiades/capabilities"
PLUGIN_DIR="/run/pleiades/purplectl-plugins"
TOOLS_DIR="${PLEIADES_REPO_ROOT}/tools"

# ---------------------------------------------------------------------------
# Subtask 1: Install Aider
# ---------------------------------------------------------------------------
install_aider() {
    log "=== Subtask 1: Install Aider ==="
    mkdir -p "$CONF_DIR"

    if command -v aider &>/dev/null; then
        log "aider already installed: $(aider --version 2>/dev/null | head -1 || echo 'unknown version')"
    else
        if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
            local pip; pip=$(command -v pip3 2>/dev/null || command -v pip)
            log "Installing aider-chat via $pip"
            "$pip" install --quiet aider-chat || die "pip install aider-chat failed"
        elif command -v pipx &>/dev/null; then
            pipx install aider-chat || die "pipx install aider-chat failed"
        else
            die "No pip or pipx found — cannot install Aider"
        fi
    fi

    # Ensure in PATH
    local aider_bin; aider_bin=$(command -v aider 2>/dev/null || true)
    if [[ -z "$aider_bin" ]]; then
        # Try common pip user bin locations
        for d in "$HOME/.local/bin" "/root/.local/bin" "/usr/local/bin"; do
            [[ -x "$d/aider" ]] && { ln -sf "$d/aider" /usr/local/bin/aider; break; }
        done
    fi

    cat > "$CONF_DIR/aider.conf" << 'CONF'
# Aider purple team configuration
# Set ANTHROPIC_API_KEY or OPENAI_API_KEY before use
# Usage: purplectl ai-agent aider <task>

# Default model for purple team work (Claude for RE, GPT-4 for quick patches)
AIDER_MODEL="${AIDER_MODEL:-claude-3-5-sonnet-20241022}"

# Auto-commit is OFF by default in purple team context
AIDER_AUTO_COMMITS=false

# Purple team working directories
AIDER_WATCH_FILES=true
CONF
    log "Aider config written to $CONF_DIR/aider.conf"
}

# ---------------------------------------------------------------------------
# Subtask 2: Verify/stage OpenHands
# ---------------------------------------------------------------------------
stage_openhands() {
    log "=== Subtask 2: Stage OpenHands ==="
    mkdir -p "$TOOLS_DIR"

    local oh_dir="$TOOLS_DIR/OpenHands"
    if [[ -d "$oh_dir" ]]; then
        log "OpenHands found at $oh_dir"
    else
        log "Cloning OpenHands to $oh_dir"
        git clone --depth=1 https://github.com/All-Hands-AI/OpenHands.git "$oh_dir" 2>/dev/null \
            || log "WARN: OpenHands clone failed — stub wrapper only"
    fi

    # Write launcher wrapper
    cat > /usr/local/bin/openhands << WRAPPER
#!/usr/bin/env bash
# openhands — purple team launcher
OH_DIR="${oh_dir}"
if [[ ! -d "\$OH_DIR" ]]; then
    echo "openhands: not installed at \$OH_DIR" >&2
    exit 1
fi
cd "\$OH_DIR"
if [[ -f "pyproject.toml" ]] && command -v poetry &>/dev/null; then
    poetry run python -m openhands "\$@"
elif [[ -f "requirements.txt" ]]; then
    python3 -m openhands "\$@" 2>/dev/null || python3 openhands/main.py "\$@"
else
    echo "openhands: cannot determine launch method in \$OH_DIR" >&2
    exit 1
fi
WRAPPER
    chmod +x /usr/local/bin/openhands

    cat > "$CONF_DIR/openhands.conf" << 'CONF'
# OpenHands purple team configuration
# Requires: ANTHROPIC_API_KEY or LLM_API_KEY
# Usage: purplectl ai-agent openhands <task>

# Default LLM backend
OH_LLM_MODEL="${OH_LLM_MODEL:-claude-3-5-sonnet-20241022}"
OH_LLM_BASE_URL="${OH_LLM_BASE_URL:-}"

# Workspace isolation (each task gets a sandbox)
OH_WORKSPACE_BASE="/var/lib/pleiades-team/openhands"
CONF
    log "OpenHands config written to $CONF_DIR/openhands.conf"
}

# ---------------------------------------------------------------------------
# Subtask 3: purplectl plugin + pleiades-swarm capability registration
# ---------------------------------------------------------------------------
register_capabilities() {
    log "=== Subtask 3: Register pleiades-swarm capabilities ==="
    mkdir -p "$CAP_DIR" "$PLUGIN_DIR"

    # Capability files
    {
        echo "schema=pleiades-pleiades-swarm-capability-v1"
        echo "component=aider"
        echo "domain=operator_assist"
        echo "capabilities=code_edit,re_assist,patch_gen,interactive_coding"
        echo "authority=policy-gated"
        echo "binary=$(command -v aider 2>/dev/null || echo not_installed)"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$CAP_DIR/aider.cap"

    {
        echo "schema=pleiades-pleiades-swarm-capability-v1"
        echo "component=openhands"
        echo "domain=operator_assist"
        echo "capabilities=autonomous_coding,task_execution,multi_step_re"
        echo "authority=policy-gated"
        echo "binary=$(command -v openhands 2>/dev/null || echo /usr/local/bin/openhands)"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$CAP_DIR/openhands.cap"

    # purplectl plugin
    cat > "$PLUGIN_DIR/ai-agents.sh" << 'PLUGIN'
#!/usr/bin/env bash
# purplectl plugin: ai-agents
# Usage: purplectl ai-agent <aider|openhands> [args...]

_ai_agent_usage() {
    echo "Usage: purplectl ai-agent <aider|openhands> [task/args]"
    echo "       purplectl ai-agent aider --help"
    echo "       purplectl ai-agent openhands --help"
}

ai_agent_cmd() {
    local agent="${1:-}"; shift || true
    case "$agent" in
        aider)
            [[ -x "$(command -v aider)" ]] || { echo "aider not installed — run install-ai-agents.sh" >&2; exit 1; }
            exec aider "$@"
            ;;
        openhands)
            [[ -x /usr/local/bin/openhands ]] || { echo "openhands not installed" >&2; exit 1; }
            exec /usr/local/bin/openhands "$@"
            ;;
        *)
            _ai_agent_usage; exit 1 ;;
    esac
}

ai_agent_cmd "$@"
PLUGIN
    chmod +x "$PLUGIN_DIR/ai-agents.sh"
    log "purplectl plugin written to $PLUGIN_DIR/ai-agents.sh"
    log "capability files written to $CAP_DIR/{aider,openhands}.cap"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    log "=== AI agent installer — $(date -u) ==="
    install_aider
    stage_openhands
    register_capabilities
    log ""
    log "=== Installation complete ==="
    log "  aider:      $(command -v aider 2>/dev/null || echo 'NOT FOUND')"
    log "  openhands:  $(command -v openhands 2>/dev/null || echo /usr/local/bin/openhands)"
    log "  plugin:     $PLUGIN_DIR/ai-agents.sh"
    log ""
    log "Test: purplectl ai-agent aider --help"
    log "Requires: ANTHROPIC_API_KEY or OPENAI_API_KEY to be set"
}

main "$@"
