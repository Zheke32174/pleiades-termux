#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
set -euo pipefail


register_pleiades-swarm_capability() {
    local component="$1" domain="$2" capabilities="$3"
    local run_dir="/run/pleiades"
    local cap_dir="$run_dir/capabilities"
    local state_dir="$run_dir/state"
    local policy_dir="/etc/pleiades"
    local alien_dir="$run_dir/alien"
    mkdir -p "$cap_dir" "$state_dir" "$run_dir/requests" "$run_dir/decisions" "$run_dir/actions" "$run_dir/results" "$alien_dir/inbox" "$alien_dir/outbox" "$policy_dir" /var/lib/pleiades-team/pleiades-swarm 2>/dev/null || true
    touch "$run_dir/pleiades-nexus_fifo" 2>/dev/null || true
    if [[ ! -f "$policy_dir/pleiades-swarm-policy.json" ]]; then
        cat > "$policy_dir/pleiades-swarm-policy.json" <<'POLICY'
{
  "schema": "pleiades-pleiades-swarm-policy-v1",
  "mode": "owner-authorized-defensive",
  "default_request_decision": "deny",
  "allowed_request_classes": ["status", "health", "capabilities", "evidence-list", "brl-status", "strat-list", "alien-hint"],
  "denied_request_classes": ["shell", "exec", "install", "network-change", "firewall-change", "script-modify", "credential-access", "lateral-movement"],
  "alien_sidecar": {"enabled": false, "authority": "advisory-only", "may_request": true, "may_act": false},
  "audit": {"append_only_events": true, "owner_visible": true}
}
POLICY
    fi
    {
        echo "schema=pleiades-pleiades-swarm-capability-v1"
        echo "component=$component"
        echo "domain=$domain"
        echo "capabilities=$capabilities"
        echo "authority=policy-gated"
        echo "ai_sidecar_required=no"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$cap_dir/$component.cap" 2>/dev/null || true
    {
        echo "schema=pleiades-pleiades-swarm-state-v1"
        echo "component=$component"
        echo "status=registered"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$state_dir/$component.state" 2>/dev/null || true
    printf 'PLEIADES_SWARM_CAPABILITY|%s|%s|%s
' "$component" "$domain" "$capabilities" >> "$run_dir/pleiades-nexus_fifo" 2>/dev/null || true
}

# ------------------------------------------------------------
# Curl-based Go and Rust installers — never use emerge for these
# ------------------------------------------------------------
ensure_go() {
    command -v go &>/dev/null && return 0
    local arch; arch=$(uname -m)
    local goarch="amd64"; [[ "$arch" == "aarch64" ]] && goarch="arm64"
    curl -fsSL "https://go.dev/dl/go1.22.5.linux-${goarch}.tar.gz" -o /tmp/_go.tar.gz || return 1
    tar -C /usr/local -xzf /tmp/_go.tar.gz && rm -f /tmp/_go.tar.gz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    export PATH="/usr/local/go/bin:$PATH"
}

ensure_rust() {
    command -v rustc &>/dev/null && return 0
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path
    local cargo="$HOME/.cargo/bin"
    ln -sf "${cargo}/rustc" /usr/local/bin/rustc 2>/dev/null || true
    ln -sf "${cargo}/cargo" /usr/local/bin/cargo 2>/dev/null || true
    export PATH="${cargo}:$PATH"
}

# ------------------------------------------------------------
# Package manager shim — works on Gentoo, Debian, RHEL, Arch, Alpine, FreeBSD
# ------------------------------------------------------------
pkg_install() {
    local pkgs=()
    for p in "$@"; do
        case "$p" in
            golang) ensure_go; continue ;;
            rustc)  ensure_rust; continue ;;
            bun)    continue ;;
        esac
        if command -v emerge &>/dev/null; then
            case "$p" in
                openbsd-netcat|nc) pkgs+=("net-analyzer/openbsd-netcat") ;;
                screen) pkgs+=("app-misc/screen") ;;
                bc) pkgs+=("sys-devel/bc") ;;
                lm-sensors) : ;;
                parted) pkgs+=("sys-block/parted") ;;
                socat) pkgs+=("net-misc/socat") ;;
                conntrack) pkgs+=("net-firewall/conntrack-tools") ;;
                golang) : ;;
                bun) : ;;
                lm-sensors) : ;;
                rustc) : ;;
                curl) pkgs+=("net-misc/curl") ;;
                git) pkgs+=("dev-vcs/git") ;;
                openssl) pkgs+=("dev-libs/openssl") ;;
                traceroute) pkgs+=("net-analyzer/traceroute") ;;
                sshpass) pkgs+=("net-misc/sshpass") ;;
                *) pkgs+=("$p") ;;
            esac
        else
            pkgs+=("$p")
        fi
    done

    if command -v emerge &>/dev/null; then
        emerge --quiet --noreplace "${pkgs[@]}"
    elif command -v apt-get &>/dev/null; then
        local apt_pkgs=()
        for p in "${pkgs[@]}"; do
            case "$p" in
                openbsd-netcat) apt_pkgs+=("netcat-openbsd") ;;
                bind-tools) apt_pkgs+=("dnsutils") ;;
                iproute2|net-tools|tcpdump|conntrack|lsof|curl|openssl|jq|procps|sysstat|tar|gzip|coreutils|screen|bc|traceroute|socat|nodejs) apt_pkgs+=("$p") ;;
                *) apt_pkgs+=("$p") ;;
            esac
        done
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt_pkgs[@]}" || {
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt_pkgs[@]}"
        }
    elif command -v apk &>/dev/null; then
        apk add --quiet "${pkgs[@]}"
    elif command -v pkg &>/dev/null; then
        pkg install -y -q "${pkgs[@]}"
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "${pkgs[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y -q "${pkgs[@]}"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm --needed "${pkgs[@]}"
    else
        echo "WARN: no supported package manager; skipping install of: ${pkgs[*]}" >&2
    fi
}

# ----------------------------------------------------------------
# Shared helpers: socket compat, load-order coordination
# ----------------------------------------------------------------
nc_unix_send() {
    local sock="$1" msg="$2"
    if command -v socat &>/dev/null; then
        printf '%s\n' "$msg" | socat - "UNIX-CONNECT:$sock" 2>/dev/null || true
    else
        printf '%s\n' "$msg" | nc -U "$sock" -w 1 2>/dev/null || true
    fi
}
signal_ready() { mkdir -p /var/lib/pleiades/ready; touch "/var/lib/pleiades/ready/$1"; }
wait_for()     {
    local name="$1" timeout="${2:-90}" elapsed=0
    while [[ ! -f "/var/lib/pleiades/ready/$name" ]]; do
        (( elapsed >= timeout )) && { logger -t pleiades "WARN: timeout waiting for $name"; return 0; }
        sleep 2; (( elapsed += 2 ))
    done
}

# ------------------------------------------------------------
# Runtime service manager detection
# Environment awareness is separate from persistence method.
# In WSL-backed nspawn containers, /proc/version says WSL even when
# systemd is fully available inside the container.
# ------------------------------------------------------------
systemd_usable() {
    command -v systemctl &>/dev/null || return 1
    [[ -d /run/systemd/system ]] || return 1
    local state
    state=$(systemctl is-system-running 2>/dev/null || true)
    case "$state" in
        running|degraded|starting|initializing) return 0 ;;
        *) return 1 ;;
    esac
}

container_context() {
    if command -v systemd-detect-virt &>/dev/null; then
        systemd-detect-virt --container 2>/dev/null || true
        return 0
    fi
    awk -F/ '/docker|lxc|kubepods|machine.slice|systemd-nspawn/ {print $NF; found=1} END {exit found?0:1}' /proc/1/cgroup 2>/dev/null || true
}


host_bridge_capability_report() {
    local component="${1:-unknown}"
    local state_file="${PURPLE_HOST_BRIDGE_STATE:-/run/pleiades/host_bridge_capabilities}"
    local owner_copy="${PURPLE_HOST_BRIDGE_OWNER_COPY:-/var/lib/.maia/host_bridge_capabilities}"
    local tmp="${state_file}.$$"
    local container="none"
    local host_proc="absent"
    local host_root="absent"
    local host_systemd="absent"
    local host_container_socket="absent"
    local windows_host_files="absent"
    local mode="container-sentinel"

    mkdir -p /run/pleiades /var/lib/.maia 2>/dev/null || true

    container=$(container_context 2>/dev/null | head -1)
    [[ -z "$container" ]] && container="none"

    for p in /host/proc /mnt/host/proc /run/host/proc /hostfs/proc; do
        if [[ -r "$p/1/status" ]]; then host_proc="$p"; break; fi
    done

    for p in /host /mnt/host /run/host /hostfs; do
        if [[ -r "$p/etc/os-release" ]] || [[ -d "$p/Windows/System32" ]]; then host_root="$p"; break; fi
    done

    for p in /host/run/systemd/private /mnt/host/run/systemd/private /run/host/run/systemd/private /hostfs/run/systemd/private; do
        if [[ -S "$p" ]]; then host_systemd="$p"; break; fi
    done

    for p in /var/run/docker.sock /run/docker.sock /host/var/run/docker.sock /mnt/host/var/run/docker.sock /run/host/var/run/docker.sock; do
        if [[ -S "$p" ]]; then host_container_socket="$p"; break; fi
    done

    if [[ -d /mnt/c/Windows/System32 ]]; then
        windows_host_files="/mnt/c"
    fi

    if [[ "$host_proc" != "absent" ]] || [[ "$host_root" != "absent" ]] || [[ "$host_systemd" != "absent" ]] || [[ "$host_container_socket" != "absent" ]] || [[ "$windows_host_files" != "absent" ]]; then
        mode="host-bridge"
    fi

    {
        echo "schema=pleiades-host-bridge-v1"
        echo "component=$component"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "runtime_env=${ENV:-unknown}"
        echo "container_context=$container"
        echo "systemd_usable=$(systemd_usable && echo yes || echo no)"
        echo "mode=$mode"
        echo "host_proc=$host_proc"
        echo "host_root=$host_root"
        echo "host_systemd=$host_systemd"
        echo "host_container_socket=$host_container_socket"
        echo "windows_host_files=$windows_host_files"
        echo "owner_visible=yes"
        echo "attacker_decoy_profile=enabled"
    } > "$tmp" 2>/dev/null && mv "$tmp" "$state_file" 2>/dev/null || true

    cp "$state_file" "$owner_copy" 2>/dev/null || true
    chmod 0644 "$state_file" "$owner_copy" 2>/dev/null || true
    printf 'HOST_BRIDGE_MODE|%s|%s|%s\n' "$component" "$mode" "$container" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
}


# ZOD_ID
# ==================================================================
# PLEIADES ATLAS – OMNIVERSAL ORCHESTRATOR (WSL / DGX Spark / VPS)
# ==================================================================
# Environment‑aware resource limits, BGP hijack detection,
# thermal anomaly monitoring, threat scoring, mode switching,
# thrall deployment, pleiades-rebirth/containment coordination.
# ==================================================================

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Must be run as root." >&2; exit 1
fi

# ------------------------------------------------------------
# ------------------------------------------------------------
# 0. Environment detection
# ------------------------------------------------------------
ENV="unknown"
IS_BARE_METAL=false
IS_WSL=false
IS_VPS=false

if grep -qi microsoft /proc/version 2>/dev/null; then
    ENV="wsl"
    IS_WSL=true
elif [[ -d /sys/firmware/efi ]] && ! systemd-detect-virt --container &>/dev/null && ! systemd-detect-virt --vm &>/dev/null; then
    ENV="bare-metal"
    IS_BARE_METAL=true
else
    if dmidecode -s system-manufacturer 2>/dev/null | grep -qiE "kvm|xen|vmware|virtualbox"; then
        ENV="vps"
        IS_VPS=true
    else
        ENV="bare-metal"
        IS_BARE_METAL=true
    fi
fi

# ------------------------------------------------------------
# 1. Environment‑specific resource limits
# ------------------------------------------------------------
MAX_OPEN_FILES=4096
MEMORY_LIMIT=3764M
CPU_QUOTA=400%
THRALL_MAX_FLOODS=3
THRALL_INTERVAL=3

# Fallback for initial run
[[ "$MAX_OPEN_FILES" == "4096" ]] && {
    if [[ "$ENV" == "wsl" ]]; then
        MAX_OPEN_FILES=4096; MEMORY_LIMIT="1G"; CPU_QUOTA="100%"
        THRALL_MAX_FLOODS=3; THRALL_INTERVAL=3
    elif [[ "$ENV" == "bare-metal" ]]; then
        MAX_OPEN_FILES=1048576; MEMORY_LIMIT="4G"; CPU_QUOTA="400%"
        THRALL_MAX_FLOODS=10; THRALL_INTERVAL=1
    else
        MAX_OPEN_FILES=65536; MEMORY_LIMIT="2G"; CPU_QUOTA="200%"
        THRALL_MAX_FLOODS=5; THRALL_INTERVAL=2
    fi
}

# ------------------------------------------------------------
# 2. Anti‑BGP hijack detection
# ------------------------------------------------------------
bgp_hijack_detected() {
    local cache="/run/pleiades/asn_baseline"
    local my_ip asn
    my_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) || return 1
    asn=$(curl -s --max-time 5 "https://api.bgpview.io/ip/${my_ip}" \
        2>/dev/null | grep -o '"asn":[0-9]*' | head -1 | grep -o '[0-9]*')
    [[ -z "$asn" ]] && return 1
    if [[ ! -f "$cache" ]]; then
        echo "$asn" > "$cache"; return 1
    fi
    [[ "$(cat "$cache")" != "$asn" ]]
}

# ------------------------------------------------------------
# 3. Thermal/side‑channel anomaly detection
# ------------------------------------------------------------
thermal_anomaly() {
    local temp=0
    local paths=("/host/sys/class/thermal/thermal_zone0/temp" "/sys/class/thermal/thermal_zone0/temp" "/host/sys/class/thermal/thermal_zone1/temp" "/sys/class/thermal/thermal_zone1/temp")
    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then
            temp=$(cat "$p"); temp=$((temp / 1000)); break
        fi
    done
    if [[ $temp -eq 0 ]] && command -v sensors &>/dev/null; then
        temp=$(sensors | grep -oP 'Package id 0: \+\K[0-9]+' | head -1)
    fi
    local load=$(uptime | awk -F'load ameropege:' '{print $2}' | cut -d',' -f1 | tr -d ' ')
    if [[ $temp -gt 85 ]] && (( $(echo "$load < 2.0" | bc -l) )); then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# 4. Build Go threat calculator (reads FIFO, adaptive scoring)
# ------------------------------------------------------------
build_go_threat_calc() {
    cat > /tmp/threat_calc.go << 'GO_THREAT'
package main

import (
    "bufio"
    "fmt"
    "io"
    "os"
    "syscall"
    "os/exec"
    "strings"
    "sync/atomic"
    "time"
)

var threatScore int64
var pleiadesRebirthNeeded bool
var containmentTriggered bool

func reportToPleiadesNexus(msg string) {
    f, err := os.OpenFile("/run/pleiades/pleiades-nexus_fifo", os.O_WRONLY|os.O_APPEND|syscall.O_NONBLOCK, 0666)
    if err == nil {
        defer f.Close()
        fmt.Fprintln(f, msg)
    }
}

func updateScore(delta int64) {
    atomic.AddInt64(&threatScore, delta)
}

func getScore() int64 {
    return atomic.LoadInt64(&threatScore)
}

func parseLine(line string) {
    if strings.HasPrefix(line, "ANOMALY|") || strings.HasPrefix(line, "NEW_ANOMALY|") {
        updateScore(10)
    } else if strings.HasPrefix(line, "RATE_LIMITED|") {
        updateScore(5)
    } else if strings.HasPrefix(line, "CREDENTIAL_FINDING|") {
        updateScore(15)
    } else if strings.HasPrefix(line, "PROXY|") {
        updateScore(20)
    } else if strings.HasPrefix(line, "HARVESTED|") {
        updateScore(8)
    } else if strings.HasPrefix(line, "HOSTILE_RECON|") {
        updateScore(6)
    } else if strings.HasPrefix(line, "KERNEL_TRAP|") {
        updateScore(25)
    } else if strings.HasPrefix(line, "FORENSIC_OBSERVATION|score=") {
        parts := strings.SplitN(line, "|", 3)
        if len(parts) >= 2 {
            scorePart := strings.TrimPrefix(parts[1], "score=")
            var fs int64
            fmt.Sscanf(scorePart, "%d", &fs)
            updateScore(fs)
        }
        if strings.Contains(line, "PROMISCUOUS_MODE") || strings.Contains(line, "KERNEL_MODULE_SPIKE") {
            updateScore(20)
        }
    } else if strings.HasPrefix(line, "BGP_HIJACK") || strings.HasPrefix(line, "THERMAL_ANOMALY") {
        updateScore(50)
        pleiadesRebirthNeeded = true
    } else if strings.Contains(line, "PLEIADES_REBIRTH_TRIGGERED") {
        pleiadesRebirthNeeded = true
        reportToPleiadesNexus("ZOD_PLEIADES_REBIRTH_ACK")
        os.WriteFile("/run/pleiades/pleiades-rebirth_acknowledged", []byte("done"), 0644)
    } else if strings.Contains(line, "CONTAINMENT_TRIGGERED") {
        containmentTriggered = true
        atomic.StoreInt64(&threatScore, 0)
        reportToPleiadesNexus("ZOD_containment_ACK")
    }
}

func monitorFifo() {
    logPath := "/run/pleiades/pleiades-nexus_fifo"
    var offset int64
    for {
        f, err := os.Open(logPath)
        if err != nil {
            time.Sleep(5 * time.Second)
            continue
        }
        fi, err := f.Stat()
        if err == nil && fi.Size() > offset {
            f.Seek(offset, io.SeekStart)
            scanner := bufio.NewScanner(f)
            for scanner.Scan() {
                parseLine(scanner.Text())
            }
            offset, _ = f.Seek(0, io.SeekCurrent)
        }
        f.Close()
        time.Sleep(1 * time.Second)
    }
}

func sendCommand(sock string, cmd string) {
    sh := fmt.Sprintf("printf '%%s\\n' %q | socat - UNIX-CONNECT:%s 2>/dev/null || printf '%%s\\n' %q | nc -U %s -w 1 2>/dev/null || true", cmd, sock, cmd, sock)
    exec.Command("sh", "-c", sh).Run()
}

func main() {
    go monitorFifo()
    decayTicker := time.NewTicker(30 * time.Minute)
    for {
        select {
        case <-decayTicker.C:
            cur := atomic.LoadInt64(&threatScore)
        newScore := int64(float64(cur) * 0.7)
        if newScore == cur && cur > 0 { newScore-- }
        atomic.StoreInt64(&threatScore, newScore)
        default:
        }
        score := getScore()
        var modeStr string
        if score >= 8 {
            modeStr = "AGGRESSIVE"
            sendCommand("/run/pleiades/taygete.sock", "aggressive")
            sendCommand("/run/pleiades/alcyone.sock", "active")
            reportToPleiadesNexus(fmt.Sprintf("ZOD_MODE_AGGRESSIVE|%d", score))
        } else if score >= 2 {
            modeStr = "PASSIVE"
            sendCommand("/run/pleiades/alcyone.sock", "passive")
            reportToPleiadesNexus(fmt.Sprintf("ZOD_MODE_PASSIVE|%d", score))
        } else {
            modeStr = "NORMAL"
        }
        os.WriteFile("/run/pleiades/atlas_mode", []byte(modeStr), 0644)
        if pleiadesRebirthNeeded && !containmentTriggered {
            sendCommand("/run/pleiades/taygete.sock", "resurrect")
            sendCommand("/run/pleiades/alcyone.sock", "resurrect")
            reportToPleiadesNexus("ZOD_PLEIADES_REBIRTH_SIGNAL")
            pleiadesRebirthNeeded = false
        }
        if containmentTriggered {
            // Reset everything
            atomic.StoreInt64(&threatScore, 0)
            containmentTriggered = false
        }
        time.Sleep(5 * time.Second)
    }
}
GO_THREAT
    go build -o /usr/local/bin/threat_calc /tmp/threat_calc.go
    chmod +x /usr/local/bin/threat_calc
    rm -f /tmp/threat_calc.go
}

# ------------------------------------------------------------
# 5. Build Go thrall deployer (Bobby Long with environment limits)
# ------------------------------------------------------------
build_go_thrall() {
    cat > /tmp/thrall.go << 'GO_THRALL'
package main

import (
    "bufio"
    "fmt"
    "io"
    "os"
    "syscall"
    "os/exec"
    "strings"
    "time"
)

const (
    thrallMaxFloods = 3
    thrallInterval  = 3
    banner          = "\n   ____   ____   _      _   _   _   _   ____   _   _   ____   \n  | __ ) | __ ) | |    | | | | | \\ | | / ___| | \\ | | / ___|  \n  |  _ \\ |  _ \\ | |    | | | | |  \\| | | |  _  |  \\| | | |  _ \n  | |_) || |_) || |___ | |_| | | |\\  | | |_| || |\\  | | |_| | \n  |____/ |____/ |_____| \\___/  |_| \\_|  \\____||_| \\_|  \\____| \n  \n   B   O   B   B   Y       L   O   N   G   !   !   ~\n"
)

func reportToPleiadesNexus(msg string) {
    f, _ := os.OpenFile("/run/pleiades/pleiades-nexus_fifo", os.O_WRONLY|os.O_APPEND|syscall.O_NONBLOCK, 0666)
    if f != nil {
        defer f.Close()
        fmt.Fprintln(f, msg)
    }
}

func deployThrall(ip string) {
    script := fmt.Sprintf("/tmp/thrall_%s.sh", strings.ReplaceAll(ip, ".", "_"))
    content := fmt.Sprintf(`#!/bin/bash
TARGET_IP="%s"
MAX_FLOODS=%d
INTERVAL=%d
BANNER='%s'

get_terminals() {
    who | grep -E "$TARGET_IP" | awk '{print "/dev/"$2}'
    for tty in /dev/pts/*; do
        if [[ -w "$tty" ]]; then
            owner=$(stat -c %%U "$tty" 2>/dev/null)
            ip=$(who | grep "$owner" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            [[ "$ip" == "$TARGET_IP" ]] && echo "$tty"
        fi
    done | sort -u
}

live_ttys=()
for tty in $(get_terminals); do
    if echo "test" > "$tty" 2>/dev/null; then
        live_ttys+=("$tty")
    fi
done

if [[ ${#live_ttys[@]} -eq 0 ]]; then
    exit 0
fi

for i in $(seq 1 "$MAX_FLOODS"); do
    for tty in "${live_ttys[@]}"; do
        echo "$BANNER" > "$tty" 2>/dev/null
    done
    sleep "$INTERVAL"
done
rm -f "$0"
`, ip, thrallMaxFloods, thrallInterval, banner)
    os.WriteFile(script, []byte(content), 0755)
    cmd := exec.Command("/bin/bash", script)
    cmd.Start()
    reportToPleiadesNexus(fmt.Sprintf("THRALL_DEPLOYED|%s", ip))
}

func main() {
    deployed := make(map[string]bool)
    var offset int64
    for {
        f, err := os.Open("/run/pleiades/attacker_ips")
        if err == nil {
            fi, _ := f.Stat()
            if fi.Size() > offset {
                f.Seek(offset, io.SeekStart)
                scanner := bufio.NewScanner(f)
                for scanner.Scan() {
                    ip := strings.TrimSpace(scanner.Text())
                    if ip != "" && !deployed[ip] {
                        deployThrall(ip)
                        deployed[ip] = true
                    }
                }
                offset, _ = f.Seek(0, io.SeekCurrent)
            }
            f.Close()
        }
        time.Sleep(5 * time.Second)
    }
}
GO_THRALL
    sed -i -E "s/^const thrallMaxFloods = .*/const thrallMaxFloods = $THRALL_MAX_FLOODS/" /tmp/thrall.go
    sed -i -E "s/^const thrallInterval = .*/const thrallInterval = $THRALL_INTERVAL/" /tmp/thrall.go
    go build -o /usr/local/bin/thrall_deployer /tmp/thrall.go
    chmod +x /usr/local/bin/thrall_deployer
    rm -f /tmp/thrall.go
}

# ------------------------------------------------------------
# 6. Build Bash helpers (mode switching, thrall trigger)
# ------------------------------------------------------------
build_bash_helpers() {
    cat > /etc/atlas/switch_modes.sh << 'SWITCH'
#!/bin/bash
# Tails pleiades-nexus log and sends commands to Alcyone/Taygete sockets
unix_send() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$2" 2>/dev/null || printf '%s\n' "$1" | nc -U "$2" -w 1 2>/dev/null || true; }
tail -n 0 -F /run/pleiades/pleiades-nexus_fifo 2>/dev/null | while read -r line; do
    if [[ "$line" =~ ^ZOD_MODE_(AGGRESSIVE|PASSIVE) ]]; then
        mode=$(echo "$line" | cut -d'|' -f1 | cut -d'_' -f3)
        if [[ "$mode" == "AGGRESSIVE" ]]; then
            unix_send "aggressive" /run/pleiades/taygete.sock
            unix_send "active" /run/pleiades/alcyone.sock
        elif [[ "$mode" == "PASSIVE" ]]; then
            unix_send "passive" /run/pleiades/alcyone.sock
        fi
    fi
done
SWITCH
    chmod +x /etc/atlas/switch_modes.sh
}

# ------------------------------------------------------------
# 7. Install systemd service (Atlas pleiades-swarm)
# ------------------------------------------------------------
install_systemd() {
    if ! systemd_usable; then
        pkg_install screen
        screen -dmS atlas_pleiades-swarm /usr/local/bin/atlas_pleiades-swarm
    else
        cat > /etc/systemd/system/atlas-omniversal.service << SERVICE
[Unit]
Description=General Atlas Omniversal Orchestrator
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/atlas_pleiades-swarm
Restart=always
RestartSec=5
LimitNOFILE=$MAX_OPEN_FILES
MemoryMax=$MEMORY_LIMIT
CPUQuota=$CPU_QUOTA

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable atlas-omniversal.service
        systemctl start atlas-omniversal.service
    fi

    # Build Go pleiades-swarm that runs threat calculator and thrall deployer
    cat > /tmp/atlas_pleiades-swarm.go << 'GO_HIVE'
package main

import (
    "log"
    "os/exec"
    "time"
)

type Proc struct {
    Name string
    Cmd  *exec.Cmd
}

func (p *Proc) run() {
    defer func() {
        if r := recover(); r != nil {
            log.Printf("[pleiades-swarm/%s] panic: %v — restarting in 3s", p.Name, r)
            time.Sleep(3 * time.Second)
            go p.run()
        }
    }()
    for {
        cmd := exec.Command(p.Cmd.Args[0], p.Cmd.Args[1:]...)
        if err := cmd.Run(); err != nil {
            log.Printf("[pleiades-swarm/%s] died: %v — respawning in 2s", p.Name, err)
        }
        time.Sleep(2 * time.Second)
    }
}

func main() {
    procs := []*Proc{
        {Name: "threat_calc", Cmd: exec.Command("/usr/local/bin/threat_calc")},
        {Name: "thrall_deployer", Cmd: exec.Command("/usr/local/bin/thrall_deployer")},
        {Name: "switch_modes", Cmd: exec.Command("/etc/atlas/switch_modes.sh")},
        {Name: "forensic_scanner", Cmd: exec.Command("/usr/local/bin/pleiades-forensic-scanner.sh")},
    }
    for _, p := range procs {
        go p.run()
    }
    select {}
}
GO_HIVE
    go build -o /usr/local/bin/atlas_pleiades-swarm /tmp/atlas_pleiades-swarm.go
    chmod +x /usr/local/bin/atlas_pleiades-swarm
    rm -f /tmp/atlas_pleiades-swarm.go
}

# ------------------------------------------------------------
# 8. Background monitors for BGP and thermal threats
# ------------------------------------------------------------
monitor_threats() {
    while true; do
        if bgp_hijack_detected; then
            logger -t atlas "BGP hijack detected – signalling Pleiades Nexus"
            ( echo "BGP_HIJACK" >> /run/pleiades/pleiades-nexus_fifo & )
fi
        if thermal_anomaly; then
            logger -t atlas "Thermal anomaly detected – signalling Pleiades Nexus"
            ( echo "THERMAL_ANOMALY" >> /run/pleiades/pleiades-nexus_fifo & )
fi
        sleep 30
    done
}

# ------------------------------------------------------------
# 9. Main
# ------------------------------------------------------------
main() {
    if [[ "$ENV" == "wsl" ]]; then
        pkg_install golang bc lm-sensors traceroute socat openbsd-netcat
    elif [[ "$ENV" == "bare-metal" ]]; then
        pkg_install golang bc lm-sensors traceroute socat openbsd-netcat
    else
        pkg_install golang bc lm-sensors traceroute socat openbsd-netcat
    fi

    mkdir -p /etc/atlas /run/pleiades
    host_bridge_capability_report "atlas"
    register_pleiades-swarm_capability "atlas" "threat-orchestrator" "threat-scoring,mode-switch,thrall-dispatch,forensic-integration"
    wait_for alcyone 2
    wait_for taygete 2
    build_go_threat_calc
    build_go_thrall
    build_bash_helpers
    install_systemd
    monitor_threats &
    SELF="$0"
    cat > /usr/local/sbin/install-atlas-omniversal.sh << INST
#!/bin/bash
exec bash "$SELF"
INST
    chmod +x /usr/local/sbin/install-atlas-omniversal.sh
    signal_ready atlas
    echo "General Atlas Omniversal deployed on $ENV."
}

main












# --- MAIA EVENT HOOK ---
_maia_hook() {
    [[ -S "/run/maia.sock" ]] && printf '%s\n' "$1" | (socat - UNIX-CONNECT:/run/maia.sock 2>/dev/null || nc -U /run/maia.sock -w 1 2>/dev/null) || true
}
# --- END MAIA EVENT HOOK ---
