#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
set -euo pipefail


# --- MAIA EVENT HOOK ---
_maia_hook() {
    [[ -S "/run/maia.sock" ]] && printf '%s\n' "$1" | (socat - UNIX-CONNECT:/run/maia.sock 2>/dev/null || nc -U /run/maia.sock -w 1 2>/dev/null) || true
}
# --- END MAIA EVENT HOOK ---


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


ensure_bun() {
    command -v bun &>/dev/null && return 0
    pkg_install bun 2>/dev/null || true; command -v bun &>/dev/null && return 0
    if command -v curl &>/dev/null; then
        curl -fsSL https://bun.sh/install | bash 2>/dev/null || true
        local bp="/root/.bun/bin/bun"
    fi
    # Node.js shim fallback
    pkg_install nodejs 2>/dev/null || true
    if command -v node &>/dev/null; then
        printf '#!/bin/bash\nexec node "$@"\n' > /usr/local/bin/bun
        chmod +x /usr/local/bin/bun
        echo "WARN: using node as bun shim" >&2
        return 0
    fi
    return 1
}

# ELECTRA_ID
# ==================================================================
# ELECTRA HOOD + LICH – OMNIVERSAL (WSL / bare metal / VPS)
# ==================================================================
# Environment‑aware resource limits, BGP hijack detection,
# thermal anomaly monitoring, fake environment + Lich pleiades-rebirth.
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
        ENV="bare_metal"
        IS_BARE_METAL=true
    fi
fi
echo "Detected environment: $ENV"

# ------------------------------------------------------------
# 1. Environment‑specific resource limits
# ------------------------------------------------------------
MAX_OPEN_FILES=4096
MEMORY_LIMIT=3764M
CPU_QUOTA=400%

# Fallback for initial run
[[ "$MAX_OPEN_FILES" == "4096" ]] && {
    if [[ "$ENV" == "wsl" ]]; then
        MAX_OPEN_FILES=4096
        MEMORY_LIMIT="512M"
        CPU_QUOTA="50%"
        SYSMON-IDLE_INTERVAL=15
    elif [[ "$ENV" == "bare_metal" ]]; then
        MAX_OPEN_FILES=1048576
        MEMORY_LIMIT="2G"
        CPU_QUOTA="200%"
        SYSMON-IDLE_INTERVAL=5
    else
        MAX_OPEN_FILES=65536
        MEMORY_LIMIT="1G"
        CPU_QUOTA="100%"
        SYSMON-IDLE_INTERVAL=10
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
# 4. Build Go fake environment monitor (detects attack, creates bait)
# ------------------------------------------------------------
build_go_sysmon-idle() {
    cat > /tmp/sysmon-idle.go << 'GO_FAKE'
package main

import (
    "bufio"
    "fmt"
    "io"
    "os"
    "os/exec"
    "strings"
    "syscall"
    "time"
)

const fakeState = "/etc/imtherealsparticus"
const runDir = "/run/pleiades"

func reportToPleiadesNexus(msg string) {
    f, err := os.OpenFile(runDir+"/pleiades-nexus_fifo", os.O_WRONLY|os.O_APPEND|syscall.O_NONBLOCK, 0666)
    if err == nil {
        defer f.Close()
        fmt.Fprintln(f, msg)
    }
}

func isUnderAttack() bool {
    // Check recent pleiades-nexus log for threat events (last 8 KB)
    f, err := os.Open(runDir + "/pleiades-nexus_fifo")
    if err == nil {
        defer f.Close()
        if fi, err2 := f.Stat(); err2 == nil && fi.Size() > 8192 {
            f.Seek(-8192, io.SeekEnd)
        }
        scanner := bufio.NewScanner(f)
        count := 0
        for scanner.Scan() {
            line := scanner.Text()
            if strings.HasPrefix(line, "ANOMALY|") || strings.HasPrefix(line, "CREDENTIAL_FINDING|") ||
                strings.HasPrefix(line, "RATE_LIMITED|") {
                count++
                if count >= 5 {
                    return true
                }
            }
        }
    }
    // Check for failed SSH logins in last minute
    cmd := exec.Command("journalctl", "-u", "sshd", "--since", "-1m", "-o", "cat")
    stdout, err := cmd.StdoutPipe()
    if err == nil {
        cmd.Start()
        scanner := bufio.NewScanner(stdout)
        failCount := 0
        for scanner.Scan() {
            if strings.Contains(scanner.Text(), "Failed password") {
                failCount++
                if failCount > 5 {
                    cmd.Process.Kill()
                    return true
                }
            }
        }
        cmd.Wait()
    }
    return false
}

func isPleiadesRebirthActive() bool {
    _, err := os.Stat(runDir + "/pleiades-rebirth_active")
    return err == nil
}

func createFakeEnvironment() {
    os.MkdirAll(fakeState, 0700)
    os.WriteFile(fakeState+"/STOP", []byte("fake-idle-token"), 0644)
    os.WriteFile(fakeState+"/ACTIVE", []byte(""), 0644)
    os.WriteFile(fakeState+"/threat_increment", []byte("INVALID_TOKEN"), 0644)
    os.MkdirAll(runDir+"/fake", 0755)
    syscall.Mkfifo(runDir+"/fake/control", 0666)
    // Simulate CPU load to frustrate attacker (background)
    go func() { for { time.Sleep(1 * time.Second) } }()
    reportToPleiadesNexus("FAKE_ENVIRONMENT_CREATED")
}

func main() {
    for {
        if isUnderAttack() {
            createFakeEnvironment()
            // Notify Celaeno to pause regeneration
            {
                lj, lerr := os.OpenFile(runDir+"/celaeno_cmd", os.O_WRONLY|os.O_APPEND|syscall.O_NONBLOCK|os.O_CREATE, 0644)
                if lerr == nil {
                    fmt.Fprintln(lj, "pause_regeneration")
                    lj.Close()
                }
            }
            // Wait for fake STOP file removal (attacker thinks they won)
            for i := 0; i < 150; i++ {
                if _, err := os.Stat(fakeState + "/STOP"); os.IsNotExist(err) {
                    break
                }
                time.Sleep(2 * time.Second)
            }
            reportToPleiadesNexus("FAKE_DISARMED_ATTACKER_WON")
            if isPleiadesRebirthActive() {
                os.Exit(0)
            }
            // Trigger Lich pleiades-rebirth
            exec.Command("/usr/local/bin/lich_resurrect").Run()
            os.Exit(0)
        }
        time.Sleep(10 * time.Second)
    }
}
GO_FAKE
    go build -o /usr/local/bin/sysmon-idle /tmp/sysmon-idle.go
    chmod +x /usr/local/bin/sysmon-idle
    rm -f /tmp/sysmon-idle.go
}

# ------------------------------------------------------------
# 5. Build Rust credential harvester (reports to Pleiades Nexus)
# ------------------------------------------------------------
build_rust_harvester() {
    cat > /tmp/harvester.rs << 'RUST_HARV'
use std::fs;
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
use std::io::{BufRead, BufReader, Write};
use std::thread;
use std::time::Duration;

fn report_to_pleiades_nexus(msg: &str) {
    if let Ok(mut fifo) = OpenOptions::new().write(true).append(true).custom_flags(0o4000).open("/run/pleiades/pleiades-nexus_fifo") {
        let _ = writeln!(fifo, "{}", msg);
    }
}

fn harvest_credentials() {
    let paths = ["/etc/imtherealsparticus/ssh_honeypot.log", "/etc/taygete/ssh_honeypot.log"];
    for path in paths {
        if let Ok(file) = fs::File::open(path) {
            let reader = BufReader::new(file);
            for line in reader.lines() {
                if let Ok(l) = line {
                    if l.contains("password") || l.contains("Unexpected SSH") {
                        report_to_pleiades_nexus(&format!("HARVESTED|{}", l));
                    }
                }
            }
        }
    }
}

fn main() {
    loop {
        harvest_credentials();
        thread::sleep(Duration::from_secs(30));
    }
}
RUST_HARV
    rustc -o /usr/local/bin/harvester /tmp/harvester.rs
    chmod +x /usr/local/bin/harvester
    rm -f /tmp/harvester.rs
}

# ------------------------------------------------------------
# 6. Build Bun Lich deception engine (respects pleiades-rebirth)
# ------------------------------------------------------------
build_bun_lich() {
    cat > /usr/local/bin/lich.js << 'BUN_LICH'
#!/usr/bin/env bun
import { existsSync, readFileSync, writeFileSync, appendFileSync } from 'fs';
import { exec } from 'child_process';
import { promisify } from 'util';
const execAsync = promisify(exec);

const TRAP_FILE = "/var/lib/.lich/traps_active";
const LOG_FILE = "/var/lib/.lich/lich.log";
const PLEIADES_REBIRTH_FLAG = "/run/pleiades/pleiades-rebirth_active";

function log(msg) {
    const ts = new Date().toISOString();
    appendFileSync(LOG_FILE, `${ts} - ${msg}\n`);
}

function reportToPleiadesNexus(msg) {
    try {
        appendFileSync("/run/pleiades/pleiades-nexus_fifo", msg + "\n");
    } catch(e) {}
}

async function kernelTrap(ip) {
    await execAsync(`ip route add ${ip} via 127.0.0.1 dev lo 2>/dev/null`);
    log(`Kernel trap set for ${ip}`);
    reportToPleiadesNexus(`KERNEL_TRAP|${ip}`);
}

async function harvestCredentials() {
    const files = ["/etc/imtherealsparticus/ssh_honeypot.log", "/etc/taygete/ssh_honeypot.log"];
    for (const file of files) {
        if (existsSync(file)) {
            const content = readFileSync(file, 'utf8');
            const lines = content.split('\n');
            for (const line of lines) {
                if (line.includes("password") || line.includes("Unexpected SSH")) {
                    reportToPleiadesNexus(`HARVESTED|${line}`);
                }
            }
        }
    }
}

async function feedFalseInfo() {
    if (existsSync(PLEIADES_REBIRTH_FLAG)) {
        const fakeIP = `10.${Math.floor(Math.random()*256)}.${Math.floor(Math.random()*256)}.${Math.floor(Math.random()*256)}`;
        reportToPleiadesNexus(`FAKE_NETWORK|${fakeIP}`);
    }
}

async function main() {
    log("Lich resurrected (omniversal)");
    reportToPleiadesNexus("LICH_RESURRECTED");
    writeFileSync(TRAP_FILE, "active");
    while (true) {
        const { stdout } = await execAsync('conntrack -E -p tcp --state NEW 2>/dev/null | grep -oP "src=\\K[0-9.]+" | head -1');
        if (stdout) {
            const ip = stdout.trim();
            if (ip && !ip.startsWith("127.") && !ip.startsWith("192.168.") && !ip.startsWith("10.") && !ip.startsWith("172.16.")) {
                await kernelTrap(ip);
            }
        }
        await harvestCredentials();
        await feedFalseInfo();
        writeFileSync("/run/pleiades/lich_heartbeat", Date.now().toString());
        await new Promise(resolve => setTimeout(resolve, 10000));
    }
}

main();
BUN_LICH
    chmod +x /usr/local/bin/lich.js
}

# ------------------------------------------------------------
# 7. Create Lich pleiades-rebirth helper (Bash)
# ------------------------------------------------------------
build_lich_resurrector() {
    cat > /usr/local/bin/lich_resurrect << 'RESURRECT'
#!/bin/bash
# Checks pleiades-rebirth flag; if not already active, spawn Lich
if [[ -f /run/pleiades/pleiades-rebirth_active ]]; then
    exit 0
fi
if [[ -f /run/pleiades/pleiades-rebirth_needed ]]; then
    touch /run/pleiades/pleiades-rebirth_active
fi
nohup bun /usr/local/bin/lich.js > /var/log/lich.log 2>&1 &
echo $! > /var/lib/.lich/lich.pid
( echo "LICH_RESURRECTED" >> /run/pleiades/pleiades-nexus_fifo & )
RESURRECT
    chmod +x /usr/local/bin/lich_resurrect
}

# ------------------------------------------------------------
# 8. Build Bash fallback (if toolchain missing)
# ------------------------------------------------------------
build_bash_fallback() {
    cat > /var/lib/.electra/create_fake.sh << 'FAKE'
#!/bin/bash
mkdir -p /etc/imtherealsparticus
echo "fake-idle-token" > /etc/imtherealsparticus/STOP
touch /etc/imtherealsparticus/ACTIVE
echo "INVALID_TOKEN" > /etc/imtherealsparticus/threat_increment
mkfifo /run/pleiades/fake/control 2>/dev/null || true
dd if=/dev/zero of=/dev/null bs=1024 count=1000 2>/dev/null &
echo $! > /var/lib/.electra/load.pid
( echo "FAKE_ENVIRONMENT_CREATED" >> /run/pleiades/pleiades-nexus_fifo & )
FAKE
    chmod +x /var/lib/.electra/create_fake.sh
}

# ------------------------------------------------------------
# 9. Build Go pleiades-swarm
# ------------------------------------------------------------
build_go_pleiades-swarm() {
    cat > /tmp/sysmon_daemon.go << 'GO_HIVE'
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
        {Name: "sysmon-idle", Cmd: exec.Command("/usr/local/bin/sysmon-idle")},
        {Name: "harvester",    Cmd: exec.Command("/usr/local/bin/harvester")},
        {Name: "lich",         Cmd: exec.Command("bun", "/usr/local/bin/lich.js")},
    }
    for _, p := range procs {
        go p.run()
    }
    select {}
}
GO_HIVE
    go build -o /usr/local/bin/sysmon-daemon /tmp/sysmon_daemon.go
    chmod +x /usr/local/bin/sysmon-daemon
    rm -f /tmp/sysmon_daemon.go
}

# ------------------------------------------------------------
# 10. Install service
# ------------------------------------------------------------
install_service() {
    if ! systemd_usable; then
        pkg_install screen
        screen -dmS sysmon_daemon /usr/local/bin/sysmon-daemon
    else
        cat > /etc/systemd/system/machine-runtime-monitor.service << SERVICE
[Unit]
Description=Machine Runtime Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sysmon-daemon
Restart=always
RestartSec=5
LimitNOFILE=$MAX_OPEN_FILES
MemoryMax=$MEMORY_LIMIT
CPUQuota=$CPU_QUOTA

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable machine-runtime-monitor.service
        systemctl start machine-runtime-monitor.service
    fi
}

# ------------------------------------------------------------
# 10. Background monitors for BGP and thermal threats
# ------------------------------------------------------------
monitor_threats() {
    while true; do
        if bgp_hijack_detected; then
            logger -t electra "BGP hijack detected – activating countermeasures"
            ( echo "BGP_HIJACK" >> /run/pleiades/pleiades-nexus_fifo & )
touch /run/pleiades/pleiades-rebirth_needed
            _maia_hook "PLEIADES_REBIRTH_NEEDED"
        fi
        if thermal_anomaly; then
            logger -t electra "Thermal anomaly detected – possible side‑channel"
            ( echo "THERMAL_ANOMALY" >> /run/pleiades/pleiades-nexus_fifo & )
cpulimit -l 10 -p $$ 2>/dev/null || true
        fi
        sleep 30
    done
}

# ------------------------------------------------------------
# 11. Main
# ------------------------------------------------------------
main() {
    if [[ "$ENV" == "wsl" ]]; then
        pkg_install golang rustc bun screen bc lm-sensors traceroute socat openbsd-netcat
    elif [[ "$ENV" == "bare_metal" ]]; then
        pkg_install golang rustc bun screen bc lm-sensors traceroute socat openbsd-netcat
    else
        pkg_install golang rustc bun screen bc lm-sensors traceroute socat openbsd-netcat
    fi

    ensure_bun

    mkdir -p /var/lib/.electra /var/lib/.lich /run/pleiades
    host_bridge_capability_report "electra"
    register_pleiades-swarm_capability "electra" "fake-environment" "fake-monitor,harvester,lich,electra-pleiades-swarm"
    touch /run/pleiades/pleiades-nexus_fifo /run/pleiades/celaeno_cmd
    build_go_sysmon-idle
    build_rust_harvester
    build_bun_lich
    build_lich_resurrector
    build_bash_fallback
    build_go_pleiades-swarm
    install_service
    monitor_threats &
    SELF="$0"
    cat > /usr/local/sbin/install-machine-runtime-monitor.sh << INST
#!/bin/bash
exec bash "$SELF"
INST
    chmod +x /usr/local/sbin/install-machine-runtime-monitor.sh
    signal_ready electra
    echo "Electra Hood + Lich Omniversal deployed on $ENV."
}

main












