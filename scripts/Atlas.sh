#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLEIADES_CONTAINER_ROOT="${PLEIADES_CONTAINER_ROOT:-$(dirname "$SCRIPT_DIR")}"
PLEIADES_REPO_ROOT="${PLEIADES_REPO_ROOT:-$(dirname "$PLEIADES_CONTAINER_ROOT")}"


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
            lm-sensors) continue ;;
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


# PLEIADES_NEXUS_ID
# ==================================================================
# PLEIADES_NEXUS containment – OMNIVERSAL (WSL / DGX Spark / VPS)
# ==================================================================
# Environment‑aware resource limits, BGP hijack detection,
# thermal anomaly monitoring, threat aggregation, botnet blocklist.
# ==================================================================

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Must be run as root." >&2; exit 1
fi

# ------------------------------------------------------------
# 0. Environment detection
# ------------------------------------------------------------
ENV="unknown"
IS_WSL=false
IS_BARE_METAL=false
IS_VPS=false

if grep -qi microsoft /proc/version 2>/dev/null; then
    ENV="wsl"
    IS_WSL=true
elif [[ -d /sys/firmware/efi ]] && ! systemd-detect-virt --container -q 2>/dev/null && ! systemd-detect-virt --vm -q 2>/dev/null; then
    ENV="bare_metal"
    IS_BARE_METAL=true
else
    if dmidecode -s system-manufacturer 2>/dev/null | grep -qiE "kvm|xen|vmware|virtualbox"; then
        ENV="vps"
        IS_VPS=true
    else
        ENV="bare"
    fi
fi
echo "Detected environment: $ENV"

# ------------------------------------------------------------
# 1. Environment‑specific resource limits
# ------------------------------------------------------------
MAX_OPEN_FILES=4096
MEMORY_LIMIT=3764M
CPU_QUOTA=400%
THREAT_THRESHOLD=500

# Fallback for initial run
[[ "$MAX_OPEN_FILES" == "4096" ]] && {
    if [[ "$ENV" == "wsl" ]]; then
        MAX_OPEN_FILES=4096
        MEMORY_LIMIT="1G"
        CPU_QUOTA="100%"
        THREAT_THRESHOLD=2000
    elif [[ "$ENV" == "bare_metal" ]]; then
        MAX_OPEN_FILES=1048576
        MEMORY_LIMIT="8G"
        CPU_QUOTA="400%"
        THREAT_THRESHOLD=5000
    else
        MAX_OPEN_FILES=65536
        MEMORY_LIMIT="2G"
        CPU_QUOTA="200%"
        THREAT_THRESHOLD=5000
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
# 4. Build Go containment monitor (reads FIFO, aggregates threats)
# ------------------------------------------------------------
build_go_containment_controller() {
    cat > /tmp/containment_controller.go << 'GO_IMP'
package main

import (
    "bufio"
    "fmt"
    "io"
    "log"
    "os"
    "syscall"
    "os/exec"
    "strings"
    "sync/atomic"
    "time"
)

var attackerCount int64
var contained bool
const threshold = 500

func reportToPleiadesNexus(msg string) {
    f, err := os.OpenFile("/run/pleiades/pleiades-nexus_fifo", os.O_WRONLY|os.O_APPEND|syscall.O_NONBLOCK, 0666)
    if err == nil {
        defer f.Close()
        fmt.Fprintln(f, msg)
    }
}

func addToBlocklist(ip string) {
    if ip == "" {
        return
    }
    // Ensure the set exists first
    exec.Command("nft", "add", "set", "inet", "filter", "blocklist",
        "{ type ipv4_addr; flags interval; }").Run()
    exec.Command("nft", "add", "element", "inet", "filter", "blocklist",
        "{ "+ip+" }").Run()
    reportToPleiadesNexus(fmt.Sprintf("BLOCKLIST_ADD|%s", ip))
}

func archiveLogs() {
    stamp := time.Now().Format("20060102T150405Z")
    archive := fmt.Sprintf("/var/lib/pleiades-team/forensics/logs_%s.tar.gz", stamp)
    os.MkdirAll("/var/lib/pleiades-team/forensics", 0750)
    exec.Command("journalctl", "-o", "json", "--no-pager",
        "--output-file=/tmp/pleiades_journal_"+stamp+".json").Run()
    exec.Command("tar", "-czf", archive,
        "/tmp/pleiades_journal_"+stamp+".json",
        "/run/pleiades/pleiades-nexus_fifo").Run()
    os.Remove("/tmp/pleiades_journal_" + stamp + ".json")
    exec.Command("journalctl", "--rotate").Run()
    exec.Command("journalctl", "--vacuum-time=1s").Run()
    reportToPleiadesNexus(fmt.Sprintf("LOGS_ARCHIVED|%s", archive))
}

func contain() {
    if contained {
        return
    }
    contained = true
    log.Println("Threat threshold exceeded – initiating Pleiades Nexus containment")
    reportToPleiadesNexus("CONTAINMENT_TRIGGERED")

    // Block all current attackers from conntrack
    cmd := exec.Command("conntrack", "-L")
    out, err := cmd.Output()
    if err == nil {
        lines := strings.Split(string(out), "\n")
        for _, line := range lines {
            if strings.Contains(line, "src=") {
                parts := strings.Split(line, "src=")
                if len(parts) > 1 {
                    ip := strings.Split(parts[1], " ")[0]
                    if !strings.HasPrefix(ip, "127.") && !strings.HasPrefix(ip, "192.168.") &&
                        !strings.HasPrefix(ip, "10.") && !strings.HasPrefix(ip, "172.16.") {
                        addToBlocklist(ip)
                    }
                }
            }
        }
    }

    archiveLogs()

    // Notify other components
    os.WriteFile("/run/pleiades/pleiades-nexus_complete", []byte("done"), 0644)
}

func main() {
    logPath := "/run/pleiades/pleiades-nexus_fifo"
    var offset int64
    for {
        if _, err := os.Stat("/run/pleiades/bgp_hijack"); err == nil {
            log.Println("BGP hijack detected – triggering containment")
            contain()
            return
        }
        if _, err := os.Stat("/run/pleiades/thermal_anomaly"); err == nil {
            log.Println("Thermal anomaly detected – triggering containment")
            contain()
            return
        }

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
                line := scanner.Text()
                if strings.HasPrefix(line, "ANOMALY|") || strings.HasPrefix(line, "RATE_LIMITED|") ||
                    strings.HasPrefix(line, "NEW_ANOMALY|") || strings.HasPrefix(line, "CREDENTIAL_FINDING|") {
                    parts := strings.Split(line, "|")
                    if len(parts) >= 2 {
                        ip := parts[1]
                        if !strings.HasPrefix(ip, "127.") && !strings.HasPrefix(ip, "192.168.") &&
                            !strings.HasPrefix(ip, "10.") && !strings.HasPrefix(ip, "172.16.") {
                            atomic.AddInt64(&attackerCount, 1)
                        }
                    }
                }
                if strings.Contains(line, "CONTAIN_NOW") {
                    f.Close()
                    contain()
                    return
                }
            }
            offset, _ = f.Seek(0, io.SeekCurrent)
        }
        f.Close()

        if atomic.LoadInt64(&attackerCount) >= threshold {
            contain()
            return
        }
        time.Sleep(10 * time.Second)
    }
}
GO_IMP
    sed -i "s/500/$THREAT_THRESHOLD/" /tmp/containment_controller.go
    go build -o /usr/local/bin/containment_controller /tmp/containment_controller.go
    chmod +x /usr/local/bin/containment_controller
    rm -f /tmp/containment_controller.go
}

# ------------------------------------------------------------
# 5. Build Rust fallback (if Go fails)
# ------------------------------------------------------------
build_rust_containment_controller() {
    cat > /tmp/containment_controller.rs << 'RUST_IMP'
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
use std::io::{BufRead, BufReader, Write};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

static ATTACKER_COUNT: AtomicUsize = AtomicUsize::new(0);
const THRESHOLD: usize = 500;

fn report(msg: &str) {
    if let Ok(mut fifo) = OpenOptions::new().write(true).append(true).custom_flags(0o4000).open("/run/pleiades/pleiades-nexus_fifo") {
        let _ = writeln!(fifo, "{}", msg);
    }
}

fn add_blocklist(ip: &str) {
    let set_spec = "{ type ipv4_addr; flags interval; }";
    Command::new("nft").args(&["add", "set", "inet", "filter", "blocklist", set_spec]).output().ok();
    let elem = format!("{{ {} }}", ip);
    Command::new("nft").args(&["add", "element", "inet", "filter", "blocklist", &elem]).output().ok();
    report(&format!("BLOCKLIST_ADD|{}", ip));
}

fn archive_logs() {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    let archive = format!("/var/lib/pleiades-team/forensics/logs_{}.tar.gz", ts);
    std::fs::create_dir_all("/var/lib/pleiades-team/forensics").ok();
    let journal_tmp = format!("/tmp/pleiades_journal_{}.json", ts);
    Command::new("journalctl").args(&["-o", "json", "--no-pager",
        &format!("--output-file={}", journal_tmp)]).output().ok();
    Command::new("tar").args(&["-czf", &archive, &journal_tmp,
        "/run/pleiades/pleiades-nexus_fifo"]).output().ok();
    std::fs::remove_file(&journal_tmp).ok();
    Command::new("journalctl").arg("--rotate").output().ok();
    Command::new("journalctl").arg("--vacuum-time=1s").output().ok();
    report(&format!("LOGS_ARCHIVED|{}", archive));
}

fn contain() {
    report("CONTAINMENT_TRIGGERED");
    if let Ok(out) = Command::new("conntrack").arg("-L").output() {
        let s = String::from_utf8_lossy(&out.stdout);
        for line in s.lines() {
            if let Some(ip) = line.split("src=").nth(1).and_then(|x| x.split_whitespace().next()) {
                if !ip.starts_with("127.") && !ip.starts_with("192.168.") && !ip.starts_with("10.") && !ip.starts_with("172.16.") {
                    add_blocklist(ip);
                }
            }
        }
    }
    archive_logs();
    std::fs::write("/run/pleiades/pleiades-nexus_complete", "done").ok();
}

fn main() {
    let fifo_path = "/run/pleiades/pleiades-nexus_fifo";
    loop {
        if let Ok(file) = OpenOptions::new().read(true).open(fifo_path) {
            let reader = BufReader::new(file);
            for line in reader.lines() {
                if let Ok(line) = line {
                    if line.starts_with("ANOMALY|") || line.starts_with("RATE_LIMITED|") ||
                       line.starts_with("NEW_ANOMALY|") || line.starts_with("CREDENTIAL_FINDING|") {
                        let parts: Vec<&str> = line.split('|').collect();
                        if parts.len() >= 2 {
                            let ip = parts[1];
                            if !ip.starts_with("127.") && !ip.starts_with("192.168.") && !ip.starts_with("10.") && !ip.starts_with("172.16.") {
                                let prev = ATTACKER_COUNT.fetch_add(1, Ordering::SeqCst);
                                if prev + 1 >= THRESHOLD {
                                    contain();
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        }
        thread::sleep(Duration::from_secs(10));
    }
}
RUST_IMP
    sed -i "s/500/$THREAT_THRESHOLD/" /tmp/containment_controller.rs
    rustc -o /usr/local/bin/containment_controller_rust /tmp/containment_controller.rs
    chmod +x /usr/local/bin/containment_controller_rust
    rm -f /tmp/containment_controller.rs
}

# ------------------------------------------------------------
# 6. Build Bash fallback (if both Go and Rust fail)
# ------------------------------------------------------------
build_bash_containment_controller() {
    cat > /usr/local/bin/containment_controller_bash.sh << 'BASH_IMP'
#!/bin/bash
THRESHOLD=500
COUNT_FILE="/run/pleiades/attacker_count"
echo 0 > "$COUNT_FILE"

report() { ( echo "$1" >> /run/pleiades/pleiades-nexus_fifo & ); }

while true; do
    # Check for BGP/thermal flags
    if [[ -f /run/pleiades/bgp_hijack ]] || [[ -f /run/pleiades/thermal_anomaly ]]; then
        report "CONTAINMENT_TRIGGERED"
        nft add set inet filter blocklist '{ type ipv4_addr; flags interval; }' 2>/dev/null
        conntrack -L | grep -oP 'src=\K[0-9.]+' | sort -u | while read -r ip; do
            case "$ip" in 127.*|192.168.*|10.*|172.16.*) continue ;; esac
            nft add element inet filter blocklist "{ $ip }"
            report "BLOCKLIST_ADD|$ip"
        done
        _stamp=$(date -u +%Y%m%dT%H%M%SZ)
        mkdir -p /var/lib/pleiades-team/forensics
        journalctl -o json --no-pager > "/tmp/pleiades_journal_${_stamp}.json" 2>/dev/null
        tar -czf "/var/lib/pleiades-team/forensics/logs_${_stamp}.tar.gz" \
            "/tmp/pleiades_journal_${_stamp}.json" /run/pleiades/pleiades-nexus_fifo 2>/dev/null
        rm -f "/tmp/pleiades_journal_${_stamp}.json"
        journalctl --rotate && journalctl --vacuum-time=1s
        report "LOGS_ARCHIVED|/var/lib/pleiades-team/forensics/logs_${_stamp}.tar.gz"
        touch /run/pleiades/pleiades-nexus_complete
        break
    fi
    # Tail new lines from log file (non-blocking)
    new_lines=$(tail -n +"$(($(cat "$COUNT_FILE" 2>/dev/null || echo 0)+1))" \
        /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true)
    while IFS= read -r line; do
        if [[ "$line" =~ ^(ANOMALY|RATE_LIMITED|NEW_ANOMALY|CREDENTIAL_FINDING) ]]; then
            ip=$(echo "$line" | cut -d'|' -f2)
            if [[ ! "$ip" =~ ^(127|192\.168|10|172\.16) ]]; then
                count=$(cat "$COUNT_FILE")
                count=$((count+1))
                echo "$count" > "$COUNT_FILE"
                if [[ $count -ge $THRESHOLD ]]; then
                    report "CONTAINMENT_TRIGGERED"
                    nft add set inet filter blocklist '{ type ipv4_addr; flags interval; }' 2>/dev/null
                    conntrack -L | grep -oP 'src=\K[0-9.]+' | sort -u | while read -r ip2; do
                        case "$ip2" in 127.*|192.168.*|10.*|172.16.*) continue ;; esac
                        nft add element inet filter blocklist "{ $ip2 }"
                        report "BLOCKLIST_ADD|$ip2"
                    done
                    _stamp=$(date -u +%Y%m%dT%H%M%SZ)
                    mkdir -p /var/lib/pleiades-team/forensics
                    journalctl -o json --no-pager > "/tmp/pleiades_journal_${_stamp}.json" 2>/dev/null
                    tar -czf "/var/lib/pleiades-team/forensics/logs_${_stamp}.tar.gz" \
                        "/tmp/pleiades_journal_${_stamp}.json" /run/pleiades/pleiades-nexus_fifo 2>/dev/null
                    rm -f "/tmp/pleiades_journal_${_stamp}.json"
                    journalctl --rotate && journalctl --vacuum-time=1s
                    report "LOGS_ARCHIVED|/var/lib/pleiades-team/forensics/logs_${_stamp}.tar.gz"
                    touch /run/pleiades/pleiades-nexus_complete
                    break 2
                fi
            fi
        fi
    done <<< "$new_lines"
done
BASH_IMP
    sed -i "s/500/$THREAT_THRESHOLD/" /usr/local/bin/containment_controller_bash.sh
    chmod +x /usr/local/bin/containment_controller_bash.sh
}


# ------------------------------------------------------------
# 7. Host bridge network monitor (read-only, owner-granted views)
# ------------------------------------------------------------
build_host_bridge_monitor() {
    cat > /usr/local/bin/host_bridge_monitor.sh << 'HOST_MONITOR'
#!/bin/bash
set -euo pipefail
STATE_FILE="${PURPLE_HOST_BRIDGE_STATE:-/run/pleiades/host_bridge_capabilities}"
FIFO="/run/pleiades/pleiades-nexus_fifo"
BASE_DIR="/var/lib/pleiades-team/host-bridge"
mkdir -p "$BASE_DIR" /run/pleiades

event() { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }
value_of() {
    local key="$1"
    grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}
sha_of_file() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then sha256sum "$file" | awk '{print $1}'; else cksum "$file" | awk '{print $1}'; fi
}
observe_current_namespace() {
    local tmp="$BASE_DIR/current_ns_net.tmp"
    if command -v ss &>/dev/null; then
        ss -Htan 2>/dev/null | awk '{print $1,$4,$5}' | sort > "$tmp" || true
    elif command -v netstat &>/dev/null; then
        netstat -tan 2>/dev/null | awk 'NR>2 {print $1,$4,$5,$6}' | sort > "$tmp" || true
    else
        : > "$tmp"
    fi
    local hash; hash=$(sha_of_file "$tmp")
    local base="$BASE_DIR/current_ns_net.sha256"
    if [[ ! -f "$base" ]]; then
        echo "$hash" > "$base"
        event "HOST_NET_BASELINE|current-namespace|$hash"
    elif [[ "$(cat "$base")" != "$hash" ]]; then
        echo "$hash" > "$base"
        event "HOST_NET_CHANGE|current-namespace|$hash"
    else
        event "HOST_NET_OBSERVED|current-namespace|$hash"
    fi
    rm -f "$tmp"
}
observe_host_proc() {
    local host_proc="$1"
    [[ -r "$host_proc/net/tcp" ]] || return 0
    local tmp="$BASE_DIR/host_proc_net.tmp"
    {
        printf 'tcp\n'
        cat "$host_proc/net/tcp" 2>/dev/null || true
        printf 'tcp6\n'
        cat "$host_proc/net/tcp6" 2>/dev/null || true
        printf 'udp\n'
        cat "$host_proc/net/udp" 2>/dev/null || true
        printf 'udp6\n'
        cat "$host_proc/net/udp6" 2>/dev/null || true
    } > "$tmp"
    local hash; hash=$(sha_of_file "$tmp")
    local base="$BASE_DIR/host_proc_net.sha256"
    if [[ ! -f "$base" ]]; then
        echo "$hash" > "$base"
        event "HOST_NET_BASELINE|host-proc|$hash"
    elif [[ "$(cat "$base")" != "$hash" ]]; then
        echo "$hash" > "$base"
        event "HOST_NET_CHANGE|host-proc|$hash"
    else
        event "HOST_NET_OBSERVED|host-proc|$hash"
    fi
    rm -f "$tmp"
}

while true; do
    if [[ ! -f "$STATE_FILE" ]]; then
        event "HOST_BRIDGE_DEGRADED|state-missing"
        sleep 30
        continue
    fi
    mode=$(value_of mode)
    host_proc=$(value_of host_proc)
    host_root=$(value_of host_root)
    host_systemd=$(value_of host_systemd)
    host_container_socket=$(value_of host_container_socket)
    windows_host_files=$(value_of windows_host_files)
    event "HOST_BRIDGE_OBSERVED|mode=${mode:-unknown}|host_proc=${host_proc:-absent}|host_root=${host_root:-absent}|host_systemd=${host_systemd:-absent}|host_container_socket=${host_container_socket:-absent}|windows_host_files=${windows_host_files:-absent}"
    observe_current_namespace
    if [[ -n "${host_proc:-}" && "$host_proc" != "absent" ]]; then
        observe_host_proc "$host_proc"
    fi
    sleep "${PURPLE_HOST_BRIDGE_MONITOR_INTERVAL:-30}"
done
HOST_MONITOR
    chmod +x /usr/local/bin/host_bridge_monitor.sh
}

install_host_bridge_monitor() {
    if ! systemd_usable; then
        pkg_install screen
        screen -dmS host_bridge_monitor /usr/local/bin/host_bridge_monitor.sh
    else
        cat > /etc/systemd/system/host-bridge-monitor.service << SERVICE
[Unit]
Description=Purple Host Bridge Read-Only Monitor
After=network.target pleiades-nexus-omniversal.service

[Service]
Type=simple
ExecStart=/usr/local/bin/host_bridge_monitor.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable host-bridge-monitor.service
        systemctl start host-bridge-monitor.service
    fi
}

build_windows_host_bridge_monitor() {
    cat > /usr/local/bin/windows_host_bridge_monitor.sh << 'WINDOWS_HOST_MONITOR'
#!/bin/bash
set -euo pipefail
FIFO="/run/pleiades/pleiades-nexus_fifo"
BASE="/var/lib/pleiades-team/host-bridge/windows11"
PS="/host/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
mkdir -p "$BASE" /run/pleiades
touch "$FIFO"

event() { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }
sha_file() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then sha256sum "$file" | awk '{print $1}'; else cksum "$file" | awk '{print $1}'; fi
}
collect_once() {
    if [[ ! -x "$PS" ]]; then
        event "WINDOWS_HOST_BRIDGE_DEGRADED|powershell-unavailable"
        return 0
    fi
    local ts tmp hash base_hash ps_rc
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    tmp="$BASE/windows_host_${ts}.txt"
    ps_rc=0
    timeout 20 "$PS" -NoProfile -ExecutionPolicy Bypass -Command '& {
        Write-Output ("UTC=" + (Get-Date).ToUniversalTime().ToString("o"))
        Write-Output ("COMPUTER=" + $env:COMPUTERNAME)
        Write-Output "TCP"
        Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Select-Object -First 300 State,LocalAddress,LocalPort,RemoteAddress,RemotePort,OwningProcess |
            ConvertTo-Csv -NoTypeInformation
        Write-Output "PROC"
        Get-Process -ErrorAction SilentlyContinue |
            Select-Object -First 300 Id,ProcessName,Path |
            ConvertTo-Csv -NoTypeInformation
    }' > "$tmp" 2>&1 || ps_rc=$?
    if [[ $ps_rc -ne 0 ]]; then
        event "WINDOWS_HOST_BRIDGE_DEGRADED|powershell-exit-$ps_rc|$tmp"
    fi
    hash=$(sha_file "$tmp")
    base_hash="$BASE/current.sha256"
    if [[ ! -f "$base_hash" ]]; then
        echo "$hash" > "$base_hash"
        event "WINDOWS_HOST_NET_BASELINE|$hash|$tmp"
    elif [[ "$(cat "$base_hash")" != "$hash" ]]; then
        echo "$hash" > "$base_hash"
        event "WINDOWS_HOST_NET_CHANGE|$hash|$tmp"
    else
        event "WINDOWS_HOST_NET_OBSERVED|$hash|$tmp"
    fi
}

event "WINDOWS_HOST_BRIDGE_READY|read-only"
while true; do
    collect_once
    sleep "${PURPLE_WINDOWS_HOST_BRIDGE_INTERVAL:-30}"
done
WINDOWS_HOST_MONITOR
    chmod +x /usr/local/bin/windows_host_bridge_monitor.sh
}

install_windows_host_bridge_monitor() {
    if [[ ! -e /host/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]]; then
        event "WINDOWS_HOST_BRIDGE_SKIPPED|powershell-bridge-absent"
        return 0
    fi
    if ! systemd_usable; then
        pkg_install screen
        screen -dmS windows_host_bridge_monitor /usr/local/bin/windows_host_bridge_monitor.sh
    else
        cat > /etc/systemd/system/windows-host-bridge-monitor.service << SERVICE
[Unit]
Description=Purple Windows Host Read-Only Bridge Monitor
After=network.target host-bridge-monitor.service

[Service]
Type=simple
ExecStart=/usr/local/bin/windows_host_bridge_monitor.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable windows-host-bridge-monitor.service
        systemctl restart windows-host-bridge-monitor.service
    fi
}


# ------------------------------------------------------------
# 8. Pleiades Swarm substrate control plane (deterministic, policy-gated)
# ------------------------------------------------------------
build_pleiades-swarm_substrate() {
    mkdir -p /etc/pleiades /run/pleiades/{requests,decisions,actions,results,capabilities,state,alien/inbox,alien/outbox} /var/lib/pleiades-team/pleiades-swarm
    touch /run/pleiades/pleiades-nexus_fifo
    if [[ ! -e /opt/brl && -d "${PLEIADES_CONTAINER_ROOT}/opt/brl" ]]; then
        ln -s "${PLEIADES_CONTAINER_ROOT}/opt/brl" /opt/brl 2>/dev/null || true
    fi
    if [[ ! -e /strat && -d "${PLEIADES_CONTAINER_ROOT}/strat" ]]; then
        ln -s "${PLEIADES_CONTAINER_ROOT}/strat" /strat 2>/dev/null || true
    fi
    if [[ -x /opt/brl/bin/brl ]]; then
        ln -sf /opt/brl/bin/brl /usr/local/bin/brl 2>/dev/null || true
    fi
    if [[ -x /opt/brl/bin/strat ]]; then
        ln -sf /opt/brl/bin/strat /usr/local/bin/strat 2>/dev/null || true
    fi

    cat > /etc/pleiades/host-bridge-policy.json <<'HOST_POLICY'
{
  "schema": "pleiades-host-bridge-policy-v1",
  "mode": "owner-authorized-defensive",
  "visibility": {"owner_visible": true, "intruder_nonobvious": true, "stealth_process_hiding": false},
  "allowed_reads": ["process-summary", "listener-summary", "service-health", "bridge-health", "capsule-heartbeat"],
  "allowed_writes": ["status-files", "tamper-evident-alerts", "sealed-evidence-export"],
  "gated_actions": ["restart-pleiades-host-services", "refresh-owner-granted-bridge-mounts", "collect-forensic-bundle"],
  "denied_actions": ["arbitrary-shell", "credential-read", "credential-export", "firewall-mutation", "new-persistence", "lateral-movement", "process-hiding", "firmware-or-boot-modification"],
  "default_decision": "deny",
  "audit": {"append_only": true, "owner_visible": true}
}
HOST_POLICY

    if [[ ! -f /etc/pleiades/pleiades-swarm-policy.json ]]; then
        cat > /etc/pleiades/pleiades-swarm-policy.json <<'POLICY'
{
  "schema": "pleiades-pleiades-swarm-policy-v1",
  "mode": "owner-authorized-defensive",
  "default_request_decision": "deny",
  "allowed_request_classes": ["status", "health", "capabilities", "evidence-list", "brl-status", "strat-list", "alien-hint", "host-process-summary"],
  "denied_request_classes": ["shell", "exec", "install", "network-change", "firewall-change", "script-modify", "credential-access", "lateral-movement"],
  "alien_sidecar": {"enabled": false, "authority": "advisory-only", "may_request": true, "may_act": false},
  "audit": {"append_only_events": true, "owner_visible": true}
}
POLICY
    fi

    cat > /usr/local/bin/pleiadesctl <<'PURPLECTL'
#!/bin/bash
set -euo pipefail
RUN="/run/pleiades"
POLICY="/etc/pleiades/pleiades-swarm-policy.json"
usage() {
    cat <<'USAGE'
usage: purplectl <command> [args]
commands: status health capabilities events [lines] request <class> <scope> <action> [why] decisions [id] results [id] brl-status strat-list alien-status host-process-summary
USAGE
}
event() { printf '%s\n' "$1" >> "$RUN/pleiades-nexus_fifo" 2>/dev/null || true; }
kv_get() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
status() {
    echo "schema=purplectl-status-v1"
    echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "policy=$POLICY"
    echo "requests=$RUN/requests"
    echo "decisions=$RUN/decisions"
    echo "results=$RUN/results"
    echo "alien_inbox=$RUN/alien/inbox"
    echo "alien_outbox=$RUN/alien/outbox"
    if [[ -f /host/run/pleiades-gentoo-heartbeat/status ]]; then
        sed 's/^/deployment_heartbeat./' /host/run/pleiades-gentoo-heartbeat/status
    fi
}
health() {
    status
    for svc in taygete-omniversal alcyone-omniversal pleiades-rebirth-omniversal atlas-omniversal celaeno-omniversal electra-omniversal pleiades-nexus-omniversal maia host-bridge-monitor windows-host-bridge-monitor pleiades-adaptive-builder pleiades-request-broker; do
        printf 'service.%s=' "$svc"
        systemctl is-active "$svc.service" 2>/dev/null || true
    done
}
capabilities() {
    find "$RUN/capabilities" -maxdepth 1 -type f -name '*.cap' 2>/dev/null | sort | while read -r file; do
        echo "--- ${file##*/} ---"
        cat "$file"
    done
}
request() {
    [[ $# -ge 3 ]] || { usage; exit 2; }
    local class="$1" scope="$2" action="$3" why="${4:-owner-request}"
    local id="req-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$RUN/requests" "$RUN/decisions" "$RUN/results"
    cat > "$RUN/requests/$id.req" <<REQ
schema=pleiades-pleiades-swarm-request-v1
id=$id
origin=purplectl
class=$class
scope=$scope
action=$action
justification=$why
status=pending
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REQ
    event "PLEIADES_SWARM_REQUEST|$id|$class|$scope|$action"
    echo "$id"
}
list_or_cat() {
    local dir="$1" id="${2:-}"
    if [[ -n "$id" ]]; then cat "$dir/$id"* 2>/dev/null || true; else find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort; fi
}
brl_status() { if [[ -x /opt/brl/bin/brl ]]; then /opt/brl/bin/brl status; else echo "brl=absent"; fi; }
strat_list() { if [[ -x /opt/brl/bin/brl ]]; then /opt/brl/bin/brl list; elif [[ -d /strat ]]; then find /strat -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; else echo "strat=absent"; fi; }
alien_status() {
    echo "schema=pleiades-alien-dock-v1"
    echo "enabled=false"
    echo "authority=advisory-only"
    echo "inbox=$RUN/alien/inbox"
    echo "outbox=$RUN/alien/outbox"
    grep -n 'alien_sidecar' "$POLICY" 2>/dev/null || true
}
host_process_summary() {
    echo "schema=purplectl-host-process-summary-v1"
    echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "policy=/etc/pleiades/host-bridge-policy.json"
    if [[ -f /host/run/pleiades-host-capsule/status ]]; then
        echo "--- capsule_status ---"
        cat /host/run/pleiades-host-capsule/status
    else
        echo "capsule_status=absent"
    fi
    if [[ -f /host/run/pleiades-host-capsule/process-summary ]]; then
        echo "--- process_summary ---"
        cat /host/run/pleiades-host-capsule/process-summary
    else
        echo "process_summary=absent"
    fi
}
case "${1:-}" in
    status) status ;;
    health) health ;;
    capabilities) capabilities ;;
    events) tail -n "${2:-80}" "$RUN/pleiades-nexus_fifo" 2>/dev/null || true ;;
    request) shift; request "$@" ;;
    decisions) list_or_cat "$RUN/decisions" "${2:-}" ;;
    results) list_or_cat "$RUN/results" "${2:-}" ;;
    brl-status) brl_status ;;
    strat-list) strat_list ;;
    alien-status) alien_status ;;
    host-process-summary) host_process_summary ;;
    --help|-h|"") usage ;;
    *) usage; exit 2 ;;
esac
PURPLECTL
    chmod +x /usr/local/bin/pleiadesctl

    cat > /usr/local/bin/pleiades_request_broker.sh <<'BROKER'
#!/bin/bash
set -euo pipefail
RUN="/run/pleiades"
POLICY="/etc/pleiades/pleiades-swarm-policy.json"
event() { printf '%s\n' "$1" >> "$RUN/pleiades-nexus_fifo" 2>/dev/null || true; }
kv_get() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
write_capability() {
    local component="$1" domain="$2" capabilities="$3" authority="${4:-policy-gated}" source="${5:-runtime-registry}"
    mkdir -p "$RUN/capabilities" "$RUN/state"
    {
        echo "schema=pleiades-pleiades-swarm-capability-v1"
        echo "component=$component"
        echo "domain=$domain"
        echo "capabilities=$capabilities"
        echo "source=$source"
        echo "authority=$authority"
        echo "ai_sidecar_required=no"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$RUN/capabilities/$component.cap"
    {
        echo "schema=pleiades-pleiades-swarm-state-v1"
        echo "component=$component"
        echo "status=registered"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$RUN/state/$component.state"
}
write_host_bridge_state() {
    local state_file="$RUN/host_bridge_capabilities"
    local owner_copy="/var/lib/.maia/host_bridge_capabilities"
    local mode="container-sentinel"
    local container_context="none"
    local host_proc="absent"
    local host_root="absent"
    local host_systemd="absent"
    local host_container_socket="absent"
    local windows_host_files="absent"
    [[ -r /host/proc/1/status ]] && host_proc="/host/proc"
    [[ -d /host ]] && host_root="/host"
    [[ -S /host/run/systemd/private ]] && host_systemd="/host/run/systemd/private"
    [[ -S /host/var/run/docker.sock ]] && host_container_socket="/host/var/run/docker.sock"
    [[ -e /host/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]] && windows_host_files="/host/mnt/c"
    [[ "$host_proc" != "absent" || "$host_root" != "absent" || "$host_systemd" != "absent" || "$host_container_socket" != "absent" || "$windows_host_files" != "absent" ]] && mode="host-bridge"
    container_context="$(systemd-detect-virt --container 2>/dev/null || true)"
    [[ -n "$container_context" ]] || container_context="none"
    mkdir -p "$(dirname "$owner_copy")"
    {
        echo "schema=pleiades-host-bridge-capabilities-v1"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "mode=$mode"
        echo "container_context=$container_context"
        echo "systemd_usable=$([[ -d /run/systemd/system ]] && echo yes || echo no)"
        echo "host_proc=$host_proc"
        echo "host_root=$host_root"
        echo "host_systemd=$host_systemd"
        echo "host_container_socket=$host_container_socket"
        echo "windows_host_files=$windows_host_files"
        echo "authority=owner-granted-read-only"
        echo "source=pleiades-request-broker-startup"
    } > "$state_file"
    cp "$state_file" "$owner_copy" 2>/dev/null || true
}
restore_runtime_registry() {
    mkdir -p "$RUN/requests" "$RUN/decisions" "$RUN/actions" "$RUN/results" "$RUN/capabilities" "$RUN/state" "$RUN/alien/inbox" "$RUN/alien/outbox"
    touch "$RUN/pleiades-nexus_fifo"
    write_capability "alcyone" "decoy-honeypot" "alcyone_honeypot,conntrack,hypervisor-detector,alcyone-socket"
    write_capability "taygete" "deception-tarpit" "sandbox,credential-decoy,anti-recon,owner-helper,taygete-socket"
    write_capability "electra" "fake-environment" "fake-monitor,harvester,lich,electra-pleiades-swarm"
    write_capability "pleiades-rebirth" "recovery-decoy" "pleiades-rebirth-keeper,ssh-decoy,owner-escrow-beacon"
    write_capability "atlas" "threat-orchestrator" "threat-scoring,mode-switch,thrall-dispatch"
    write_capability "celaeno" "health-hotpatch" "health-monitor,hotpatch,command-processor,regeneration-control"
    write_capability "pleiades-nexus" "containment-substrate" "containment-controller,host-bridge-monitor,windows-bridge-monitor,adaptive-builder,pleiades-swarm-substrate,brl-strat-registry,alien-dock-placeholder"
    write_capability "maia" "overseer-escrow" "crypto,escrow,integrity,state-bundles,safe-mode"
    write_capability "gentoo_container" "deployment-layer" "systemd-nspawn,heartbeat,read-only-host-bridges,service-recovery" "deployment-layer" "/host/run/pleiades-gentoo-heartbeat/status"
    write_capability "host_capsule" "owner-visible-host-sentinel" "process-summary,listener-summary,host-capsule-heartbeat,read-only-alerts" "observe-and-report" "/host/run/pleiades-host-capsule/status"
    write_capability "brl_strat" "cross-stratum-dispatch" "brl-status,strat-list,strat-exec-via-policy-only" "policy-gated" "/opt/brl/bin/brl"
    write_capability "alien_placeholder" "optional-ai-sidecar" "hint-ingest,summary-request,similarity-request-future" "advisory-only-disabled-by-default"
    write_capability "asterope_placeholder" "reserved-script-slot" "not-built-yet,policy-placeholder,owner-visible-reserved-slot" "none-until-implemented"
    write_host_bridge_state
    event "PLEIADES_SWARM_RUNTIME_REGISTRY_RESTORED|capabilities|state"
}
allowed_class() {
    case "$1" in status|health|capabilities|evidence-list|brl-status|strat-list|alien-hint|host-process-summary) return 0 ;; *) return 1 ;; esac
}
write_decision() {
    local id="$1" decision="$2" reason="$3"
    cat > "$RUN/decisions/$id.decision" <<DECISION
schema=pleiades-pleiades-swarm-decision-v1
id=$id
decision=$decision
reason=$reason
policy=$POLICY
updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DECISION
    event "POLICY_DECISION|$id|$decision|$reason"
}
write_result() {
    local id="$1" status="$2" detail="$3"
    cat > "$RUN/results/$id.result" <<RESULT
schema=pleiades-pleiades-swarm-result-v1
id=$id
status=$status
detail=$detail
updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RESULT
    event "ACTION_RESULT|$id|$status|$detail"
}
process_request() {
    local file="$1" id class
    id="$(kv_get "$file" id)"; class="$(kv_get "$file" class)"
    [[ -n "$id" ]] || id="${file##*/}"; id="${id%.req}"
    if ! allowed_class "$class"; then
        write_decision "$id" deny "class-not-allowed:$class"
        write_result "$id" denied "no-action-dispatched"
        sed -i 's/^status=pending/status=denied/' "$file" 2>/dev/null || true
        return 0
    fi
    write_decision "$id" allow "introspection-only:$class"
    case "$class" in
        status|health) /usr/local/bin/pleiadesctl health > "$RUN/results/$id.output" 2>&1 || true ;;
        capabilities) /usr/local/bin/pleiadesctl capabilities > "$RUN/results/$id.output" 2>&1 || true ;;
        evidence-list) find /var/lib/.maia/escrow /var/lib/pleiades-team -maxdepth 3 -type f 2>/dev/null | sort > "$RUN/results/$id.output" || true ;;
        brl-status) /usr/local/bin/pleiadesctl brl-status > "$RUN/results/$id.output" 2>&1 || true ;;
        strat-list) /usr/local/bin/pleiadesctl strat-list > "$RUN/results/$id.output" 2>&1 || true ;;
        host-process-summary) /usr/local/bin/pleiadesctl host-process-summary > "$RUN/results/$id.output" 2>&1 || true ;;
        alien-hint) cp "$file" "$RUN/alien/inbox/$id.hint" 2>/dev/null || true; printf 'accepted_as_hint_only\n' > "$RUN/results/$id.output" ;;
    esac
    write_result "$id" complete "$RUN/results/$id.output"
    sed -i 's/^status=pending/status=complete/' "$file" 2>/dev/null || true
}
restore_runtime_registry
event "PLEIADES_SWARM_BROKER_READY|policy-gated|alien-advisory-only"
while true; do
    for file in "$RUN"/requests/*.req; do
        [[ -f "$file" ]] || continue
        grep -q '^status=pending' "$file" 2>/dev/null || continue
        process_request "$file"
    done
    sleep "${PURPLE_REQUEST_BROKER_INTERVAL:-5}"
done
BROKER
    chmod +x /usr/local/bin/pleiades_request_broker.sh

    cat > /run/pleiades/capabilities/gentoo_container.cap <<'CAP'
schema=pleiades-pleiades-swarm-capability-v1
component=gentoo_container
domain=deployment-layer
capabilities=systemd-nspawn,heartbeat,read-only-host-bridges,service-recovery
source=/host/run/pleiades-gentoo-heartbeat/status
authority=deployment-layer
ai_sidecar_required=no
CAP
    cat > /run/pleiades/capabilities/host_capsule.cap <<'CAP'
schema=pleiades-pleiades-swarm-capability-v1
component=host_capsule
domain=owner-visible-host-sentinel
capabilities=process-summary,listener-summary,host-capsule-heartbeat,read-only-alerts
source=/host/run/pleiades-host-capsule/status
policy=/etc/pleiades/host-bridge-policy.json
authority=observe-and-report
ai_sidecar_required=no
CAP
    cat > /run/pleiades/capabilities/brl_strat.cap <<'CAP'
schema=pleiades-pleiades-swarm-capability-v1
component=brl_strat
domain=cross-stratum-dispatch
capabilities=brl-status,strat-list,strat-exec-via-policy-only
brl=/opt/brl/bin/brl
strat=/opt/brl/bin/strat
strat_root=/strat
authority=policy-gated
ai_sidecar_required=no
CAP
    cat > /run/pleiades/capabilities/alien_placeholder.cap <<'CAP'
schema=pleiades-pleiades-swarm-capability-v1
component=alien_placeholder
domain=optional-ai-sidecar
capabilities=hint-ingest,summary-request,similarity-request-future
authority=advisory-only-disabled-by-default
ai_sidecar_required=no
CAP
    cat > /run/pleiades/capabilities/asterope_placeholder.cap <<'CAP'
schema=pleiades-pleiades-swarm-capability-v1
component=asterope_placeholder
domain=reserved-script-slot
capabilities=not-built-yet,policy-placeholder,owner-visible-reserved-slot
authority=none-until-implemented
ai_sidecar_required=no
CAP
    printf 'PLEIADES_SWARM_SUBSTRATE_READY|purplectl|broker|brl-strat|gentoo-container|asterope-placeholder|alien-placeholder\n' >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
}

install_pleiades-swarm_substrate() {
    if ! systemd_usable; then
        pkg_install screen
        screen -dmS pleiades_request_broker /usr/local/bin/pleiades_request_broker.sh
    else
        cat > /etc/systemd/system/pleiades-request-broker.service << SERVICE
[Unit]
Description=Purple Pleiades Swarm Policy-Gated Request Broker
After=network.target pleiades-nexus-omniversal.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pleiades_request_broker.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable pleiades-request-broker.service
        systemctl restart pleiades-request-broker.service
    fi
}


# ------------------------------------------------------------
# 8. Adaptive defensive tool builder (allowlisted recipes only)
# ------------------------------------------------------------
build_adaptive_tool_builder() {
    cat > /usr/local/bin/pleiades_adaptive_builder.sh << 'ADAPTIVE_BUILDER'
#!/bin/bash
set -euo pipefail

FIFO="/run/pleiades/pleiades-nexus_fifo"
STATE_DIR="/var/lib/pleiades-team/adaptive"
TOOLS_DIR="/usr/local/lib/pleiades-tools"
BIN_DIR="/usr/local/bin"
mkdir -p "$STATE_DIR" "$TOOLS_DIR" /run/pleiades
touch "$FIFO"

event() { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }

pkg_install_adaptive() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" || {
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
        }
    elif command -v apk &>/dev/null; then
        apk add --quiet "${pkgs[@]}"
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "${pkgs[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y -q "${pkgs[@]}"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm --needed "${pkgs[@]}"
    elif command -v pkg &>/dev/null; then
        pkg install -y -q "${pkgs[@]}"
    elif command -v emerge &>/dev/null; then
        local mapped=()
        for p in "${pkgs[@]}"; do
            case "$p" in
                iproute2) mapped+=("sys-apps/iproute2") ;;
                net-tools) mapped+=("sys-apps/net-tools") ;;
                tcpdump) mapped+=("net-analyzer/tcpdump") ;;
                conntrack) mapped+=("net-firewall/conntrack-tools") ;;
                lsof) mapped+=("sys-process/lsof") ;;
                bind-tools|dnsutils) mapped+=("net-dns/bind-tools") ;;
                traceroute) mapped+=("net-analyzer/traceroute") ;;
                curl) mapped+=("net-misc/curl") ;;
                openssl) mapped+=("dev-libs/openssl") ;;
                jq) mapped+=("app-misc/jq") ;;
                procps) mapped+=("sys-process/procps") ;;
                sysstat) mapped+=("app-admin/sysstat") ;;
                tar|gzip|coreutils) : ;;
                *) mapped+=("$p") ;;
            esac
        done
        [[ ${#mapped[@]} -gt 0 ]] && emerge --quiet --noreplace "${mapped[@]}" || true
    else
        event "ADAPTIVE_DEGRADED|no-package-manager|${pkgs[*]}"
        return 0
    fi
}

category_from_event() {
    local line="$1"
    case "$line" in
        HOSTILE_RECON*'|container|'*|*'|defender-probe|'*|HOST_BRIDGE_OBSERVED*|HOST_NET_CHANGE*) echo "host_bridge_probe" ;;
        HOSTILE_RECON*'|network|'*|RATE_LIMITED*|PROXY*) echo "network_scan" ;;
        HOSTILE_RECON*'|cloud|'*|ATTACKER_REQUESTED_UPDATE*) echo "web_probe" ;;
        HOSTILE_RECON*'|users|'*|DECOY_AUTH_OBSERVED*|CREDENTIAL_FINDING*|HARVESTED*) echo "auth_abuse" ;;
        BGP_HIJACK*) echo "dns_route_anomaly" ;;
        THERMAL_ANOMALY*|HOSTILE_RECON*'|process|'*) echo "resource_pressure" ;;
        FORENSIC_OBSERVATION*) echo "forensic_scan" ;;
        HOSTILE_RECON*'|tooling|'*) echo "evidence_pack" ;;
        *) echo "" ;;
    esac
}

packages_for_category() {
    case "$1" in
        network_scan) echo "iproute2 net-tools tcpdump conntrack lsof" ;;
        web_probe) echo "curl openssl jq" ;;
        auth_abuse) echo "procps lsof" ;;
        dns_route_anomaly) echo "bind-tools traceroute iproute2" ;;
        host_bridge_probe) echo "procps lsof iproute2" ;;
        container_probe) echo "procps lsof iproute2" ;;
        resource_pressure) echo "procps sysstat" ;;
        evidence_pack) echo "tar gzip coreutils" ;;
        forensic_scan) echo "procps lsof sysstat bc" ;;
        *) echo "" ;;
    esac
}

write_tool() {
    local name="$1" body="$2"
    printf '%s\n' "$body" > "$BIN_DIR/$name"
    chmod +x "$BIN_DIR/$name"
    event "ADAPTIVE_TOOL_READY|$name"
}

build_recipe() {
    local category="$1"
    local marker="$STATE_DIR/${category}.ready"
    [[ -f "$marker" ]] && return 0
    event "ADAPTIVE_CATEGORY|$category"
    read -r -a pkgs <<< "$(packages_for_category "$category")"
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        event "ADAPTIVE_PACKAGE_PLAN|$category|${pkgs[*]}"
        pkg_install_adaptive "${pkgs[@]}" || event "ADAPTIVE_PACKAGE_WARN|$category"
    fi

    case "$category" in
        network_scan)
            write_tool pleiades-net-summary '#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/pleiades-team/adaptive/reports
out="/var/lib/pleiades-team/adaptive/reports/net_$(date -u +%Y%m%dT%H%M%SZ).txt"
{ date -u; ip addr 2>/dev/null || true; ip route 2>/dev/null || true; ss -tanup 2>/dev/null || netstat -tanp 2>/dev/null || true; conntrack -L 2>/dev/null | head -200 || true; } > "$out"
echo "ADAPTIVE_REPORT|network_scan|$out" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
printf "%s\n" "$out"'
            ;;
        web_probe)
            write_tool pleiades-web-triage '#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/pleiades-team/adaptive/reports
out="/var/lib/pleiades-team/adaptive/reports/web_$(date -u +%Y%m%dT%H%M%SZ).txt"
{ date -u; ss -tanp 2>/dev/null | awk "/:80|:443|:8080|:8443/" || true; openssl version 2>/dev/null || true; } > "$out"
echo "ADAPTIVE_REPORT|web_probe|$out" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
printf "%s\n" "$out"'
            ;;
        auth_abuse)
            write_tool pleiades-auth-triage '#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/pleiades-team/adaptive/reports
out="/var/lib/pleiades-team/adaptive/reports/auth_$(date -u +%Y%m%dT%H%M%SZ).txt"
{ date -u; last -a 2>/dev/null | head -50 || true; journalctl -u ssh -u sshd --since "-2 hours" --no-pager 2>/dev/null | tail -200 || true; lsof -iTCP -sTCP:ESTABLISHED 2>/dev/null || true; } > "$out"
echo "ADAPTIVE_REPORT|auth_abuse|$out" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
printf "%s\n" "$out"'
            ;;
        dns_route_anomaly)
            write_tool pleiades-route-triage '#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/pleiades-team/adaptive/reports
out="/var/lib/pleiades-team/adaptive/reports/route_$(date -u +%Y%m%dT%H%M%SZ).txt"
{ date -u; ip route 2>/dev/null || true; ip rule 2>/dev/null || true; cat /etc/resolv.conf 2>/dev/null || true; traceroute -m 4 1.1.1.1 2>/dev/null || true; } > "$out"
echo "ADAPTIVE_REPORT|dns_route_anomaly|$out" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
printf "%s\n" "$out"'
            ;;
        host_bridge_probe|container_probe)
            write_tool pleiades-host-bridge-triage '#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/pleiades-team/adaptive/reports
out="/var/lib/pleiades-team/adaptive/reports/host_bridge_$(date -u +%Y%m%dT%H%M%SZ).txt"
{ date -u; cat /run/pleiades/host_bridge_capabilities 2>/dev/null || true; mount 2>/dev/null | grep -E "host|mnt/c|docker|systemd" || true; systemd-detect-virt --container 2>/dev/null || true; } > "$out"
echo "ADAPTIVE_REPORT|host_bridge_probe|$out" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
printf "%s\n" "$out"'
            ;;
        resource_pressure)
            write_tool pleiades-resource-triage '#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/pleiades-team/adaptive/reports
out="/var/lib/pleiades-team/adaptive/reports/resource_$(date -u +%Y%m%dT%H%M%SZ).txt"
{ date -u; uptime; ps aux --sort=-%cpu 2>/dev/null | head -25; ps aux --sort=-%mem 2>/dev/null | head -25; vmstat 1 3 2>/dev/null || true; } > "$out"
echo "ADAPTIVE_REPORT|resource_pressure|$out" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
printf "%s\n" "$out"'
            ;;
        evidence_pack)
            write_tool pleiades-evidence-pack '#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/pleiades-team/adaptive/bundles
out="/var/lib/pleiades-team/adaptive/bundles/evidence_$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$out" /run/pleiades /var/lib/pleiades-team/adaptive/reports 2>/dev/null || true
echo "ADAPTIVE_REPORT|evidence_pack|$out" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
printf "%s\n" "$out"'
            ;;
        forensic_scan)
            write_tool pleiades-forensic-triage '#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/pleiades-team/adaptive/reports
out="/var/lib/pleiades-team/adaptive/reports/forensic_$(date -u +%Y%m%dT%H%M%SZ).txt"
{
date -u
echo "=== FORENSIC SCORE ==="
cat /run/pleiades/forensic_score 2>/dev/null || echo "0"
echo "=== ANOMALIES ==="
cat /run/pleiades/forensic_anomalies 2>/dev/null || echo "none"
echo "=== SNAPSHOT INVENTORY ==="
ls -la /var/lib/pleiades-team/forensic/snapshots/ 2>/dev/null | tail -20
echo "=== ADAPTIVE THRESHOLDS ==="
cat /var/lib/pleiades-team/forensic/thresholds 2>/dev/null || echo "none"
echo "=== /proc/sys/fs/file-nr ==="
cat /proc/sys/fs/file-nr 2>/dev/null || true
echo "=== LAST 20 BASELINE CHANGES ==="
tail -20 /var/lib/pleiades-team/forensic/profiles/*.profile 2>/dev/null || echo "none"
} > "$out"
echo "ADAPTIVE_REPORT|forensic_scan|$out" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
printf "%s\n" "$out"'
            ;;
    esac
    date -u +%Y-%m-%dT%H:%M:%SZ > "$marker"
}

process_line() {
    local line="$1"
    local category
    category=$(category_from_event "$line")
    [[ -z "$category" ]] && return 0
    build_recipe "$category"
}

offset=0
event "ADAPTIVE_BUILDER_READY|allowlisted-recipes"
while true; do
    if [[ ! -f "$FIFO" ]]; then sleep 2; continue; fi
    size=$(stat -c %s "$FIFO" 2>/dev/null || echo 0)
    if (( size < offset )); then offset=0; fi
    if (( size > offset )); then
        while IFS= read -r line; do process_line "$line"; done < <(tail -c +"$((offset + 1))" "$FIFO" 2>/dev/null || true)
        offset=$size
    fi
    sleep 2
done
ADAPTIVE_BUILDER
    chmod +x /usr/local/bin/pleiades_adaptive_builder.sh
}

install_adaptive_tool_builder() {
    if ! systemd_usable; then
        pkg_install screen
        screen -dmS purple_adaptive_builder /usr/local/bin/pleiades_adaptive_builder.sh
    else
        cat > /etc/systemd/system/pleiades-adaptive-builder.service << SERVICE
[Unit]
Description=Purple Adaptive Defensive Tool Builder
After=network.target pleiades-nexus-omniversal.service host-bridge-monitor.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pleiades_adaptive_builder.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable pleiades-adaptive-builder.service
        systemctl start pleiades-adaptive-builder.service
    fi
}

# ------------------------------------------------------------
# 7. Install systemd service
# ------------------------------------------------------------
install_service() {
    if ! systemd_usable; then
        pkg_install screen
        screen -dmS pleiades-nexus /usr/local/bin/containment_controller
    else
        cat > /etc/systemd/system/pleiades-nexus-omniversal.service << SERVICE
[Unit]
Description=Pleiades Nexus containment Omniversal
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/containment_controller
Restart=always
RestartSec=10
LimitNOFILE=$MAX_OPEN_FILES
MemoryMax=$MEMORY_LIMIT
CPUQuota=$CPU_QUOTA

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable pleiades-nexus-omniversal.service
        systemctl start pleiades-nexus-omniversal.service
    fi
}

# ------------------------------------------------------------
# 8. Background monitors for BGP and thermal threats
# ------------------------------------------------------------
monitor_threats() {
    while true; do
        if bgp_hijack_detected; then
            logger -t pleiades-nexus "BGP hijack detected – setting flag"
            touch /run/pleiades/bgp_hijack
        fi
        if thermal_anomaly; then
            logger -t pleiades-nexus "Thermal anomaly detected – setting flag"
            touch /run/pleiades/thermal_anomaly
        fi
        # Detect forensic analysis tools
        for tool in volatility volatility3 rekall strings gdb; do
            if command -v "$tool" &>/dev/null; then
                logger -t pleiades-nexus "Forensic tool detected: $tool"
                ( echo "ANOMALY|forensic_tool|$tool" >> /run/pleiades/pleiades-nexus_fifo & )
fi
        done
        sleep 30
    done
}

# ------------------------------------------------------------
# 9. Main
# ------------------------------------------------------------
main() {
    # Install dependencies
    if [[ "$ENV" == "wsl" ]]; then
        pkg_install golang rustc bc lm-sensors traceroute socat openbsd-netcat
    elif [[ "$ENV" == "bare_metal" ]]; then
        pkg_install golang rustc bc lm-sensors traceroute socat openbsd-netcat
    else
        pkg_install golang rustc bc lm-sensors traceroute socat openbsd-netcat
    fi

    mkdir -p /run/pleiades
    host_bridge_capability_report "pleiades-nexus"
    register_pleiades-swarm_capability "pleiades-nexus" "containment-substrate" "containment-controller,host-bridge-monitor,windows-bridge-monitor,adaptive-builder,pleiades-swarm-substrate,brl-strat-registry,alien-dock-placeholder"

    # Build the containment_controller (Go preferred)
    if command -v go &>/dev/null; then
        build_go_containment_controller
        CONTAINMENT_BIN="/usr/local/bin/containment_controller"
    elif command -v rustc &>/dev/null; then
        build_rust_containment_controller
        CONTAINMENT_BIN="/usr/local/bin/containment_controller_rust"
    else
        build_bash_containment_controller
        CONTAINMENT_BIN="/usr/local/bin/containment_controller_bash.sh"
    fi

    build_host_bridge_monitor
    install_host_bridge_monitor
    build_windows_host_bridge_monitor
    install_windows_host_bridge_monitor
    build_pleiades-swarm_substrate
    install_pleiades-swarm_substrate
    build_adaptive_tool_builder
    install_adaptive_tool_builder
    install_service
    monitor_threats &
    SELF="$0"
    cat > /usr/local/sbin/install-pleiades-nexus-omniversal.sh << INST
#!/bin/bash
exec bash "$SELF"
INST
    chmod +x /usr/local/sbin/install-pleiades-nexus-omniversal.sh
    signal_ready pleiades-nexus
    echo "Pleiades Nexus Omniversal deployed on $ENV."
}

main











# --- MAIA EVENT HOOK ---
_maia_hook() {
    [[ -S "/run/maia.sock" ]] && printf '%s\n' "$1" | (socat - UNIX-CONNECT:/run/maia.sock 2>/dev/null || nc -U /run/maia.sock -w 1 2>/dev/null) || true
}
# --- END MAIA EVENT HOOK ---
# --- MAIA EVENT HOOK ---
_maia_hook() {
    [[ -S "/run/maia.sock" ]] && printf '%s\n' "$1" | (socat - UNIX-CONNECT:/run/maia.sock 2>/dev/null || nc -U /run/maia.sock -w 1 2>/dev/null) || true
}
# --- END MAIA EVENT HOOK ---
