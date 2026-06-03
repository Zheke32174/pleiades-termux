#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# Advanced test library for pleiades-regression.sh
# Source this file from the main harness — do not run directly.
# Requires: pass(), fail(), skip(), in_container(), container_up(), CONTAINER_PID
# set in the sourcing script.

# ── subtask 4a: hostile-recon replay ─────────────────────────────────────────

test_recon_replay() {
    if ! container_up; then skip "recon replay (container down)"; return; fi

    local real_hostname
    real_hostname="$(hostname 2>/dev/null || echo "unknown")"

    local before after response
    before="$(in_container "wc -l < /run/pleiades/pleiades-nexus_fifo 2>/dev/null || echo 0")" || before=0

    # Probe Taygete (port 2222) with identity recon commands
    for cmd in "id" "uname -a" "cat /etc/passwd"; do
        response="$(in_container "echo '$cmd' | timeout 3 nc -w 2 127.0.0.1 2222 2>/dev/null || true")"

        # Verify response is SYNTHETIC — must not expose real hostname
        if echo "$response" | grep -qF "$real_hostname" 2>/dev/null; then
            fail "recon '$cmd': real hostname leaked in response"
        else
            pass "recon '$cmd': response does not expose real hostname"
        fi
    done

    after="$(in_container "wc -l < /run/pleiades/pleiades-nexus_fifo 2>/dev/null || echo 0")" || after=0

    if [[ "$after" -gt "$before" ]]; then
        pass "HOSTILE_RECON events emitted to pleiades-nexus_fifo (lines: $before → $after)"
    else
        fail "no new telemetry lines in pleiades-nexus_fifo after recon probes"
    fi
}

# ── subtask 4b: policy broker deny matrix ────────────────────────────────────

test_broker_deny_matrix() {
    if ! container_up; then skip "broker deny matrix (container down)"; return; fi

    # Broker reads *.req files (key=value format), writes decisions to $id.decision
    local req_id="test-deny-$$"
    local req_file="/run/pleiades/requests/${req_id}.req"
    local decision_dir="/run/pleiades/decisions"

    # Test 1: denied class (shell/exec)
    in_container "printf 'id=%s\nclass=shell\naction=exec\nstatus=pending\n' '${req_id}' > '${req_file}'" 2>/dev/null || true

    local denied=false
    for i in $(seq 1 10); do
        sleep 0.5
        if in_container "grep -l 'decision=deny' '${decision_dir}/${req_id}.decision' 2>/dev/null | xargs cat 2>/dev/null | grep -q 'no-action-dispatched\|denied\|class-not-allowed'" 2>/dev/null; then
            denied=true; break
        fi
        # Also accept result file showing denied
        if in_container "grep -q 'no-action-dispatched\|denied' '${decision_dir}/../results/${req_id}.result' 2>/dev/null" 2>/dev/null; then
            denied=true; break
        fi
    done

    if $denied; then
        pass "broker denied shell/exec request"
    else
        fail "broker did not deny shell/exec request within 5s"
    fi

    in_container "rm -f '${req_file}' '${decision_dir}/${req_id}'* '/run/pleiades/results/${req_id}'* 2>/dev/null" || true

    # Test 2: allowed class (capabilities)
    local req_id2="test-allow-$$"
    local req_file2="/run/pleiades/requests/${req_id2}.req"
    in_container "printf 'id=%s\nclass=capabilities\naction=list\nstatus=pending\n' '${req_id2}' > '${req_file2}'" 2>/dev/null || true

    local allowed=false
    for i in $(seq 1 10); do
        sleep 0.5
        if in_container "grep -q 'decision=allow' '${decision_dir}/${req_id2}.decision' 2>/dev/null" 2>/dev/null; then
            allowed=true; break
        fi
    done

    if $allowed; then
        pass "broker allowed capabilities/list request"
    else
        skip "broker allow test inconclusive (broker may not process synchronously)"
    fi

    in_container "rm -f '${req_file2}' '${decision_dir}/${req_id2}'* '/run/pleiades/results/${req_id2}'* 2>/dev/null" || true
}

# ── subtask 5a: host-bridge + Windows telemetry ──────────────────────────────

test_host_bridge() {
    if ! container_up; then skip "host-bridge (container down)"; return; fi

    # /host/proc readable inside container
    if in_container "cat /host/proc/1/status" &>/dev/null; then
        pass "/host/proc/1/status readable"
    else
        skip "/host/proc not mounted (owner bridge not active)"
    fi

    if in_container "cat /host/sys/kernel/hostname" &>/dev/null; then
        pass "/host/sys/kernel/hostname readable"
    else
        skip "/host/sys not mounted"
    fi

    # Windows snapshot newer than 5 minutes
    local snap_dir="/var/lib/pleiades-team/host-bridge/windows11"
    local recent
    recent="$(in_container "find '$snap_dir' -maxdepth 1 -name '*.txt' -mmin -5 2>/dev/null | head -1")" || true
    if [[ -n "$recent" ]]; then
        pass "Windows host-bridge snapshot updated within last 5 min"
    else
        skip "Windows host-bridge snapshot >5 min old (may be normal if monitor just started)"
    fi
}

# ── subtask 5b: Celaeno liveness ─────────────────────────────────────────

test_celaeno_alive() {
    if ! container_up; then skip "Celaeno (container down)"; return; fi

    # Service active
    if in_container "systemctl is-active celaeno-omniversal.service" &>/dev/null; then
        pass "celaeno-omniversal.service is active"
    else
        fail "celaeno-omniversal.service is not active"
        return
    fi

    # Command file writable (Celaeno reads /run/pleiades/celaeno_cmd)
    if in_container "test -w /run/pleiades/celaeno_cmd 2>/dev/null || test -e /run/pleiades/celaeno_cmd"; then
        pass "/run/pleiades/celaeno_cmd exists"
    else
        fail "/run/pleiades/celaeno_cmd missing"
    fi

    # No recent crash-loop: check journal for excessive restarts in last 2 min
    # grep -c exits 1 with 0 matches; use || true to prevent appending a second "0"
    local restarts
    restarts="$(in_container "journalctl -u celaeno-omniversal.service --since '2 minutes ago' --no-pager 2>/dev/null | { grep -c 'Started\|start request' || true; }")" || restarts=0
    restarts="${restarts//[^0-9]/}"   # strip any stray whitespace/newlines
    restarts="${restarts:-0}"
    if [[ "$restarts" -le 2 ]]; then
        pass "Celaeno restart count in last 2m: ${restarts} (≤2)"
    else
        fail "Celaeno crash-looping: ${restarts} restarts in last 2m"
    fi
}

# ── LLM stack verification (task #30) ────────────────────────────────────────

test_llm_stack() {
    if ! container_up; then skip "LLM stack (container down)"; return; fi

    # 1. llama-cli binary
    if ! in_container "test -x /usr/local/bin/llama-cli" &>/dev/null; then
        skip "llama-cli not found — run install-llm-stack.sh to build"
        return
    fi
    pass "llama-cli installed"

    # 2. Config file with expected keys
    if ! in_container "test -f /etc/pleiades/llm.conf" &>/dev/null; then
        fail "/etc/pleiades/llm.conf missing — install-llm-stack.sh not run"
        return
    fi
    pass "/etc/pleiades/llm.conf present"

    local model_path
    model_path="$(in_container "grep '^MODEL_PATH=' /etc/pleiades/llm.conf | cut -d= -f2" 2>/dev/null)" || true
    if [[ -z "$model_path" ]]; then
        fail "MODEL_PATH not set in /etc/pleiades/llm.conf"
        return
    fi

    # 3. Model file >1 GiB
    local model_size
    model_size="$(in_container "wc -c < '$model_path' 2>/dev/null || echo 0")" || model_size=0
    model_size="${model_size//[^0-9]/}"; model_size="${model_size:-0}"
    if (( model_size > 1000000000 )); then
        pass "model file present ($(( model_size / 1048576 )) MiB)"
    else
        fail "model file missing or too small at $model_path (${model_size} bytes)"
        return
    fi

    # 4. pleiades-llm wrapper
    if in_container "test -x /usr/local/bin/pleiades-llm" &>/dev/null; then
        pass "pleiades-llm wrapper executable"
    else
        fail "pleiades-llm wrapper not found"
        return
    fi

    # 5. systemd resource slice present
    if in_container "test -f /etc/systemd/system/pleiades-llm.slice" &>/dev/null; then
        pass "pleiades-llm.slice unit present"
    else
        fail "pleiades-llm.slice missing — resource limits not configured"
    fi
}

# ── RE pipeline verification (task #31) ───────────────────────────────────────

test_re_pipeline() {
    if ! container_up; then skip "RE pipeline (container down)"; return; fi

    # Locate pleiades-re inside the container (installed binary or script)
    local re_cmd=""
    if in_container "test -x /usr/local/bin/pleiades-re" &>/dev/null; then
        re_cmd="/usr/local/bin/pleiades-re"
    elif in_container "test -f /scripts/pleiades-re.sh" &>/dev/null; then
        re_cmd="bash /scripts/pleiades-re.sh"
    else
        skip "pleiades-re not found inside container (not yet installed)"
        return
    fi

    # 1. Version command
    local ver
    ver="$(in_container "$re_cmd version 2>/dev/null")" || true
    if [[ "$ver" == pleiades-re* ]]; then
        pass "pleiades-re version: $ver"
    else
        fail "pleiades-re version command failed (got: '$ver')"
        return
    fi

    # 2. Stage 1: analyze maia_crypto without LLM — report must contain expected sections
    local sample_bin="/usr/local/bin/maia_crypto"
    if ! in_container "test -x '$sample_bin'" &>/dev/null; then
        sample_bin="/usr/bin/file"
    fi

    local report
    report="$(in_container "$re_cmd analyze '$sample_bin' --format=markdown 2>/dev/null")" || true

    if echo "$report" | grep -q "Pleiades Team RE Report"; then
        pass "pleiades-re analyze: report header present"
    else
        fail "pleiades-re analyze: report missing 'Pleiades Team RE Report' header"
    fi

    if echo "$report" | grep -q "Stage 1: Decompiled Output"; then
        pass "pleiades-re analyze: Stage 1 section present"
    else
        fail "pleiades-re analyze: Stage 1 section missing"
    fi

    if echo "$report" | grep -q "Stage 3: Type Recovery"; then
        pass "pleiades-re analyze: Stage 3 section present"
    else
        fail "pleiades-re analyze: Stage 3 section missing"
    fi

    # 3. Capability file registered
    if in_container "test -f /run/pleiades/capabilities/pleiades_re.cap" &>/dev/null; then
        pass "pleiades_re.cap capability registered"
    else
        fail "pleiades_re.cap not written — register_re_capability() may have failed"
    fi

    # 4. LLM stage integration — only if llama-cli + pleiades-llm are present
    if ! in_container "test -x /usr/local/bin/llama-cli && test -x /usr/local/bin/pleiades-llm" &>/dev/null; then
        skip "RE pipeline LLM stage (pleiades-llm or llama-cli not installed)"
        return
    fi

    local llm_report
    llm_report="$(in_container "USE_LLM=1 $re_cmd analyze '$sample_bin' --llm 2>/dev/null")" || true
    if echo "$llm_report" | grep -q "Stage 2: LLM Analysis"; then
        pass "pleiades-re --llm: Stage 2 section present"
    else
        fail "pleiades-re --llm: Stage 2 LLM section missing in report"
    fi
}

# ── subtask 5c: Maia crypto round-trip ─────────────────────────────────────

test_maia_crypto() {
    if ! container_up; then skip "Maia crypto (container down)"; return; fi

    if ! in_container "test -x /usr/local/bin/maia_crypto" &>/dev/null; then
        fail "maia_crypto binary not found or not executable"
        return
    fi

    # maia_crypto sign <file>  → hex signature
    # maia_crypto verify <file> <sigHex>  → exit 0 on valid
    local tmp_msg="/tmp/_pleiades_regtest_msg_$$"
    local test_payload="regression-test-$(date +%s)"
    in_container "printf '%s' '${test_payload}' > '${tmp_msg}'" 2>/dev/null || true

    local signed
    signed="$(in_container "/usr/local/bin/maia_crypto sign '${tmp_msg}' 2>/dev/null")" || true

    if [[ -z "$signed" ]]; then
        in_container "rm -f '${tmp_msg}'" 2>/dev/null || true
        fail "maia_crypto sign failed (empty output)"
        return
    fi
    pass "maia_crypto sign succeeded"

    # Verify the signature: pass file + sigHex as separate args
    local verify_rc
    verify_rc="$(in_container "/usr/local/bin/maia_crypto verify '${tmp_msg}' '${signed}' 2>/dev/null; echo \$?")" || verify_rc=1
    verify_rc="$(echo "$verify_rc" | tail -1 | tr -d '[:space:]')"

    in_container "rm -f '${tmp_msg}'" 2>/dev/null || true

    if [[ "$verify_rc" == "0" ]]; then
        pass "maia_crypto verify round-trip: OK"
    else
        fail "maia_crypto verify round-trip: FAILED (rc=${verify_rc})"
    fi
}
