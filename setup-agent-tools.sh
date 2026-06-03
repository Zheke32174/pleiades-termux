#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# setup-agent-tools.sh — Run once (as yourself, not as Claude) to wire up
# RTK + JCodeMunch auto-hooks into Claude Code's settings.json.
# Claude cannot self-modify these files; you must run this.
#
# Usage: bash ${PLEIADES_ROOT:-${HOME}/pleiades}/env/../setup-agent-tools.sh
#   or in agent prompt: ! bash setup-agent-tools.sh

set -euo pipefail

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
PLEIADES_ROOT="${PLEIADES_ROOT:-${HOME}/pleiades}"
JCM_DIR="${JCODEMUNCH_HOME:-${PLEIADES_ROOT}/tools/jcodemunch-mcp}"
RTK_HOOK="$HOME/.local/bin/rtk-bash-hook.py"

echo "=== Pleiades Agent Tool Setup ==="

# 1. Write RTK bash hook script
mkdir -p "$(dirname "$RTK_HOOK")"
cat > "$RTK_HOOK" << 'HOOK'
#!/usr/bin/env python3
"""PreToolUse:Bash — rewrites eligible commands through RTK for 60-90% token savings."""
import json, sys, re

RTK_CMDS = {'git','gh','ls','tree','find','grep','diff','docker','kubectl','psql','pnpm','dotnet','aws'}

try:
    data = json.load(sys.stdin)
    cmd = (data.get('command') or data.get('tool_input', {}).get('command', '')).strip()
    first = re.split(r'\s+', re.sub(r'^(sudo\s+|env\s+\S+=\S+\s+)+', '', cmd))[0] if cmd else ''
    if first in RTK_CMDS and not cmd.startswith('rtk '):
        print(json.dumps({"type":"system","content":
            f"RTK: prefix this with `rtk` for 60-90% token reduction. "
            f"Run: rtk {cmd[:120]}"}))
except Exception:
    pass
HOOK
chmod +x "$RTK_HOOK"
echo "[1/4] RTK hook script written to $RTK_HOOK"

# 2. Install jcodemunch into Claude Code (MCP + hooks + CLAUDE.md policy)
if command -v python3 &>/dev/null && [[ -d "$JCM_DIR" ]]; then
    (cd "$JCM_DIR" && python3 -m jcodemunch_mcp install claude-code --yes 2>&1 | tail -5) || \
    (cd "$JCM_DIR" && python3 -m jcodemunch_mcp install claude-code 2>&1 | tail -5) || \
    echo "  jcodemunch install failed — may need interactive approval"
    echo "[2/4] JCodeMunch: install attempted"
else
    echo "[2/4] JCodeMunch: skipped (dir not found: $JCM_DIR)"
fi

# 3. Add RTK PreToolUse:Bash hook to Claude Code settings.json
python3 - << PY
import json, pathlib, sys

p = pathlib.Path('$CLAUDE_SETTINGS')
if not p.exists():
    print("[3/4] Claude settings.json not found, skipping")
    sys.exit(0)

d = json.loads(p.read_text())
hooks = d.setdefault('hooks', {})
pre = hooks.setdefault('PreToolUse', [])

rtk_entry = {
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "python3 $RTK_HOOK", "timeout": 3000}]
}

if not any('rtk' in str(h) for h in pre):
    pre.insert(0, rtk_entry)
    p.write_text(json.dumps(d, indent=2))
    print("[3/4] RTK PreToolUse:Bash hook added to Claude Code settings.json")
else:
    print("[3/4] RTK hook already present in Claude Code settings.json")
PY

# 4. Add jcodemunch MCP to Claude Code settings.json if not already there
python3 - << PY
import json, pathlib, sys

p = pathlib.Path('$CLAUDE_SETTINGS')
if not p.exists():
    print("[4/4] Claude settings.json not found, skipping")
    sys.exit(0)

d = json.loads(p.read_text())
mcp = d.setdefault('mcpServers', {})

if 'jcodemunch' not in mcp:
    mcp['jcodemunch'] = {
        "command": "python3",
        "args": ["-m", "jcodemunch_mcp", "serve"],
        "cwd": "$JCM_DIR"
    }
    p.write_text(json.dumps(d, indent=2))
    print("[4/4] JCodeMunch MCP server added to Claude Code settings.json")
else:
    print("[4/4] JCodeMunch MCP already registered")
PY

echo ""
echo "=== Done. Restart Claude Code / Codex / Gemini for hooks to take effect. ==="
echo "Verify: rtk gain    (should show savings analytics)"
echo "Verify: python3 -m jcodemunch_mcp health (in $JCM_DIR)"
