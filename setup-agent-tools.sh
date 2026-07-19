#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
setup-agent-tools.sh has been retired.

The previous script modified Claude Code settings and installed hooks from a
Termux bootstrap context. Agent configuration is not part of the Pleiades edge
node and must not be mutated implicitly.

Use the relevant application's reviewed local configuration flow, and acquire
third-party tools through the locked pleiades-factory-stack catalog instead.
EOF
exit 64
