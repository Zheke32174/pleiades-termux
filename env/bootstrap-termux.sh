#!/data/data/com.termux/files/usr/bin/env bash
# bootstrap-termux.sh — Bootstrap Pleiades for Termux (Android)
#
# Usage:
#   source ./env/pleiades-env.sh
#   bash ./env/bootstrap-termux.sh
#
# This script:
#   1. Sets up the PLEIADES_ROOT directory structure
#   2. Symlinks scripts from the cloned repos
#   3. Generates config files with correct paths
#   4. Installs agent scripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLEIADES_ROOT="${PLEIADES_ROOT:-${HOME}/pleiades}"
PLEIADES_ENV_FILE="${SCRIPT_DIR}/pleiades-env.sh"

log() { echo "[bootstrap-termux] $*"; }
warn() { echo "[bootstrap-termux] WARNING: $*" >&2; }
die() { echo "[bootstrap-termux] ERROR: $*" >&2; exit 1; }

# Source env if not already
if [[ -z "${PLEIADES_SCRIPTS:-}" ]]; then
  [[ -f "$PLEIADES_ENV_FILE" ]] && source "$PLEIADES_ENV_FILE"
fi

log "Bootstrapping Pleiades for Termux at ${PLEIADES_ROOT}"

# Source repos: from PLEIADES_SRC_DIR or default to $HOME/pleiades-review
REVIEW_DIR="${PLEIADES_SRC_DIR:-${HOME}/pleiades-review}"

# ── Create directory structure ───────────────────────────────────────────────
mkdir -p "${PLEIADES_ROOT}"/{scripts,tools,config,data/{backup-manifest,tasks},backups,bin}

# ── Symlink agent scripts from pleiades repo ─────────────────────────────────
if [[ -d "${REVIEW_DIR}/pleiades/root.x86_64/scripts" ]]; then
  for script in "${REVIEW_DIR}/pleiades/root.x86_64/scripts/"*.sh; do
    name="$(basename "$script")"
    target="${PLEIADES_SCRIPTS}/${name}"
    if [[ ! -f "$target" ]]; then
      ln -s "$script" "$target"
      log "Linked script: ${name}"
    fi
  done
  # omnipkg tool
  if [[ -f "${REVIEW_DIR}/pleiades/root.x86_64/scripts/omnipkg" ]]; then
    chmod +x "${REVIEW_DIR}/pleiades/root.x86_64/scripts/omnipkg"
    ln -sf "${REVIEW_DIR}/pleiades/root.x86_64/scripts/omnipkg" "${PLEIADES_ROOT}/bin/omnipkg"
  fi
fi

# ── Symlink host scripts ────────────────────────────────────────────────────
for script_file in \
  pleiades-backup.sh \
  pleiades-factory-tools.sh \
  tm-context.sh \
  setup-agent-tools.sh; do
  src="${REVIEW_DIR}/pleiades/${script_file}"
  dst="${PLEIADES_ROOT}/bin/${script_file}"
  if [[ -f "$src" ]]; then
    chmod +x "$src"
    ln -sf "$src" "$dst"
  fi
done

# ── Generate MCP config with resolved paths ──────────────────────────────────
MCP_CONFIG="${PLEIADES_CONFIG}/pleiades-mcp-config.json"
sed "s|__PLEIADES_ROOT__|${PLEIADES_ROOT}|g" "${SCRIPT_DIR}/pleiades-mcp-config.json.tpl" > "$MCP_CONFIG"
log "Generated MCP config: ${MCP_CONFIG}"

# ── Generate tool manifest ────────────────────────────────────────────────────
TOOL_MANIFEST="${PLEIADES_CONFIG}/tool-manifest.json"
sed "s|__PLEIADES_ROOT__|${PLEIADES_ROOT}|g" "${SCRIPT_DIR}/tool-manifest.json.tpl" > "$TOOL_MANIFEST"
log "Generated tool manifest: ${TOOL_MANIFEST}"

# ── Link pleiades-factory-stack tools bootstrap ──────────────────────────────
FACTORY_BOOTSTRAP="${REVIEW_DIR}/pleiades-factory-stack/bootstrap-tools.sh"
if [[ -f "$FACTORY_BOOTSTRAP" ]]; then
  chmod +x "$FACTORY_BOOTSTRAP"
  ln -sf "$FACTORY_BOOTSTRAP" "${PLEIADES_ROOT}/bin/bootstrap-factory-tools.sh"
  log "Linked factory tools bootstrap"
fi

# ── Create local config override ──────────────────────────────────────────────
LOCAL_CONFIG="${PLEIADES_CONFIG}/local.sh"
if [[ ! -f "$LOCAL_CONFIG" ]]; then
  cat > "$LOCAL_CONFIG" << 'LOCAL'
# local.sh — Local Pleiades overrides (sourced by pleiades-env.sh)
# Set your API keys and local preferences here.
# This file is NOT tracked by git.

# export OPENAI_API_KEY="sk-..."
# export ANTHROPIC_API_KEY="sk-..."
# export GEMINI_API_KEY="..."
LOCAL
  log "Created local config: ${LOCAL_CONFIG}"
fi

# ── Create MCP config template ────────────────────────────────────────────────

# ── Add to shell rc ──────────────────────────────────────────────────────────
RC_CMD="source '${PLEIADES_ENV_FILE}'"
for rc_file in "${HOME}/.zshrc" "${HOME}/.bashrc"; do
  if [[ -f "$rc_file" ]]; then
    if ! grep -q "pleiades-env.sh" "$rc_file" 2>/dev/null; then
      echo "" >> "$rc_file"
      echo "# Pleiades environment" >> "$rc_file"
      echo "${RC_CMD}" >> "$rc_file"
      log "Added pleiades-env source to ${rc_file}"
    fi
  fi
done

# ── Verify ────────────────────────────────────────────────────────────────────
log ""
log "╔══════════════════════════════════════════════════╗"
log "║  Pleiades Termux Bootstrap Complete              ║"
log "╚══════════════════════════════════════════════════╝"
log ""
log "  Root:   ${PLEIADES_ROOT}"
log "  Scripts: ${PLEIADES_SCRIPTS}"
log "  Tools:  ${PLEIADES_TOOLS}"
log "  Config: ${PLEIADES_CONFIG}"
log ""
log "Next steps:"
log "  1. Restart shell or run: source ${PLEIADES_ENV_FILE}"
log "  2. Verify: pleiades_info"
log "  3. Bootstrap factory tools: bash \${PLEIADES_ROOT}/bin/bootstrap-factory-tools.sh"
log "  4. Set API keys in: ${PLEIADES_CONFIG}/local.sh"
log ""
