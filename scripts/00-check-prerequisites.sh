#!/usr/bin/env bash
# 00-check-prerequisites.sh — verify host tools, kernel source, and disk space
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"

log_step "Checking prerequisites"

# ── required host commands ───────────────────────────────────────────────────
REQUIRED_CMDS=(
    "${CC}"                        # cross-compiler
    "${CROSS_COMPILE}objcopy"
    make bc flex bison              # kernel build
    dtc                             # device-tree compiler
    parted losetup mkfs.ext4        # image assembly
    wget curl git                   # fetching
    rsync tar gzip sha256sum
    python3 swig                    # U-Boot build
)

missing=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

# qemu — accept either qemu-aarch64-static (older) or qemu-aarch64 (newer binfmt)
if command -v qemu-aarch64-static &>/dev/null; then
    QEMU_AARCH64="$(command -v qemu-aarch64-static)"
elif command -v qemu-aarch64 &>/dev/null; then
    QEMU_AARCH64="$(command -v qemu-aarch64)"
else
    missing+=("qemu-aarch64-static or qemu-aarch64")
fi

if (( ${#missing[@]} )); then
    log_error "Missing host tools: ${missing[*]}"
    log_info  "Install with:  sudo apt install gcc-12-aarch64-linux-gnu g++-12-aarch64-linux-gnu \\
  device-tree-compiler bison flex bc libssl-dev parted qemu-user-static \\
  rsync wget curl git python3 swig"
    log_info  "(On newer Ubuntu, qemu-user-binfmt replaces qemu-user-static)"
    exit 1
fi

# ── pyelftools (needed by U-Boot build to process BL31 ELF) ─────────────────
if ! python3 -c "import elftools" &>/dev/null; then
    log_error "Python package 'pyelftools' is missing."
    log_info  "Install with:  pip3 install pyelftools  (or: sudo apt install python3-pyelftools)"
    exit 1
fi
log_info "pyelftools found."
log_info "All required host tools found."
log_info "Using qemu: ${QEMU_AARCH64}"

# ── kernel source ────────────────────────────────────────────────────────────
if [[ ! -d "${KERNEL_SRC}/Makefile" && ! -f "${KERNEL_SRC}/Makefile" ]]; then
    if [[ ! -f "${KERNEL_SRC}/Makefile" ]]; then
        die "Kernel source not found at ${KERNEL_SRC} (no Makefile)."
    fi
fi
log_info "Kernel source found at ${KERNEL_SRC}"

# ── disk space (rough check: need ~8 GB free) ───────────────────────────────
avail_kb=$(df --output=avail "${BUILDER_DIR}" | tail -1)
avail_gb=$(( avail_kb / 1024 / 1024 ))
if (( avail_gb < 8 )); then
    log_warn "Only ${avail_gb} GB free in ${BUILDER_DIR} — build may run out of space."
else
    log_info "Disk space OK (${avail_gb} GB available)."
fi

log_step "Prerequisites check passed."
