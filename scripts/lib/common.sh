#!/usr/bin/env bash
# common.sh — shared helpers for the OS builder pipeline
set -euo pipefail

# ── colours (disabled when stdout is not a tty) ─────────────────────────────
if [[ -t 1 ]]; then
    _RED=$'\033[0;31m'  _YEL=$'\033[0;33m'
    _GRN=$'\033[0;32m'  _CYN=$'\033[0;36m'
    _RST=$'\033[0m'
else
    _RED='' _YEL='' _GRN='' _CYN='' _RST=''
fi

# ── logging ──────────────────────────────────────────────────────────────────
log_info()  { echo "${_GRN}[INFO]${_RST}  $*"; }
log_warn()  { echo "${_YEL}[WARN]${_RST}  $*" >&2; }
log_error() { echo "${_RED}[ERROR]${_RST} $*" >&2; }
log_step()  { echo "${_CYN}==>${_RST} $*"; }

die() { log_error "$@"; exit 1; }

# ── cleanup stack ────────────────────────────────────────────────────────────
# Stages push entries like "umount /path" or "losetup -d /dev/loopN".
# The EXIT trap walks the stack in reverse order.
_CLEANUP_STACK=()

cleanup_push() { _CLEANUP_STACK+=("$*"); }

_run_cleanup() {
    local i
    for (( i=${#_CLEANUP_STACK[@]}-1; i>=0; i-- )); do
        log_info "cleanup: ${_CLEANUP_STACK[$i]}"
        eval "${_CLEANUP_STACK[$i]}" || true
    done
}
trap _run_cleanup EXIT

# ── config loader ────────────────────────────────────────────────────────────
# Resolve BUILDER_DIR first (directory containing build.sh).
BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")/.." && pwd)"

load_config() {
    local board="${1:?usage: load_config <board>}"
    local global_conf="${BUILDER_DIR}/config/global.conf"
    local board_conf="${BUILDER_DIR}/config/boards/${board}.conf"

    [[ -f "$global_conf" ]] || die "Missing $global_conf"
    [[ -f "$board_conf"  ]] || die "Missing $board_conf"

    # shellcheck disable=SC1090
    source "$global_conf"
    # shellcheck disable=SC1090
    source "$board_conf"

    # Load kernel profile (if specified in board config)
    if [[ -n "${KERNEL_PROFILE:-}" ]]; then
        local profile_conf="${BUILDER_DIR}/config/kernel-profiles/${KERNEL_PROFILE}.conf"
        if [[ -f "$profile_conf" ]]; then
            log_info "Loading kernel profile: ${KERNEL_PROFILE}"
            # shellcheck disable=SC1090
            source "$profile_conf"
        else
            die "Kernel profile not found: ${profile_conf}"
        fi
    fi

    # Apply Tyr GPU driver overrides (must come after kernel profile)
    # Tyr patches are applied on top of the 6.18 kernel in 02-build-kernel.sh
    if [[ "${USE_TYR:-false}" == "true" ]]; then
        [[ "${KERNEL_PROFILE:-}" == "6.18" ]] \
            || die "--tyr requires KERNEL_PROFILE=6.18"
        log_info "Tyr mode: Rust GPU driver (patches applied at build time)"
        KERNEL_EXTRA_CONFIG="config/kernel/rk3588-tyr.config"
        GPU_DRIVER="tyr"
        KERNEL_LLVM="1"
    fi

    # Resolve relative paths in global.conf to absolute
    KERNEL_SRC="$(cd "${BUILDER_DIR}" && realpath "${KERNEL_SRC}")"
    KERNELS_OUT="$(cd "${BUILDER_DIR}" && realpath -m "${KERNELS_OUT}")"
    IMAGES_OUT="$(cd "${BUILDER_DIR}" && realpath -m "${IMAGES_OUT}")"
    UBOOT_SRC="$(cd "${BUILDER_DIR}" && realpath -m "${UBOOT_SRC}")"
    RKBIN_SRC="$(cd "${BUILDER_DIR}" && realpath -m "${RKBIN_SRC}")"
    TMP_DIR="${BUILDER_DIR}/tmp/${board}"

    # Auto-detect kernel version from source tree Makefile
    if [[ "${KERNEL_VERSION}" == "auto" ]]; then
        local kmakefile="${KERNEL_SRC}/Makefile"
        [[ -f "$kmakefile" ]] || die "KERNEL_VERSION=auto but ${kmakefile} not found"
        local _ver _patch _sub
        _ver="$(sed -n  's/^VERSION *= *//p'    "$kmakefile")"
        _patch="$(sed -n 's/^PATCHLEVEL *= *//p' "$kmakefile")"
        _sub="$(sed -n  's/^SUBLEVEL *= *//p'   "$kmakefile")"
        KERNEL_VERSION="${_ver}.${_patch}.${_sub}"
        log_info "Auto-detected kernel version: ${KERNEL_VERSION}"
    fi

    # Derived paths
    KERNEL_OUT="${KERNELS_OUT}/${KERNEL_VERSION}/${BOARD_CHIP}"
    IMAGE_OUT="${IMAGES_OUT}/${KERNEL_VERSION}/${BOARD_CHIP}"
    BUILD_ID="v$(date +%s)"
    IMAGE_NAME="${board}-cpedgeos-${UBUNTU_VERSION}-${BUILD_ID}.img"

    export BUILDER_DIR KERNEL_SRC KERNELS_OUT IMAGES_OUT TMP_DIR
    export KERNEL_OUT IMAGE_OUT IMAGE_NAME BUILD_ID
    export UBOOT_SRC RKBIN_SRC
}

# ── helpers ──────────────────────────────────────────────────────────────────
require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

require_sudo() {
    if [[ $EUID -ne 0 ]]; then
        die "This stage must be run as root (sudo)."
    fi
}

ensure_dir() {
    local d
    for d in "$@"; do mkdir -p "$d"; done
}
