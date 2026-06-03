#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# pleiades-re.sh — Pleiades Team Binary Reverse Engineering Pipeline
#
# Pipeline: binary → decompile (radare2/ghidra) → LLM refine → type recovery → report
# Task #14: Build binary decompilation + LLM refinement pipeline
#
# Usage:
#   pleiades-re analyze <binary> [--format=json|markdown] [--llm] [--type-recovery]
#   pleiades-re batch <dir> [--ext=.so,.elf] [--output-dir=<dir>]
#   pleiades-re install-deps
#
# Third-party tools called by this script (not vendored — installed separately):
#   Ghidra        NSA                Apache-2.0   https://github.com/NationalSecurityAgency/ghidra
#   angr          angr project       BSD-2-Clause https://github.com/angr/angr
#   remill        Trail of Bits      Apache-2.0   https://github.com/lifting-bits/remill
#   ddisasm       GrammaTech         AGPL-3.0     https://github.com/GrammaTech/ddisasm
#                 NOTE: ddisasm is AGPL-3.0. This script only calls the installed binary.
#                 No ddisasm source is vendored here.
#   RetroWrite    HexHive (EPFL)     MIT          https://github.com/HexHive/retrowrite
#   rev.ng        rev.ng Labs        GPL-2.0      https://github.com/revng/revng
#                 NOTE: rev.ng is GPL-2.0. This script only calls the installed binary.
set -euo pipefail

FIFO="/run/pleiades/pleiades-nexus_fifo"
STATE_DIR="/var/lib/pleiades-team/re"
REPORT_DIR="${PURPLE_RE_REPORT_DIR:-$STATE_DIR/reports}"
LOCK_FILE="/run/pleiades-re.lock"
LLM_BIN="/usr/local/bin/pleiades-llm"
LOG_FILE="/var/log/pleiades/re.log"
VERSION="1.0.0"

mkdir -p "$STATE_DIR" "$REPORT_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true

log()   { local msg="[$(date -u +%H:%M:%S)] [pleiades-re] [$$] $*"; echo "$msg" | tee -a "$LOG_FILE" >&2; }
event() { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }
die()   { log "ERROR: $*"; exit 1; }

# ─── Tool detection ────────────────────────────────────────────────────────────
detect_decompiler() {
    if command -v r2 &>/dev/null; then
        echo "radare2"
    elif command -v radare2 &>/dev/null; then
        echo "radare2"
    elif command -v ghidra-analyzeHeadless &>/dev/null; then
        echo "ghidra"
    else
        echo "fallback"
    fi
}

# ─── Stage 1: Decompilation ────────────────────────────────────────────────────
stage1_decompile() {
    local binary="$1"
    local tool; tool=$(detect_decompiler)
    log "Stage 1: decompiling $binary with $tool"

    case "$tool" in
        radare2)
            # Full analysis: aaa (auto-analysis), pdf @main (decompile main), is (symbols), il (imports)
            local r2_out
            r2_out=$(r2 -A -q -e scr.color=0 -e log.level=0 \
                -c "aaa; s main 2>/dev/null || s sym.main; pdf; is; il; iI; iz" \
                "$binary" 2>/dev/null) || \
            r2_out=$(r2 -q -e scr.color=0 -e log.level=0 \
                -c "aa; pdf @entry0; is; il; iI" \
                "$binary" 2>/dev/null) || \
            r2_out="[radare2 analysis incomplete — binary may require privileges]"
            echo "$r2_out"
            ;;
        ghidra)
            local project_dir; project_dir=$(mktemp -d /tmp/ghidra_proj_XXXXXX)
            ghidra-analyzeHeadless "$project_dir" pleiades_re_tmp \
                -import "$binary" \
                -postScript DecompileHeadless.java \
                -scriptPath /opt/ghidra/Ghidra/Features/Decompiler/ghidra_scripts \
                -deleteProject 2>/dev/null || echo "[ghidra: analysis incomplete]"
            rm -rf "$project_dir"
            ;;
        fallback)
            log "No decompiler found — using file/strings/objdump fallback"
            {
                echo "=== file ==="
                file "$binary" 2>/dev/null
                echo ""
                echo "=== strings (printable >= 8 chars) ==="
                strings -n 8 "$binary" 2>/dev/null | head -100
                echo ""
                echo "=== objdump (symbol table) ==="
                objdump -t "$binary" 2>/dev/null | head -60 || true
                echo ""
                echo "=== readelf (dynamic) ==="
                readelf -d "$binary" 2>/dev/null | head -40 || true
            }
            ;;
    esac
}

# ─── Stage 2: LLM Refinement ───────────────────────────────────────────────────
stage2_llm_refine() {
    local decompiled="$1"
    local binary_name="$2"

    if [[ "${USE_LLM:-0}" != "1" ]]; then
        echo "$decompiled"
        return 0
    fi

    if [[ ! -x "$LLM_BIN" ]]; then
        log "Stage 2: LLM refinement skipped — $LLM_BIN not found (install task #18 first)"
        echo "$decompiled"
        echo ""
        echo "<!-- LLM refinement: install pleiades-llm (task #18) and re-run with --llm -->"
        return 0
    fi

    log "Stage 2: LLM refinement via $LLM_BIN"
    local llm_prompt
    llm_prompt="Binary: $binary_name
Decompiled output:
$decompiled

Provide a concise analysis:
1. Primary purpose of this binary/function
2. Input parameters and expected types
3. Return values and side effects
4. Security concerns (buffer overflows, format strings, privilege ops, crypto)
5. Algorithm identification if applicable
Keep response under 500 words."

    echo "$llm_prompt" | "$LLM_BIN" --mode=re 2>/dev/null || {
        log "LLM refinement failed — returning raw decompilation"
        echo "$decompiled"
    }
}

# ─── Stage 3: Type Recovery ────────────────────────────────────────────────────
stage3_type_recovery() {
    local binary="$1"
    log "Stage 3: type recovery for $binary"

    {
        echo "=== Symbol Table ==="
        readelf -s "$binary" 2>/dev/null | grep -v "NOTYPE\|UND\|LOCAL" | head -50 || true

        echo ""
        echo "=== Dynamic Symbols ==="
        nm -D "$binary" 2>/dev/null | head -40 || objdump -T "$binary" 2>/dev/null | head -40 || true

        echo ""
        echo "=== DWARF Type Info (if present) ==="
        objdump --dwarf=info "$binary" 2>/dev/null | grep -A2 "DW_TAG_base_type\|DW_TAG_typedef\|DW_TAG_structure_type\|DW_TAG_pointer_type" | head -80 || true

        if command -v r2 &>/dev/null && [[ "${USE_TYPE_RECOVERY:-0}" == "1" ]]; then
            echo ""
            echo "=== radare2 Type Analysis ==="
            r2 -q -e scr.color=0 -e log.level=0 \
               -c "aaa; aaft; aflt; aft @@f" \
               "$binary" 2>/dev/null | head -60 || true
        fi
    }
}

# ─── Stage 4: Report Generation ────────────────────────────────────────────────
stage4_report() {
    local binary="$1"
    local decompiled="$2"
    local llm_output="$3"
    local type_info="$4"
    local format="${5:-markdown}"

    local binary_name; binary_name=$(basename "$binary")
    local file_info; file_info=$(file "$binary" 2>/dev/null || echo "unknown")
    local sha256; sha256=$(sha256sum "$binary" 2>/dev/null | cut -d' ' -f1 || echo "unavailable")
    local size; size=$(wc -c < "$binary" 2>/dev/null || echo "0")
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tool; tool=$(detect_decompiler)

    if [[ "$format" == "json" ]]; then
        python3 - << PYEOF
import json, sys
report = {
    "schema": "pleiades-re-report-v1",
    "timestamp": "$ts",
    "binary": {
        "name": "$binary_name",
        "path": "$binary",
        "sha256": "$sha256",
        "size_bytes": $size,
        "file_info": $(python3 -c "import json; print(json.dumps('$file_info'))")
    },
    "pipeline": {
        "decompiler": "$tool",
        "llm_used": ${USE_LLM:-0} == 1,
        "type_recovery": ${USE_TYPE_RECOVERY:-0} == 1
    },
    "decompiled": $(python3 -c "import json, sys; print(json.dumps(open('/dev/stdin').read()))" <<< "$decompiled"),
    "llm_analysis": $(python3 -c "import json, sys; print(json.dumps(open('/dev/stdin').read()))" <<< "$llm_output"),
    "type_info": $(python3 -c "import json, sys; print(json.dumps(open('/dev/stdin').read()))" <<< "$type_info")
}
print(json.dumps(report, indent=2))
PYEOF
    else
        cat << MDEOF
# Pleiades Team RE Report: \`$binary_name\`

**Generated:** $ts
**SHA-256:** \`$sha256\`
**Size:** $size bytes
**File:** $file_info
**Decompiler:** $tool
**LLM Analysis:** $([ "${USE_LLM:-0}" = "1" ] && echo "enabled" || echo "disabled (use --llm)")
**Type Recovery:** $([ "${USE_TYPE_RECOVERY:-0}" = "1" ] && echo "enabled" || echo "disabled (use --type-recovery)")

---

## Stage 1: Decompiled Output

\`\`\`
$decompiled
\`\`\`

---

## Stage 2: LLM Analysis

$llm_output

---

## Stage 3: Type Recovery

\`\`\`
$type_info
\`\`\`

---

*Generated by pleiades-re v$VERSION — [Pleiades Team Pleiades]*
MDEOF
    fi
}

# ─── Commands ──────────────────────────────────────────────────────────────────
cmd_analyze() {
    local binary=""
    local format="markdown"
    local output=""

    for arg in "$@"; do
        case "$arg" in
            --format=*)  format="${arg#--format=}" ;;
            --llm)       USE_LLM=1 ;;
            --type-recovery) USE_TYPE_RECOVERY=1 ;;
            --output=*)  output="${arg#--output=}" ;;
            --*)         die "Unknown flag: $arg" ;;
            *)           binary="$arg" ;;
        esac
    done

    [[ -z "$binary" ]] && die "Usage: pleiades-re analyze <binary> [--format=json|markdown] [--llm] [--type-recovery]"
    [[ -f "$binary" ]] || die "Binary not found: $binary"

    (
        flock -n 200 || die "Another pleiades-re instance is running"

        event "RE_ANALYSIS_START|pleiades-re|$(basename "$binary")|$(date -u +%s)"
        log "Analyzing: $binary (format=$format llm=${USE_LLM:-0} type=${USE_TYPE_RECOVERY:-0})"

        local decompiled; decompiled=$(stage1_decompile "$binary")
        local llm_out;    llm_out=$(stage2_llm_refine "$decompiled" "$(basename "$binary")")
        local type_info;  type_info=$(stage3_type_recovery "$binary")
        local report;     report=$(stage4_report "$binary" "$decompiled" "$llm_out" "$type_info" "$format")

        if [[ -n "$output" ]]; then
            echo "$report" > "$output"
            log "Report written to $output"
        else
            local slug; slug=$(basename "$binary" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_')
            local report_file="$REPORT_DIR/${slug}_$(date -u +%Y%m%dT%H%M%S).${format}"
            echo "$report" > "$report_file"
            log "Report saved to $report_file"
            echo "$report"
        fi

        event "RE_ANALYSIS_DONE|pleiades-re|$(basename "$binary")|success"
    ) 200>"$LOCK_FILE"
}

cmd_batch() {
    local dir=""
    local ext=".so .elf"
    local out_dir="$REPORT_DIR/batch_$(date -u +%Y%m%dT%H%M%S)"

    for arg in "$@"; do
        case "$arg" in
            --ext=*)        ext="${arg#--ext=}" ;;
            --output-dir=*) out_dir="${arg#--output-dir=}" ;;
            *)              dir="$arg" ;;
        esac
    done

    [[ -z "$dir" || ! -d "$dir" ]] && die "Usage: pleiades-re batch <dir> [--ext=.so,.elf] [--output-dir=<dir>]"
    mkdir -p "$out_dir"

    local count=0
    while IFS= read -r -d '' binary; do
        local outfile="$out_dir/$(basename "$binary").md"
        log "Batch: $binary → $outfile"
        cmd_analyze "$binary" --format=markdown --output="$outfile" || log "WARN: failed on $binary"
        (( count++ ))
    done < <(find "$dir" -maxdepth 3 -type f \( -name "*.so" -o -name "*.elf" -o -perm /111 \) -print0 2>/dev/null)

    log "Batch complete: $count files analyzed → $out_dir"
}

cmd_install_deps() {
    log "Installing RE dependencies"
    if command -v emerge &>/dev/null; then
        emerge --ask=n dev-util/radare2 app-misc/binwalk sys-apps/file || true
    elif command -v apt-get &>/dev/null; then
        apt-get install -y radare2 binwalk file binutils || true
    fi
    log "Deps installed. Verify: r2 -v"
}

# ─── Integration with pleiades-forensic-scanner.sh ─────────────────────────────
register_re_capability() {
    local cap_dir="/run/pleiades/capabilities"
    mkdir -p "$cap_dir" 2>/dev/null || true
    {
        echo "schema=pleiades-pleiades-swarm-capability-v1"
        echo "component=pleiades_re"
        echo "domain=reverse_engineering"
        echo "capabilities=decompile,llm_refine,type_recovery,report_gen"
        echo "authority=policy-gated"
        echo "decompiler=$(detect_decompiler)"
        echo "llm_available=$([ -x "$LLM_BIN" ] && echo yes || echo no)"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$cap_dir/pleiades_re.cap" 2>/dev/null || true
}

# ─── Maia hook ──────────────────────────────────────────────────────────────
_maia_hook() {
    local event_str="${1:-}"
    case "$event_str" in
        RE_ANALYSIS_*)  log "maia: $event_str" ;;
        *)              : ;;
    esac
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"; shift || true

    register_re_capability

    case "$cmd" in
        analyze)        cmd_analyze "$@" ;;
        batch)          cmd_batch "$@" ;;
        install-deps)   cmd_install_deps ;;
        version)        echo "pleiades-re $VERSION" ;;
        help|--help|-h)
            cat << 'HELP'
pleiades-re — Pleiades Team Binary RE Pipeline

Commands:
  analyze <binary> [opts]    Decompile + LLM refine + type recovery + report
  batch <dir> [opts]         Analyze all binaries in a directory
  install-deps               Install radare2 and RE tooling
  version                    Show version

Options for analyze:
  --format=markdown|json     Output format (default: markdown)
  --llm                      Enable LLM refinement (requires pleiades-llm)
  --type-recovery            Enable deep type recovery via radare2 aaft
  --output=<file>            Write report to file instead of stdout

Examples:
  pleiades-re analyze /usr/bin/ls --format=markdown
  pleiades-re analyze ./suspicious.elf --llm --type-recovery
  pleiades-re batch /opt/firmware --ext=.so --output-dir=/tmp/re-reports
HELP
            ;;
        *)  die "Unknown command: $cmd. Run pleiades-re help" ;;
    esac
}

main "$@"
