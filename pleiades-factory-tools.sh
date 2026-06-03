#!/data/data/com.termux/files/usr/bin/bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
set -euo pipefail

ROOT="${PLEIADES_GENTOO_PROJECT_ROOT:-${PLEIADES_ROOT:-${HOME}/pleiades}}"
TOOLS_ROOT="${PLEIADES_FACTORY_TOOLS_ROOT:-$ROOT/tools}"
MANIFEST="${PLEIADES_FACTORY_TOOL_MANIFEST:-$ROOT/.octo/factory/toolchain.json}"

usage() {
    cat <<'USAGE'
usage: pleiades-factory-tools <command> [args]
commands:
  list                         list integrated factory tools
  status                       list tools with git HEAD and presence checks
  repo <id>                    print local path for a tool id
  paper2code-fetch <arxiv> [outdir]
  paper2code-structure <paper_text.md> [outdir]
  hermes-evolve [args...]      run hermes-agent-self-evolution module
  continual-harness [args...]  run continual-harness run_cli.py
  pleiades-factory-plan                 print factory integration plan
USAGE
}

repo_path() {
    case "${1:-}" in
        paper2code) printf '%s\n' "$TOOLS_ROOT/paper2code" ;;
        hermes-evolution) printf '%s\n' "$TOOLS_ROOT/hermes-agent-self-evolution" ;;
        continual-harness) printf '%s\n' "$TOOLS_ROOT/continual-harness" ;;
        *) return 1 ;;
    esac
}

list_tools() {
    cat <<'TOOLS'
id	local_path	factory_role	cli_entry
paper2code	tools/paper2code	research-paper-to-cited-implementation	paper2code-fetch, paper2code-structure
hermes-evolution	tools/hermes-agent-self-evolution	skill-prompt-tool-evolution	hermes-evolve
continual-harness	tools/continual-harness	reset-free-agent-harness-refinement	continual-harness
TOOLS
}

status() {
    echo "schema=pleiades-factory-tools-status-v1"
    echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "manifest=$MANIFEST"
    for id in paper2code hermes-evolution continual-harness; do
        local path
        path="$(repo_path "$id")"
        echo "--- $id ---"
        echo "path=$path"
        if [[ -d "$path/.git" ]]; then
            echo "present=yes"
            git -C "$path" remote get-url origin 2>/dev/null | sed 's/^/origin=/'
            git -C "$path" log -1 --format='head=%h %ad %s' --date=short 2>/dev/null || true
        else
            echo "present=no"
        fi
    done
}

paper2code_fetch() {
    [[ $# -ge 1 ]] || { echo "paper2code-fetch requires an arxiv id or URL" >&2; exit 2; }
    local repo out
    repo="$(repo_path paper2code)"
    out="${2:-$ROOT/factory-output/paper2code/${1//\//_}}"
    mkdir -p "$out"
    python3 "$repo/skills/paper2code/scripts/fetch_paper.py" "$1" "$out"
    echo "output=$out"
}

paper2code_structure() {
    [[ $# -ge 1 ]] || { echo "paper2code-structure requires paper_text.md" >&2; exit 2; }
    local repo out
    repo="$(repo_path paper2code)"
    out="${2:-$(dirname "$1")/structure}"
    mkdir -p "$out"
    python3 "$repo/skills/paper2code/scripts/extract_structure.py" "$1" "$out"
    echo "output=$out"
}

hermes_evolve() {
    local repo
    repo="$(repo_path hermes-evolution)"
    cd "$repo"
    python3 -m evolution.skills.evolve_skill "$@"
}

continual_harness() {
    local repo
    repo="$(repo_path continual-harness)"
    cd "$repo"
    python3 run_cli.py "$@"
}

factory_plan() {
    cat <<'PLAN'
schema=pleiades-factory-toolchain-plan-v1
paper2code=ingest arxiv papers into citation-anchored implementation scaffolds for factory candidates
hermes-evolution=evolve skills/prompts/tool descriptions behind tests and constraint gates
continual-harness=run reset-free harness refinement and CLI-agent benchmark loops
guardrail=all execution remains owner-invoked from pleiades-factory-tools; broker integration is introspection-only by default
PLAN
}

case "${1:-}" in
    list) list_tools ;;
    status) status ;;
    repo) shift; repo_path "${1:-}" ;;
    paper2code-fetch) shift; paper2code_fetch "$@" ;;
    paper2code-structure) shift; paper2code_structure "$@" ;;
    hermes-evolve) shift; hermes_evolve "$@" ;;
    continual-harness) shift; continual_harness "$@" ;;
    pleiades-factory-plan) factory_plan ;;
    --help|-h|"") usage ;;
    *) usage; exit 2 ;;
esac
