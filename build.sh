#!/usr/bin/env bash
# build.sh — main entry point for the RK3588 OS builder
#
# Usage:
#   ./build.sh [options] <board> [stage ...]
#
# Options:
#   --prebuilt-uboot   Use known-good prebuilt U-Boot instead of building from source
#
# Examples:
#   ./build.sh rock-5b                          # run all stages
#   ./build.sh --prebuilt-uboot rock-5b         # use prebuilt U-Boot binaries
#   ./build.sh rock-5b prerequisites            # check host tools only
#   ./build.sh rock-5b fetch-dts kernel         # fetch DTS + build kernel
#   ./build.sh rock-5b rootfs image             # customize rootfs + assemble image
#
# Stages:
#   prerequisites   00 — verify host tools & kernel source
#   fetch-kernel    01 — clone/switch kernel source based on KERNEL_PROFILE
#   fetch-dts       01 — download Rock 5B DTS from Radxa
#   kernel          02 — cross-compile kernel Image, DTBs, modules
#   download-rootfs 03 — download Ubuntu arm64 base tarball
#   rootfs          04 — extract, chroot, customise rootfs       [sudo]
#   uboot           05 — build or fetch U-Boot bootloader
#   image           06 — assemble raw dd-able .img               [sudo]

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${BUILDER_DIR}/scripts"

# ── logging to file ─────────────────────────────────────────────────────────
LOG_DIR="${BUILDER_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-$(date '+%Y%m%d-%H%M%S').log"

# Duplicate all stdout and stderr to the log file while keeping terminal output.
# Process substitution requires /dev/fd (symlink to /proc/self/fd).
[[ -e /dev/fd ]] || ln -sf /proc/self/fd /dev/fd
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Log file: ${LOG_FILE}"

# ── stage map ────────────────────────────────────────────────────────────────
declare -A STAGE_SCRIPT=(
    [prerequisites]="00-check-prerequisites.sh"
    [fetch-kernel]="01-fetch-kernel.sh"
    [fetch-dts]="01-fetch-dts.sh"
    [kernel]="02-build-kernel.sh"
    [download-rootfs]="03-download-rootfs.sh"
    [rootfs]="04-customize-rootfs.sh"
    [uboot]="05-build-uboot.sh"
    [image]="06-assemble-image.sh"
)

ALL_STAGES=(prerequisites fetch-kernel fetch-dts kernel download-rootfs rootfs uboot image)

# ── usage ────────────────────────────────────────────────────────────────────
usage() {
    sed -n '2,/^$/{ s/^# //; s/^#//; p; }' "$0"
    exit 1
}

# ── parse args ───────────────────────────────────────────────────────────────
USE_PREBUILT_UBOOT=false
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --prebuilt-uboot) USE_PREBUILT_UBOOT=true; shift ;;
        *) echo "Error: Unknown option '$1'"; usage ;;
    esac
done

BOARD="${1:-}"
[[ -z "$BOARD" ]] && usage
shift

export USE_PREBUILT_UBOOT
export KERNEL_PROFILE="${KERNEL_PROFILE:-}"

# Validate board config exists
[[ -f "${BUILDER_DIR}/config/boards/${BOARD}.conf" ]] \
    || { echo "Error: No config for board '${BOARD}' in config/boards/"; exit 1; }

# Determine which stages to run
if [[ $# -eq 0 ]]; then
    STAGES=("${ALL_STAGES[@]}")
else
    STAGES=("$@")
fi

# ── run stages ───────────────────────────────────────────────────────────────
for stage in "${STAGES[@]}"; do
    script="${STAGE_SCRIPT[$stage]:-}"
    if [[ -z "$script" ]]; then
        echo "Error: Unknown stage '${stage}'"
        echo "Valid stages: ${!STAGE_SCRIPT[*]}"
        exit 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Stage: ${stage}  (${script})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    bash "${SCRIPTS}/${script}" "$BOARD"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  All stages completed successfully."
echo "  Log: ${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Strip ANSI colour codes from the log file so it's plain text
sed -i 's/\x1b\[[0-9;]*m//g' "$LOG_FILE"
