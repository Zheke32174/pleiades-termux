#!/data/data/com.termux/files/usr/bin/env bash
source "${PLEIADES_TERMUX_LIB:-}" 2>/dev/null || true
# install-cross-isa.sh — install QEMU user-mode + Box64 cross-ISA translation layer
# Task #15 subtasks: (1) QEMU+binfmt_misc, (2) Box64, (3) Asterope.sh integration
#
# Third-party tools installed (not vendored — cloned/downloaded from upstream):
#   Box64         ptitSeb            MIT        https://github.com/ptitSeb/box64
#   Wasmtime      Bytecode Alliance  Apache-2.0 https://github.com/bytecodealliance/wasmtime
#   QEMU          QEMU project       GPL-2.0+   https://www.qemu.org
#                 NOTE: QEMU is GPL-2.0+. This script installs the binary via apt or download.
#                 No QEMU source is vendored here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_TAG="cross-isa"
log()   { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die()   { log "ERROR: $*"; exit 1; }

HOST_ARCH=$(uname -m)
CONTAINER_ROOT="${CONTAINER_ROOT:-${PLEIADES_CONTAINER_ROOT:-$(dirname "$SCRIPT_DIR")}}"
BOX64_VERSION="v0.3.2"
BOX64_INSTALL="/usr/local/bin/box64"
QEMU_STATIC_ARM64="/usr/bin/qemu-aarch64-static"

# ---------------------------------------------------------------------------
# 1. QEMU user-mode + binfmt_misc
# ---------------------------------------------------------------------------
install_qemu_user() {
    log "=== Step 1: QEMU user-mode ==="

    if command -v qemu-aarch64-static &>/dev/null && command -v qemu-x86_64-static &>/dev/null; then
        log "qemu-user-static already installed"
    elif command -v apt-get &>/dev/null; then
        log "Installing qemu-user-static via apt"
        apt-get install -y qemu-user-static binfmt-support || die "apt install failed"
    elif command -v emerge &>/dev/null; then
        log "Installing qemu via emerge (USE=static-user)"
        USE="static-user" emerge --ask=n app-emulation/qemu || die "emerge qemu failed"
    else
        log "WARN: no apt-get or emerge found — skipping QEMU install"
        return 0
    fi

    # Register binfmt_misc handlers
    if [[ -d /proc/sys/fs/binfmt_misc ]]; then
        log "Registering binfmt_misc handlers"
        # AArch64
        if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] && [[ -f "$QEMU_STATIC_ARM64" ]]; then
            echo ":qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${QEMU_STATIC_ARM64}:F" \
                > /proc/sys/fs/binfmt_misc/register 2>/dev/null || log "WARN: binfmt_misc aarch64 registration skipped (may need root)"
        fi
        # RISC-V 64
        if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]] && [[ -f "/usr/bin/qemu-riscv64-static" ]]; then
            echo ":qemu-riscv64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-riscv64-static:F" \
                > /proc/sys/fs/binfmt_misc/register 2>/dev/null || log "WARN: binfmt_misc riscv64 registration skipped"
        fi
        # Write persistent binfmt.d config
        mkdir -p /etc/binfmt.d
        cat > /etc/binfmt.d/qemu-user-static.conf << 'BINFMT'
# qemu-user-static binfmt_misc registrations
:qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F
:qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:F
:qemu-riscv64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-riscv64-static:F
BINFMT
        log "binfmt.d config written to /etc/binfmt.d/qemu-user-static.conf"
    else
        log "WARN: /proc/sys/fs/binfmt_misc not available (may need kernel module)"
    fi

    log "QEMU user-mode step complete"
}

# ---------------------------------------------------------------------------
# 2. Box64 (x86-64 → ARM64 translation)
# ---------------------------------------------------------------------------
install_box64() {
    log "=== Step 2: Box64 ==="

    if [[ "$HOST_ARCH" != "aarch64" ]]; then
        log "Host is $HOST_ARCH — Box64 is only needed on aarch64; skipping install, registering stub"
        cat > "$BOX64_INSTALL" << 'STUB'
#!/bin/bash
# Box64 stub — only needed on aarch64 host
echo "box64: not applicable on $(uname -m)" >&2
exit 1
STUB
        chmod +x "$BOX64_INSTALL"
        return 0
    fi

    if command -v box64 &>/dev/null; then
        log "box64 already installed at $(which box64)"
        return 0
    fi

    # Try prebuilt release first
    local tmpdir; tmpdir=$(mktemp -d)
    local release_url="https://github.com/ptitSeb/box64/releases/download/${BOX64_VERSION}/box64-arm_64-${BOX64_VERSION}.tar.gz"
    log "Downloading box64 prebuilt from $release_url"
    if curl -fsSL "$release_url" -o "$tmpdir/box64.tar.gz" 2>/dev/null; then
        tar -xzf "$tmpdir/box64.tar.gz" -C "$tmpdir"
        install -m755 "$tmpdir/box64" "$BOX64_INSTALL"
        rm -rf "$tmpdir"
        log "box64 installed from prebuilt release"
    else
        log "Prebuilt download failed — building from source"
        rm -rf "$tmpdir"
        if ! command -v cmake &>/dev/null; then
            apt-get install -y cmake build-essential || die "cmake install failed"
        fi
        local srcdir="/opt/box64-src"
        if [[ ! -d "$srcdir" ]]; then
            git clone --depth=1 https://github.com/ptitSeb/box64.git "$srcdir" || die "git clone box64 failed"
        fi
        mkdir -p "$srcdir/build"
        cmake -S "$srcdir" -B "$srcdir/build" -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
              -DCMAKE_INSTALL_PREFIX=/usr/local || die "cmake configure failed"
        make -C "$srcdir/build" -j"$(nproc)" || die "box64 build failed"
        make -C "$srcdir/build" install || die "box64 install failed"
        log "box64 built and installed from source"
    fi

    # Verify
    if box64 --version 2>&1 | grep -q "Box64"; then
        log "box64 verified: $(box64 --version 2>&1 | head -1)"
    else
        log "WARN: box64 installed but --version check inconclusive"
    fi
}

# ---------------------------------------------------------------------------
# 3. Copy into container rootfs if running on host
# ---------------------------------------------------------------------------
install_into_container() {
    log "=== Step 3: Container rootfs sync ==="
    if [[ -d "$CONTAINER_ROOT/usr/local/bin" ]]; then
        cp -f "$BOX64_INSTALL" "$CONTAINER_ROOT/usr/local/bin/box64" 2>/dev/null || true
        log "box64 copied to container rootfs"
    fi
    if [[ -d "$CONTAINER_ROOT/etc/binfmt.d" ]] || mkdir -p "$CONTAINER_ROOT/etc/binfmt.d" 2>/dev/null; then
        cp -f /etc/binfmt.d/qemu-user-static.conf "$CONTAINER_ROOT/etc/binfmt.d/" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    log "Cross-ISA translation layer installer — host: $HOST_ARCH"
    install_qemu_user
    install_box64
    install_into_container

    log "=== Cross-ISA install complete ==="
    log "QEMU user-mode: $(command -v qemu-aarch64-static 2>/dev/null || echo 'not found')"
    log "Box64:          $(command -v box64 2>/dev/null || echo 'not found / not applicable')"
    log ""
    log "Next: run Asterope.sh to activate cross_isa_init() in the pleiades-swarm"
}

main "$@"
