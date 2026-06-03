#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# Asterope.sh — BSD compatibility layer, package conversion pipeline, telemetry aggregator
#
# Third-party projects used (not vendored — cloned/downloaded from upstream):
#   qemu-bsd-user-l4b  sobomax (Maksym Sobolyev)  MIT         https://github.com/sobomax/qemu-bsd-user-l4b
#   FreeBSD base       The FreeBSD Project         BSD-2-Clause https://www.freebsd.org
#   pkgsrc             The NetBSD Foundation       BSD-2-Clause https://pkgsrc.org
#   QEMU               QEMU project                GPL-2.0+    https://www.qemu.org
#                      NOTE: QEMU is GPL-2.0+. Installed as a binary; no source vendored here.
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
    printf 'PLEIADES_SWARM_CAPABILITY|%s|%s|%s\n' "$component" "$domain" "$capabilities" >> "$run_dir/pleiades-nexus_fifo" 2>/dev/null || true
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
                rustc) : ;;
                curl) pkgs+=("net-misc/curl") ;;
                git) pkgs+=("dev-vcs/git") ;;
                openssl) pkgs+=("dev-libs/openssl") ;;
                python3) pkgs+=("dev-lang/python") ;;
                xz) pkgs+=("app-arch/xz-utils") ;;
                *) pkgs+=("$p") ;;
            esac
        else
            pkgs+=("$p")
        fi
    done

    if command -v emerge &>/dev/null; then
        [[ ${#pkgs[@]} -gt 0 ]] && emerge --quiet --noreplace "${pkgs[@]}"
    elif command -v apt-get &>/dev/null; then
        local apt_pkgs=()
        for p in "${pkgs[@]}"; do
            case "$p" in
                openbsd-netcat) apt_pkgs+=("netcat-openbsd") ;;
                bind-tools) apt_pkgs+=("dnsutils") ;;
                *) apt_pkgs+=("$p") ;;
            esac
        done
        [[ ${#apt_pkgs[@]} -gt 0 ]] && {
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt_pkgs[@]}" || {
                apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt_pkgs[@]}"
            }
        }
    elif command -v apk &>/dev/null; then
        [[ ${#pkgs[@]} -gt 0 ]] && apk add --quiet "${pkgs[@]}"
    elif command -v pkg &>/dev/null; then
        [[ ${#pkgs[@]} -gt 0 ]] && pkg install -y -q "${pkgs[@]}"
    elif command -v dnf &>/dev/null; then
        [[ ${#pkgs[@]} -gt 0 ]] && dnf install -y -q "${pkgs[@]}"
    elif command -v pacman &>/dev/null; then
        [[ ${#pkgs[@]} -gt 0 ]] && pacman -S --noconfirm --needed "${pkgs[@]}"
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
    for p in /host/run/systemd/private /mnt/host/run/systemd/private; do
        if [[ -S "$p" ]]; then host_systemd="$p"; break; fi
    done
    for p in /var/run/docker.sock /run/docker.sock /host/var/run/docker.sock; do
        if [[ -S "$p" ]]; then host_container_socket="$p"; break; fi
    done
    [[ -d /mnt/c/Windows/System32 ]] && windows_host_files="/mnt/c"

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
    fi
    pkg_install nodejs 2>/dev/null || true
    if command -v node &>/dev/null; then
        printf '#!/bin/bash\nexec node "$@"\n' > /usr/local/bin/bun
        chmod +x /usr/local/bin/bun
        echo "WARN: using node as bun shim" >&2
        return 0
    fi
    return 1
}

# ASTEROPE_ID
# ==================================================================
# ASTEROPE — BSD Compatibility Layer (WSL / nspawn / VPS)
# ==================================================================
# Bootstraps and supervises the BSD compatibility subsystem:
#   - FreeBSD strat via modified brl import
#   - bsd-user-4-linux (QEMU user-mode FreeBSD ELF emulation)
#   - pkgsrc bootstrap on Linux (/opt/pkg)
#   - alien-bsd conversion pipeline (.pkg → .deb / .tbz2)
#
# Fills the asterope_placeholder slot registered by Atlas.sh.
# Capabilities exposed: bsd_compat, alien_pkg_converter, pkgsrc_available
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
elif nvidia-smi &>/dev/null && lspci 2>/dev/null | grep -qi nvidia; then
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
# 1. BSD compat configuration
# ------------------------------------------------------------
BSD_STRAT_NAME="${BSD_STRAT_NAME:-freebsd}"
BSD_STRAT_DIR="${BSD_STRAT_DIR:-/bedrock/strata/${BSD_STRAT_NAME}}"
BSD_RELEASE="${BSD_RELEASE:-14.2-RELEASE}"
BSD_ARCH="${BSD_ARCH:-amd64}"
BSD_BASE_URL="https://download.freebsd.org/releases/${BSD_ARCH}/${BSD_RELEASE}/base.txz"
PKGSRC_DIR="${PKGSRC_DIR:-/opt/pkg}"
PKGSRC_BOOTSTRAP_URL="https://cdn.NetBSD.org/pub/pkgsrc/current/pkgsrc.tar.gz"
BSD_USER_REPO="https://github.com/sobomax/qemu-bsd-user-l4b"
CONVERT_INBOX="/run/pleiades/bsd-convert/inbox"
CONVERT_OUTBOX="/run/pleiades/bsd-convert/outbox"
ALIEN_BSD_BIN="/usr/local/bin/alien-bsd"
BSD_STATE_FILE="/run/pleiades/bsd_compat_state"
FIFO="/run/pleiades/pleiades-nexus_fifo"

mkdir -p "$CONVERT_INBOX" "$CONVERT_OUTBOX" /var/log/pleiades /var/lib/pleiades-team/bsd 2>/dev/null || true

log()   { echo "[$(date -u +%H:%M:%S)] [asterope] $*" | tee -a /var/log/pleiades/asterope.log; }
event() { printf '%s\n' "$1" >> "$FIFO" 2>/dev/null || true; }

# ------------------------------------------------------------
# 2. Install alien-bsd to PATH
# ------------------------------------------------------------
install_alien_bsd() {
    local src
    for candidate in \
        "${PLEIADES_REPO_ROOT}/alien-bsd" \
        "${SCRIPT_DIR}/../../alien-bsd" \
        "${SCRIPT_DIR}/../../../alien-bsd"; do
        [[ -f "$candidate" ]] && { src="$candidate"; break; }
    done

    if [[ -z "${src:-}" ]]; then
        log "alien-bsd source not found; skipping install"
        return 1
    fi

    if [[ "$src" != "$ALIEN_BSD_BIN" ]]; then
        cp "$src" "$ALIEN_BSD_BIN"
        chmod +x "$ALIEN_BSD_BIN"
        log "alien-bsd installed → $ALIEN_BSD_BIN"
    fi
    python3 -c "import tarfile, json, struct, hashlib" 2>/dev/null || {
        pkg_install python3 || true
    }
    event "BSD_COMPAT|alien_bsd|installed|${ALIEN_BSD_BIN}"
    return 0
}

# ------------------------------------------------------------
# 3. FreeBSD strat bootstrap via brl import
# ------------------------------------------------------------
bootstrap_freebsd_strat() {
    # Check if brl is available (Bedrock Linux)
    if ! command -v brl &>/dev/null; then
        log "brl not found — FreeBSD strat bootstrap skipped (Bedrock not present)"
        event "BSD_COMPAT|brl_strat|skipped|brl_not_found"
        return 0
    fi

    # Already imported?
    if brl list 2>/dev/null | grep -q "^${BSD_STRAT_NAME}$"; then
        log "FreeBSD strat '${BSD_STRAT_NAME}' already present"
        event "BSD_COMPAT|brl_strat|already_present|${BSD_STRAT_NAME}"
        return 0
    fi

    local tarball="/var/lib/pleiades-team/bsd/base.txz"
    if [[ ! -f "$tarball" ]]; then
        log "Downloading FreeBSD ${BSD_RELEASE} base.txz ..."
        curl -fsSL --progress-bar "$BSD_BASE_URL" -o "$tarball" || {
            log "ERROR: failed to download FreeBSD base tarball"
            event "BSD_COMPAT|brl_strat|error|download_failed"
            return 1
        }
        log "Downloaded $(du -sh "$tarball" | cut -f1) → $tarball"
    fi

    log "Importing FreeBSD strat via brl import ..."
    mkdir -p "$BSD_STRAT_DIR"
    tar -xf "$tarball" -C "$BSD_STRAT_DIR" --numeric-owner 2>/dev/null || {
        log "ERROR: tarball extraction failed"
        event "BSD_COMPAT|brl_strat|error|extract_failed"
        return 1
    }

    brl import "${BSD_STRAT_NAME}" "$BSD_STRAT_DIR" 2>/dev/null || {
        log "brl import failed — strat directory pre-populated; operator can run 'brl enable ${BSD_STRAT_NAME}' manually"
        event "BSD_COMPAT|brl_strat|partial|manual_enable_needed"
        return 0
    }

    log "FreeBSD strat '${BSD_STRAT_NAME}' imported successfully"
    event "BSD_COMPAT|brl_strat|ready|${BSD_STRAT_NAME}"
}

# ------------------------------------------------------------
# 4. bsd-user-4-linux installation
# ------------------------------------------------------------
install_bsd_user() {
    # Check if already installed
    if command -v bsd-user &>/dev/null || [[ -x /usr/local/bin/bsd-user ]]; then
        log "bsd-user-4-linux already installed"
        event "BSD_COMPAT|bsd_user|already_present"
        return 0
    fi

    # Try pre-built binary first (CI releases from sobomax/qemu-bsd-user-l4b)
    local arch; arch=$(uname -m)
    local rel_url="${BSD_USER_REPO}/releases/latest/download/qemu-bsd-user-linux-${arch}.tar.gz"
    local tmpdir; tmpdir=$(mktemp -d)

    log "Attempting bsd-user-4-linux download ..."
    if curl -fsSL --max-time 60 "$rel_url" -o "${tmpdir}/bsd-user.tar.gz" 2>/dev/null; then
        tar -xf "${tmpdir}/bsd-user.tar.gz" -C "${tmpdir}" 2>/dev/null || true
        local bin
        bin=$(find "${tmpdir}" -name "qemu-bsd-user*" -type f -executable 2>/dev/null | head -1)
        if [[ -n "$bin" ]]; then
            cp "$bin" /usr/local/bin/bsd-user
            chmod +x /usr/local/bin/bsd-user
            log "bsd-user-4-linux installed from release binary"
            event "BSD_COMPAT|bsd_user|installed|binary"
            rm -rf "${tmpdir}"
            return 0
        fi
    fi
    rm -rf "${tmpdir}"

    # Build from source if release binary unavailable
    if command -v git &>/dev/null && command -v make &>/dev/null; then
        log "Building bsd-user-4-linux from source ..."
        local srcdir="/var/lib/pleiades-team/bsd/bsd-user-src"
        if [[ ! -d "$srcdir/.git" ]]; then
            git clone --depth 1 "$BSD_USER_REPO" "$srcdir" 2>/dev/null || {
                log "WARN: bsd-user-4-linux source clone failed — emulation layer unavailable"
                event "BSD_COMPAT|bsd_user|skipped|clone_failed"
                return 0
            }
        fi
        (cd "$srcdir" && make bsd-user 2>/dev/null) && {
            find "$srcdir" -name "qemu-bsd-user*" -executable 2>/dev/null | head -1 | xargs -I{} cp {} /usr/local/bin/bsd-user 2>/dev/null
            chmod +x /usr/local/bin/bsd-user 2>/dev/null || true
            log "bsd-user-4-linux built from source"
            event "BSD_COMPAT|bsd_user|installed|source_build"
            return 0
        }
    fi

    log "WARN: bsd-user-4-linux could not be installed — FreeBSD ELF emulation unavailable"
    event "BSD_COMPAT|bsd_user|unavailable|no_binary_no_build"
    return 0
}

# ------------------------------------------------------------
# 5. pkgsrc bootstrap
# ------------------------------------------------------------
bootstrap_pkgsrc() {
    if [[ -f "${PKGSRC_DIR}/bin/pkg_add" ]] || [[ -f "${PKGSRC_DIR}/sbin/pkg_add" ]]; then
        log "pkgsrc already bootstrapped at ${PKGSRC_DIR}"
        event "BSD_COMPAT|pkgsrc|already_present|${PKGSRC_DIR}"
        return 0
    fi

    log "Bootstrapping pkgsrc at ${PKGSRC_DIR} ..."
    local srcdir="/var/lib/pleiades-team/bsd/pkgsrc"

    if [[ ! -d "$srcdir/bootstrap" ]]; then
        local tmptar="/var/lib/pleiades-team/bsd/pkgsrc.tar.gz"
        if [[ ! -f "$tmptar" ]]; then
            curl -fsSL --max-time 300 "$PKGSRC_BOOTSTRAP_URL" -o "$tmptar" || {
                log "WARN: pkgsrc tarball download failed"
                event "BSD_COMPAT|pkgsrc|skipped|download_failed"
                return 0
            }
        fi
        mkdir -p "$srcdir"
        tar -xf "$tmptar" -C "$(dirname "$srcdir")" --strip-components=1 2>/dev/null || {
            log "WARN: pkgsrc tarball extraction failed"
            event "BSD_COMPAT|pkgsrc|skipped|extract_failed"
            return 0
        }
    fi

    (
        cd "$srcdir/bootstrap"
        ./bootstrap --prefix "$PKGSRC_DIR" --prefer-pkgsrc yes 2>&1 | tail -20
    ) && {
        log "pkgsrc bootstrapped → ${PKGSRC_DIR}"
        event "BSD_COMPAT|pkgsrc|ready|${PKGSRC_DIR}"
    } || {
        log "WARN: pkgsrc bootstrap failed — pkgsrc packages unavailable"
        event "BSD_COMPAT|pkgsrc|failed|bootstrap_error"
    }
    return 0
}

# ------------------------------------------------------------
# 6. Go asterope_pleiades-swarm — supervises conversion queue + health
# ------------------------------------------------------------
build_go_asterope_pleiades-swarm() {
    local bin="/usr/local/bin/asterope_pleiades-swarm"
    ensure_go || { log "Go not available; skipping pleiades-swarm build"; return 1; }

    local src
    src=$(mktemp -d)
    cat > "$src/main.go" <<'GOEOF'
package main

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	inbox      = "/run/pleiades/bsd-convert/inbox"
	outbox     = "/run/pleiades/bsd-convert/outbox"
	fifo       = "/run/pleiades/pleiades-nexus_fifo"
	alienBin   = "/usr/local/bin/alien-bsd"
	statefile  = "/run/pleiades/bsd_compat_state"
	logfile    = "/var/log/pleiades/asterope.log"
	pollSec    = 10
	healthSec  = 60
)

var flog *log.Logger
var mu sync.Mutex

func appendFifo(msg string) {
	f, err := os.OpenFile(fifo, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintln(f, msg)
}

func writeState(key, val string) {
	mu.Lock()
	defer mu.Unlock()
	data, _ := os.ReadFile(statefile)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	updated := false
	for i, l := range lines {
		if strings.HasPrefix(l, key+"=") {
			lines[i] = key + "=" + val
			updated = true
			break
		}
	}
	if !updated {
		lines = append(lines, key+"="+val)
	}
	_ = os.WriteFile(statefile, []byte(strings.Join(lines, "\n")+"\n"), 0644)
}

func processPackage(pkgPath string) {
	name := filepath.Base(pkgPath)
	flog.Printf("converting %s", name)
	appendFifo(fmt.Sprintf("BSD_CONVERT|start|%s", name))

	cmd := exec.Command(alienBin, "--both", "--output-dir", outbox, pkgPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		flog.Printf("ERROR converting %s: %v\n%s", name, err, out)
		appendFifo(fmt.Sprintf("BSD_CONVERT|error|%s|%v", name, err))
		return
	}
	flog.Printf("converted %s → %s", name, outbox)
	appendFifo(fmt.Sprintf("BSD_CONVERT|done|%s", name))
	_ = os.Remove(pkgPath)
}

func watchInbox() {
	seen := map[string]bool{}
	for {
		entries, err := os.ReadDir(inbox)
		if err != nil {
			time.Sleep(pollSec * time.Second)
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			ext := strings.ToLower(filepath.Ext(name))
			if ext != ".pkg" && ext != ".txz" && ext != ".tgz" && ext != ".tbz" {
				continue
			}
			pkgPath := filepath.Join(inbox, name)
			if !seen[pkgPath] {
				seen[pkgPath] = true
				go processPackage(pkgPath)
			}
		}
		time.Sleep(pollSec * time.Second)
	}
}

func healthLoop() {
	for {
		// brl strat check
		stratOK := "absent"
		if fi, err := os.Stat("/bedrock/strata"); err == nil && fi.IsDir() {
			entries, _ := os.ReadDir("/bedrock/strata")
			for _, e := range entries {
				if strings.HasPrefix(e.Name(), "freebsd") {
					stratOK = e.Name()
					break
				}
			}
		}

		// bsd-user check
		bsdUser := "absent"
		if _, err := exec.LookPath("bsd-user"); err == nil {
			bsdUser = "present"
		} else if fi, err := os.Stat("/usr/local/bin/bsd-user"); err == nil && fi.Mode()&0111 != 0 {
			bsdUser = "present"
		}

		// pkgsrc check
		pkgsrc := "absent"
		for _, p := range []string{"/opt/pkg/bin/pkg_add", "/opt/pkg/sbin/pkg_add"} {
			if _, err := os.Stat(p); err == nil {
				pkgsrc = "present"
				break
			}
		}

		// alien-bsd check
		alienOK := "absent"
		if _, err := os.Stat(alienBin); err == nil {
			alienOK = "present"
		}

		writeState("brl_strat", stratOK)
		writeState("bsd_user", bsdUser)
		writeState("pkgsrc", pkgsrc)
		writeState("alien_bsd", alienOK)
		writeState("updated_utc", time.Now().UTC().Format(time.RFC3339))

		appendFifo(fmt.Sprintf("BSD_HEALTH|strat=%s|bsd_user=%s|pkgsrc=%s|alien_bsd=%s",
			stratOK, bsdUser, pkgsrc, alienOK))

		flog.Printf("health: strat=%s bsd_user=%s pkgsrc=%s alien_bsd=%s",
			stratOK, bsdUser, pkgsrc, alienOK)

		time.Sleep(healthSec * time.Second)
	}
}

func main() {
	lf, err := os.OpenFile(logfile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		lf = os.Stderr
	}
	flog = log.New(lf, "[asterope_pleiades-swarm] ", log.LstdFlags|log.LUTC)
	flog.Println("starting")
	appendFifo("BSD_COMPAT|asterope_pleiades-swarm|starting")

	_ = os.MkdirAll(inbox, 0755)
	_ = os.MkdirAll(outbox, 0755)

	go healthLoop()
	watchInbox()
}
GOEOF

    (cd "$src" && go build -o "$bin" .) 2>/dev/null && {
        chmod +x "$bin"
        log "asterope_pleiades-swarm built → $bin"
        rm -rf "$src"
        return 0
    } || {
        log "WARN: asterope_pleiades-swarm build failed (Go not available or compilation error)"
        rm -rf "$src"
        return 1
    }
}

# ------------------------------------------------------------
# 7. Rust bsd_pkg_watcher — inotify-based inbox monitor (optional)
# ------------------------------------------------------------
build_rust_bsd_pkg_watcher() {
    local bin="/usr/local/bin/bsd_pkg_watcher"
    # Only build if inotify-rs is available; Go watcher is the primary path
    ensure_rust 2>/dev/null || { log "Rust not available; skipping pkg_watcher build"; return 0; }

    local src
    src=$(mktemp -d)
    mkdir -p "$src/src"

    cat > "$src/Cargo.toml" <<'TOMLEOF'
[package]
name = "bsd_pkg_watcher"
version = "0.1.0"
edition = "2021"

[dependencies]
notify = "6"
TOMLEOF

    cat > "$src/src/main.rs" <<'RUSTEOF'
use notify::{Config, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::Path;
use std::sync::mpsc::channel;
use std::time::Duration;
use std::process::Command;

const INBOX: &str = "/run/pleiades/bsd-convert/inbox";
const OUTBOX: &str = "/run/pleiades/bsd-convert/outbox";
const ALIEN: &str = "/usr/local/bin/alien-bsd";
const FIFO: &str = "/run/pleiades/pleiades-nexus_fifo";

fn append_fifo(msg: &str) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(FIFO) {
        let _ = writeln!(f, "{}", msg);
    }
}

fn is_pkg(name: &str) -> bool {
    let n = name.to_lowercase();
    n.ends_with(".pkg") || n.ends_with(".txz") || n.ends_with(".tgz") || n.ends_with(".tbz")
}

fn main() {
    let _ = std::fs::create_dir_all(INBOX);
    let _ = std::fs::create_dir_all(OUTBOX);

    let (tx, rx) = channel();
    let mut watcher = RecommendedWatcher::new(tx, Config::default()).expect("watcher");
    watcher.watch(Path::new(INBOX), RecursiveMode::NonRecursive).expect("watch inbox");

    for res in rx {
        match res {
            Ok(event) => {
                for path in &event.paths {
                    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                        if !is_pkg(name) { continue; }
                        append_fifo(&format!("BSD_WATCHER|new_pkg|{}", name));
                        let _ = Command::new(ALIEN)
                            .args(["--both", "--output-dir", OUTBOX,
                                   path.to_str().unwrap_or("")])
                            .status();
                        let _ = std::fs::remove_file(path);
                    }
                }
            }
            Err(e) => eprintln!("watch error: {e}"),
        }
    }
}
RUSTEOF

    (cd "$src" && cargo build --release -q 2>/dev/null) && {
        cp "$src/target/release/bsd_pkg_watcher" "$bin" 2>/dev/null && chmod +x "$bin"
        log "bsd_pkg_watcher built → $bin"
        rm -rf "$src"
        return 0
    } || {
        log "INFO: bsd_pkg_watcher build skipped (Rust/inotify unavailable; Go watcher covers this)"
        rm -rf "$src"
        return 0
    }
}

# ------------------------------------------------------------
# 8. Bash helper: strat health reporter (purplectl asterope-status)
# ------------------------------------------------------------
install_strat_health_helper() {
    cat > /usr/local/bin/asterope-status <<'HELPEREOF'
#!/usr/bin/env bash
# asterope-status — BSD compat layer health summary
STATE="/run/pleiades/bsd_compat_state"
INBOX="/run/pleiades/bsd-convert/inbox"
OUTBOX="/run/pleiades/bsd-convert/outbox"

echo "=== BSD Compat Layer (asterope) ==="
if [[ -f "$STATE" ]]; then
    cat "$STATE"
else
    echo "state: not yet initialized"
fi
echo ""
echo "conversion inbox:  $(ls "$INBOX" 2>/dev/null | wc -l) pending package(s)"
echo "conversion outbox: $(ls "$OUTBOX" 2>/dev/null | wc -l) converted package(s)"
echo ""
echo "drop a .pkg/.txz/.tgz into $INBOX to convert"
echo "results (.deb and .tbz2) appear in $OUTBOX"

# brl strat list if available
if command -v brl &>/dev/null; then
    echo ""
    echo "=== brl strat list ==="
    brl list 2>/dev/null || echo "(brl unavailable)"
fi
HELPEREOF
    chmod +x /usr/local/bin/asterope-status
    log "asterope-status helper installed"
}

# ------------------------------------------------------------
# 9. Systemd service
# ------------------------------------------------------------
install_systemd() {
    systemd_usable || return 0

    cat > /etc/systemd/system/asterope-bsd-compat.service <<UNIT
[Unit]
Description=Purple BSD Compatibility Layer (Asterope)
After=network.target pleiades-nexus-omniversal.service atlas-omniversal.service
Wants=pleiades-nexus-omniversal.service

[Service]
Type=simple
ExecStart=/usr/local/bin/asterope_pleiades-swarm
Restart=on-failure
RestartSec=15s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=asterope-bsd-compat
MemoryMax=256M
CPUQuota=25%

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now asterope-bsd-compat.service 2>/dev/null || true
    log "asterope-bsd-compat.service installed and started"
    event "BSD_COMPAT|systemd|asterope-bsd-compat.service|enabled"
}

# ------------------------------------------------------------
# 10. Purplectl integration — wire asterope commands into Atlas.sh's router
# ------------------------------------------------------------
wire_purplectl_asterope() {
    # Register asterope status handler in /run/pleiades so purplectl can find it
    local plugin_dir="/run/pleiades/purplectl-plugins"
    mkdir -p "$plugin_dir"
    cat > "$plugin_dir/asterope.sh" <<'PLUGEOF'
#!/usr/bin/env bash
# purplectl asterope plugin
case "${1:-}" in
    asterope-status)   asterope-status ;;
    alien-status)
        echo "alien-bsd: $(command -v alien-bsd 2>/dev/null || echo 'not installed')"
        echo "inbox:     $(ls /run/pleiades/bsd-convert/inbox 2>/dev/null | wc -l) files"
        echo "outbox:    $(ls /run/pleiades/bsd-convert/outbox 2>/dev/null | wc -l) files"
        ;;
    bsd-convert)
        shift
        [[ $# -eq 0 ]] && { echo "Usage: purplectl bsd-convert <package.pkg>"; exit 1; }
        alien-bsd --both --output-dir /run/pleiades/bsd-convert/outbox "$@"
        ;;
esac
PLUGEOF
    chmod +x "$plugin_dir/asterope.sh"
    log "purplectl asterope plugin installed"
}

# ------------------------------------------------------------
# main()
# ------------------------------------------------------------
main() {
    log "=== Asterope.sh starting ==="
    host_bridge_capability_report "asterope"

    # Register asterope_placeholder → bsd_compat in pleiades-swarm
    register_pleiades-swarm_capability \
        "asterope" \
        "bsd-compat" \
        "bsd_compat,alien_pkg_converter,pkgsrc_available,freebsd_strat"

    # Also update the asterope_placeholder .cap to show it's now active
    {
        echo "schema=pleiades-pleiades-swarm-capability-v1"
        echo "component=asterope_placeholder"
        echo "domain=bsd-compat"
        echo "capabilities=bsd_compat,alien_pkg_converter,pkgsrc_available,freebsd_strat"
        echo "authority=policy-gated"
        echo "ai_sidecar_required=no"
        echo "updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "status=active"
    } > /run/pleiades/capabilities/asterope_placeholder.cap 2>/dev/null || true

    log "Step 1/6: installing alien-bsd"
    install_alien_bsd || true

    log "Step 2/6: bootstrapping FreeBSD strat"
    bootstrap_freebsd_strat || true

    log "Step 3/6: installing bsd-user-4-linux"
    install_bsd_user || true

    log "Step 4/6: bootstrapping pkgsrc"
    bootstrap_pkgsrc || true

    log "Step 5/6: building Go asterope_pleiades-swarm"
    build_go_asterope_pleiades-swarm || true

    log "Step 6/6: building Rust bsd_pkg_watcher (optional)"
    build_rust_bsd_pkg_watcher || true

    install_strat_health_helper
    wire_purplectl_asterope
    install_systemd

    # Write initial state file
    {
        echo "schema=pleiades-bsd-compat-v1"
        echo "initialized_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "brl_strat=$(brl list 2>/dev/null | grep -c "^${BSD_STRAT_NAME}" || echo 0)"
        echo "bsd_user=$(command -v bsd-user &>/dev/null && echo present || echo absent)"
        echo "pkgsrc=$([ -f "${PKGSRC_DIR}/bin/pkg_add" ] || [ -f "${PKGSRC_DIR}/sbin/pkg_add" ] && echo present || echo absent)"
        echo "alien_bsd=$(command -v alien-bsd &>/dev/null && echo present || echo absent)"
        echo "convert_inbox=${CONVERT_INBOX}"
        echo "convert_outbox=${CONVERT_OUTBOX}"
    } > "$BSD_STATE_FILE" 2>/dev/null || true

    event "BSD_COMPAT|asterope|ready|all_steps_complete"
    log "=== Asterope.sh complete — BSD compat layer active ==="

    signal_ready "asterope"

    # Run asterope_pleiades-swarm in foreground if not under systemd
    if systemd_usable && systemctl is-active asterope-bsd-compat.service &>/dev/null; then
        log "asterope_pleiades-swarm running under systemd"
    elif [[ -x /usr/local/bin/asterope_pleiades-swarm ]]; then
        log "Launching asterope_pleiades-swarm in foreground"
        exec /usr/local/bin/asterope_pleiades-swarm
    else
        log "asterope_pleiades-swarm not built — BSD compat registered but no daemon running"
    fi
}

# ---------------------------------------------------------------------------
# Cross-ISA translation layer (Task #15)
# ---------------------------------------------------------------------------
cross_isa_init() {
    local host_arch; host_arch=$(uname -m)
    local qemu_ok=0 box64_ok=0

    command -v qemu-aarch64-static &>/dev/null && qemu_ok=1
    command -v box64               &>/dev/null && box64_ok=1

    if (( qemu_ok || box64_ok )); then
        CROSS_ISA_AVAILABLE=1
        local caps="cross_isa"
        (( qemu_ok ))  && caps+=",qemu_user"
        (( box64_ok ))  && caps+=",box64_x86_to_arm"
        register_pleiades-swarm_capability "cross_isa" "execution" "$caps"
        log "cross_isa_init: QEMU=${qemu_ok} Box64=${box64_ok} host=${host_arch}"
    else
        CROSS_ISA_AVAILABLE=0
        log "cross_isa_init: no cross-ISA tools found — run install-cross-isa.sh"
    fi
    export CROSS_ISA_AVAILABLE
}

# cross_isa_run <target-arch> <binary> [args...]
# target-arch: aarch64 | arm | riscv64 | x86_64
cross_isa_run() {
    local target_arch="${1:-}"; shift
    local binary="${1:-}"; shift
    local host_arch; host_arch=$(uname -m)

    [[ -z "$target_arch" || -z "$binary" ]] && { log "Usage: cross_isa_run <arch> <binary> [args]"; return 1; }
    [[ -x "$binary" ]] || { log "cross_isa_run: $binary not executable"; return 1; }

    # x86_64 target on aarch64 host → Box64
    if [[ "$target_arch" == "x86_64" && "$host_arch" == "aarch64" ]]; then
        if command -v box64 &>/dev/null; then
            log "cross_isa_run: box64 $binary $*"
            box64 "$binary" "$@"
            return $?
        else
            log "cross_isa_run: box64 not found for x86_64→aarch64"; return 1
        fi
    fi

    # Any other foreign arch → QEMU user-mode
    local qemu_bin="qemu-${target_arch}-static"
    if command -v "$qemu_bin" &>/dev/null; then
        log "cross_isa_run: $qemu_bin $binary $*"
        "$qemu_bin" "$binary" "$@"
        return $?
    fi

    # Fallback: binfmt_misc may handle it transparently
    if [[ -f /proc/sys/fs/binfmt_misc/qemu-"$target_arch" ]]; then
        log "cross_isa_run: binfmt_misc transparent exec $binary $*"
        "$binary" "$@"
        return $?
    fi

    log "cross_isa_run: no handler for $target_arch on $host_arch"
    return 1
}

bootstrap_wasm_runtime() {
    log "=== bootstrap_wasm_runtime ==="
    local wasmtime_ok=0 jco_ok=0

    # Install Wasmtime
    if command -v wasmtime &>/dev/null; then
        log "wasmtime already installed: $(wasmtime --version 2>/dev/null | head -1)"
        wasmtime_ok=1
    else
        local arch; arch=$(uname -m)
        local tag; tag=$(curl -fsSL https://api.github.com/repos/bytecodealliance/wasmtime/releases/latest 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/' || echo "")
        if [[ -n "$tag" ]]; then
            local url="https://github.com/bytecodealliance/wasmtime/releases/download/v${tag}/wasmtime-v${tag}-${arch}-linux.tar.xz"
            local tmp; tmp=$(mktemp -d)
            if curl -fsSL "$url" -o "$tmp/wasmtime.tar.xz" 2>/dev/null; then
                tar -xJf "$tmp/wasmtime.tar.xz" -C "$tmp"
                local bin; bin=$(find "$tmp" -name "wasmtime" -type f | head -1)
                if [[ -n "$bin" ]]; then
                    mkdir -p /opt/wasmtime
                    install -m755 "$bin" /opt/wasmtime/wasmtime
                    ln -sf /opt/wasmtime/wasmtime /usr/local/bin/wasmtime
                    wasmtime_ok=1
                    log "wasmtime $(wasmtime --version 2>/dev/null | head -1) installed"
                fi
            fi
            rm -rf "$tmp"
        fi
        [[ $wasmtime_ok -eq 0 ]] && log "WARN: wasmtime install failed — download manually"
    fi

    # Install jco
    if command -v jco &>/dev/null; then
        log "jco already installed: $(jco --version 2>/dev/null | head -1)"
        jco_ok=1
    elif command -v npm &>/dev/null; then
        npm install -g @bytecodealliance/jco 2>/dev/null && jco_ok=1 \
            || log "WARN: jco install failed"
    else
        log "WARN: npm not found — cannot install jco"
    fi

    # wasm-run wrapper
    cat > /usr/local/bin/wasm-run << 'WRAPPER'
#!/usr/bin/env bash
# wasm-run — purple team WASM module runner
[[ -x "$(command -v wasmtime)" ]] || { echo "wasm-run: wasmtime not found" >&2; exit 1; }
exec wasmtime "$@"
WRAPPER
    chmod +x /usr/local/bin/wasm-run

    # Register capability
    local caps="wasmtime_run,wasm_compile"
    [[ $jco_ok -eq 1 ]] && caps="$caps,jco_transpile"
    register_pleiades-swarm_capability "wasm_runtime" "execution" "$caps"
    log "wasm_runtime: wasmtime=${wasmtime_ok} jco=${jco_ok}"
}

_maia_hook() {
    local event="${1:-}"
    case "$event" in
        FORENSICS_DETECTED*|PROMISC_DETECTED*|CONTAINER_DEPTH*)
            log "maia_hook: $event — BSD compat layer passive"
            ;;
        *)
            ;;
    esac
}

main "$@"
