#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# install-llm-stack.sh — build llama.cpp + download model + install pleiades-llm
# Task #18: Deploy quantized local LLM inference stack
#
# Third-party projects used (not vendored — cloned/downloaded from upstream):
#   llama.cpp     ggerganov (Georgi Gerganov)  MIT        https://github.com/ggerganov/llama.cpp
#   Mistral 7B    Mistral AI                   Apache-2.0 https://huggingface.co/mistralai/Mistral-7B-v0.1
#   (GGUF quant)  TheBloke                     Apache-2.0 https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.3-GGUF
#
# llama.cpp is cloned from upstream and compiled locally. No source is vendored here.
set -euo pipefail

LOG_TAG="llm-stack"
log()  { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

LLAMA_SRC="/opt/llama.cpp"
LLAMA_BIN="/usr/local/bin/llama-cli"
MODEL_DIR="/opt/models"
MODEL_FILE="mistral-7b-instruct-v0.3-Q4_K_M.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
CONF_DIR="/etc/pleiades"
CONF_FILE="$CONF_DIR/llm.conf"
SCRIPTS_DIR="$(dirname "$(readlink -f "$0")")"

# ---------------------------------------------------------------------------
# Subtask 1: Build llama.cpp
# ---------------------------------------------------------------------------
build_llama_cpp() {
    log "=== Subtask 1: Build llama.cpp ==="

    if [[ -x "$LLAMA_BIN" ]]; then
        log "llama-cli already at $LLAMA_BIN — skipping build"
        return 0
    fi

    # Dependencies
    if command -v apt-get &>/dev/null; then
        apt-get install -y build-essential cmake git libopenblas-dev 2>/dev/null || true
    elif command -v emerge &>/dev/null; then
        emerge --ask=n --noreplace dev-build/cmake sci-libs/openblas 2>/dev/null || true
    fi

    # Clone if needed
    if [[ ! -d "$LLAMA_SRC" ]]; then
        log "Cloning llama.cpp to $LLAMA_SRC"
        git clone --depth=1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_SRC" \
            || die "git clone llama.cpp failed"
    else
        log "llama.cpp source found at $LLAMA_SRC"
        git -C "$LLAMA_SRC" pull --ff-only 2>/dev/null || true
    fi

    # Detect CUDA
    local cuda_args=()
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        log "CUDA GPU detected"
        cuda_args+=("-DGGML_CUDA=ON")
    elif [[ -d /usr/local/cuda ]] || [[ -d /usr/lib/cuda ]]; then
        log "CUDA headers found (no GPU visible — setting CUDA flag anyway)"
        cuda_args+=("-DGGML_CUDA=ON")
    else
        log "No CUDA — building with OpenBLAS"
        cuda_args+=("-DGGML_BLAS=ON" "-DGGML_BLAS_VENDOR=OpenBLAS")
    fi

    local build_dir="$LLAMA_SRC/build"
    mkdir -p "$build_dir"
    log "Configuring cmake (args: ${cuda_args[*]})"
    cmake -S "$LLAMA_SRC" -B "$build_dir" \
        "${cuda_args[@]}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=ON \
        2>&1 | tail -5

    local nproc; nproc=$(nproc 2>/dev/null || echo 2)
    log "Building with $nproc cores"
    make -C "$build_dir" -j"$nproc" llama-cli 2>&1 | tail -10

    local built_bin
    built_bin=$(find "$build_dir/bin" "$build_dir" -name "llama-cli" -type f 2>/dev/null | head -1)
    [[ -z "$built_bin" ]] && die "llama-cli binary not found after build"

    install -m755 "$built_bin" "$LLAMA_BIN"
    log "llama-cli installed to $LLAMA_BIN"
}

# ---------------------------------------------------------------------------
# Subtask 2: Download model
# ---------------------------------------------------------------------------
download_model() {
    log "=== Subtask 2: Download quantized model ==="
    mkdir -p "$MODEL_DIR"

    if [[ -f "$MODEL_PATH" ]]; then
        local size; size=$(wc -c < "$MODEL_PATH")
        if (( size > 1000000 )); then
            log "Model already at $MODEL_PATH ($size bytes) — skipping download"
            return 0
        fi
        log "Model file too small ($size bytes) — re-downloading"
        rm -f "$MODEL_PATH"
    fi

    local hf_url="https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/$MODEL_FILE"

    # Try huggingface-cli first (requires pip install huggingface_hub)
    if command -v huggingface-cli &>/dev/null; then
        log "Downloading via huggingface-cli"
        huggingface-cli download bartowski/Mistral-7B-Instruct-v0.3-GGUF \
            "$MODEL_FILE" --local-dir "$MODEL_DIR" \
            || log "WARN: huggingface-cli download failed, trying wget"
    fi

    if [[ ! -f "$MODEL_PATH" ]]; then
        log "Downloading via wget/curl: $hf_url"
        if command -v wget &>/dev/null; then
            wget -q --show-progress -O "$MODEL_PATH" "$hf_url" \
                || die "wget download failed"
        elif command -v curl &>/dev/null; then
            curl -L --progress-bar -o "$MODEL_PATH" "$hf_url" \
                || die "curl download failed"
        else
            die "No download tool available (wget or curl required)"
        fi
    fi

    local size; size=$(wc -c < "$MODEL_PATH")
    log "Model downloaded: $MODEL_PATH ($size bytes)"
    (( size < 1000000000 )) && log "WARN: model appears too small — may be incomplete"
}

# ---------------------------------------------------------------------------
# Subtask 3: Write config and pleiades-llm wrapper
# ---------------------------------------------------------------------------
write_config_and_wrapper() {
    log "=== Subtask 3: Config + pleiades-llm wrapper ==="
    mkdir -p "$CONF_DIR"

    local gpu_layers=0
    command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null && gpu_layers=35

    cat > "$CONF_FILE" << CONF
# Pleiades Team LLM Configuration — auto-generated by install-llm-stack.sh
MODEL_PATH=$MODEL_PATH
CTX_SIZE=8192
GPU_LAYERS=$gpu_layers
THREADS=$(nproc 2>/dev/null || echo 4)
TEMP_DEFAULT=0.1
TOP_P=0.9
REPEAT_PENALTY=1.1
MAX_TOKENS=2048
CONF
    log "Config written to $CONF_FILE"

    # Install wrapper
    install -m755 "$SCRIPTS_DIR/pleiades-llm" /usr/local/bin/pleiades-llm 2>/dev/null \
        || { log "WARN: could not install pleiades-llm from scripts dir — writing directly"; write_pleiades_llm_direct; }
    log "pleiades-llm installed to /usr/local/bin/pleiades-llm"
}

write_pleiades_llm_direct() {
    cat > /usr/local/bin/pleiades-llm << 'WRAPPER'
#!/usr/bin/env bash
# pleiades-llm — thin wrapper around llama-cli for purple team RE and fuzz workflows
set -euo pipefail

CONF="${PURPLE_LLM_CONF:-/etc/pleiades/llm.conf}"
[[ -f "$CONF" ]] || { echo "pleiades-llm: config not found at $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

MODE=""
SYS_PROMPT=""
INPUT_FILE=""
OUTPUT_FILE=""
CTX="${CTX_SIZE:-8192}"
TEMP="${TEMP_DEFAULT:-0.1}"
EXTRA_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --mode=re)       MODE=re;   SYS_PROMPT="You are a binary analysis expert. Analyze the decompiled code and identify: function purpose, parameter types, return values, security vulnerabilities (buffer overflows, format strings, privilege escalation, crypto weaknesses), and algorithm patterns. Be concise and precise." ;;
        --mode=fuzz)     MODE=fuzz; SYS_PROMPT="You are a fuzzing and vulnerability research expert. Given this function signature and decompiled code, identify: input constraints and valid ranges, edge cases and boundary conditions, crash-inducing inputs, and write a minimal AFL++ harness in C." ;;
        --mode=patch)    MODE=patch; SYS_PROMPT="You are a security patch engineer. Given this vulnerable code, write a minimal, correct patch that fixes the security issue without changing behavior. Output only the patched function." ;;
        --sys=*)         SYS_PROMPT="${arg#--sys=}" ;;
        --ctx=*)         CTX="${arg#--ctx=}" ;;
        --temp=*)        TEMP="${arg#--temp=}" ;;
        --file=*)        INPUT_FILE="${arg#--file=}" ;;
        --output=*)      OUTPUT_FILE="${arg#--output=}" ;;
        --*)             EXTRA_ARGS+=("$arg") ;;
    esac
done

# Read input from file or stdin
local_input=""
if [[ -n "$INPUT_FILE" ]]; then
    local_input=$(cat "$INPUT_FILE")
elif [[ ! -t 0 ]]; then
    local_input=$(cat)
fi

[[ -z "$local_input" ]] && { echo "pleiades-llm: no input (pipe text or use --file=)" >&2; exit 1; }
[[ ! -x "$(command -v llama-cli)" ]] && { echo "pleiades-llm: llama-cli not found — run install-llm-stack.sh" >&2; exit 1; }

LLAMA_ARGS=(
    -m "$MODEL_PATH"
    -c "$CTX"
    -ngl "${GPU_LAYERS:-0}"
    -t "${THREADS:-4}"
    --temp "$TEMP"
    --top-p "${TOP_P:-0.9}"
    --repeat-penalty "${REPEAT_PENALTY:-1.1}"
    -n "${MAX_TOKENS:-2048}"
    --no-display-prompt
    -s 42
)

if [[ -n "$SYS_PROMPT" ]]; then
    LLAMA_ARGS+=(-p "[INST] <<SYS>>
${SYS_PROMPT}
<</SYS>>

${local_input} [/INST]")
else
    LLAMA_ARGS+=(-p "$local_input")
fi

if [[ -n "$OUTPUT_FILE" ]]; then
    llama-cli "${LLAMA_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>/dev/null > "$OUTPUT_FILE"
    echo "pleiades-llm: output written to $OUTPUT_FILE" >&2
else
    llama-cli "${LLAMA_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>/dev/null
fi
WRAPPER
    chmod +x /usr/local/bin/pleiades-llm
}

# ---------------------------------------------------------------------------
# Subtask 4: Systemd resource limits + benchmark script
# ---------------------------------------------------------------------------
write_systemd_and_benchmark() {
    log "=== Subtask 4 & 5: systemd limits + benchmark ==="

    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/pleiades-llm.slice << 'SLICE'
[Unit]
Description=Pleiades Team LLM Inference Slice
DefaultDependencies=no

[Slice]
MemoryMax=12G
MemoryHigh=10G
CPUQuota=80%
IOWeight=50
TasksMax=64
SLICE

    log "pleiades-llm.slice written"

    # Write benchmark script
    cat > "$SCRIPTS_DIR/pleiades-llm-benchmark.sh" << 'BENCH'
#!/usr/bin/env bash
# pleiades-llm-benchmark.sh — measure tokens/sec for pleiades-llm
set -euo pipefail

echo "=== pleiades-llm benchmark ===" >&2
PROMPTS=(
    "What is 2+2?"
    "Explain the purpose of the main() function in C in one sentence."
    "List 5 common buffer overflow mitigation techniques used in modern operating systems."
)
LABELS=("short" "medium" "long")

for i in "${!PROMPTS[@]}"; do
    prompt="${PROMPTS[$i]}"
    label="${LABELS[$i]}"
    start=$(date +%s%3N)
    output=$(echo "$prompt" | /usr/local/bin/pleiades-llm 2>/dev/null)
    end=$(date +%s%3N)
    elapsed=$(( end - start ))
    tokens=$(echo "$output" | wc -w)
    tps=$(python3 -c "print(f'{$tokens / max($elapsed/1000, 0.1):.1f}')" 2>/dev/null || echo "?")
    echo "[$label] ${elapsed}ms | ~${tokens} tokens | ~${tps} tok/s"
done
echo "=== done ===" >&2
BENCH
    chmod +x "$SCRIPTS_DIR/pleiades-llm-benchmark.sh"
    log "benchmark script written"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    log "=== LLM stack installer — $(date -u) ==="
    build_llama_cpp
    download_model
    write_config_and_wrapper
    write_systemd_and_benchmark
    log ""
    log "=== Installation complete ==="
    log "  llama-cli: $(command -v llama-cli 2>/dev/null || echo 'NOT FOUND')"
    log "  pleiades-llm: $(command -v pleiades-llm 2>/dev/null || echo 'NOT FOUND')"
    log "  model: $MODEL_PATH ($(wc -c < "$MODEL_PATH" 2>/dev/null || echo '?') bytes)"
    log "  config: $CONF_FILE"
    log ""
    log "Test: echo 'What is radare2?' | pleiades-llm"
}

main "$@"
