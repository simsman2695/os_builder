#!/usr/bin/env bash
# flash-spi-uboot.sh — flash mainline U-Boot to SPI NOR on Rock 5B
#
# Run this ON THE TARGET BOARD (not the build host).
# Requires: mtd-utils (flash_erase), root access.
#
# Usage:
#   sudo ./flash-spi-uboot.sh
#
# Supports two MTD layouts:
#   - Single partition:  mtd0 = entire SPI (e.g. mainline kernel, "spi5.0")
#   - Mender partitions: mtd0 = idbloader region starting at SPI 0x8000
#
# RK3588 SPI NOR layout (mainline U-Boot, CONFIG_SYS_SPI_U_BOOT_OFFS=0x60000):
#   idbloader.img at SPI offset 0x8000
#   u-boot.itb    at SPI offset 0x60000
# Note: these are NOT the same as SD/eMMC sector offsets in board config.
#
# Recovery: if something goes wrong, use Rockchip maskrom mode
# (hold maskrom button + USB) with rkdeveloptool to reflash.

set -euo pipefail

die() { echo "[ERROR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root (sudo)"

# ── locate binaries (same directory as this script) ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IDBLOADER="${SCRIPT_DIR}/idbloader.img"
UBOOT_ITB="${SCRIPT_DIR}/u-boot.itb"

[[ -f "$IDBLOADER" ]] || die "idbloader.img not found in ${SCRIPT_DIR}"
[[ -f "$UBOOT_ITB" ]]  || die "u-boot.itb not found in ${SCRIPT_DIR}"

# ── verify MTD devices exist ─────────────────────────────────────────────────
[[ -c /dev/mtd0 ]] || die "/dev/mtd0 not found — is this a Rock 5B with SPI flash?"
[[ -b /dev/mtdblock0 ]] || die "/dev/mtdblock0 not found"

command -v flash_erase >/dev/null || die "flash_erase not found. Install mtd-utils: apt install mtd-utils"

# ── show current MTD layout ──────────────────────────────────────────────────
echo "Current SPI flash layout:"
cat /proc/mtd
echo ""

# ── detect MTD layout and set offsets ────────────────────────────────────────
# RK3588 boot ROM expects:
#   idbloader at SPI absolute offset 0x8000
#   u-boot.itb at SPI absolute offset 0x60000
#
# Single-partition layout (mainline kernel): mtd0 covers entire SPI from 0x0
#   → idbloader at mtd0 offset 0x8000, u-boot.itb at mtd0 offset 0x60000
#
# Mender multi-partition layout: mtd0 starts at SPI 0x8000
#   → idbloader at mtd0 offset 0x0, u-boot.itb at mtd0 offset 0x58000

MTD_COUNT=$(grep -c "^mtd" /proc/mtd || true)

if [[ "$MTD_COUNT" -le 1 ]]; then
    # Single partition — mtd0 is the whole SPI starting at offset 0x0
    IDBLOADER_OFFSET=$((0x8000))
    UBOOT_ITB_OFFSET=$((0x60000))
    echo "Detected: single MTD partition (whole SPI)"
else
    # Multi-partition (Mender layout) — mtd0 starts at SPI 0x8000
    IDBLOADER_OFFSET=0
    UBOOT_ITB_OFFSET=$((0x58000))
    echo "Detected: multi-partition MTD layout (Mender)"
fi

echo "  idbloader offset: 0x$(printf '%x' $IDBLOADER_OFFSET)"
echo "  u-boot.itb offset: 0x$(printf '%x' $UBOOT_ITB_OFFSET)"
echo ""

IDBLOADER_SIZE=$(stat -c%s "$IDBLOADER")
UBOOT_ITB_SIZE=$(stat -c%s "$UBOOT_ITB")
echo "  idbloader.img: ${IDBLOADER_SIZE} bytes"
echo "  u-boot.itb:    ${UBOOT_ITB_SIZE} bytes"

# ── confirm before flashing ──────────────────────────────────────────────────
echo ""
echo "This will REPLACE the SPI bootloader with mainline U-Boot."
echo ""
read -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── flash ────────────────────────────────────────────────────────────────────
# Erase the entire SPI flash, then write each binary at its offset via the
# block device interface. This avoids building a 16MB image and the flashcp
# verification stall that comes with it.
echo ""
echo "Erasing mtd0..."
flash_erase /dev/mtd0 0 0

echo "Writing idbloader.img at offset 0x$(printf '%x' $IDBLOADER_OFFSET)..."
dd if="$IDBLOADER" of=/dev/mtdblock0 bs=4096 seek=$((IDBLOADER_OFFSET / 4096)) conv=fsync status=progress

echo "Writing u-boot.itb at offset 0x$(printf '%x' $UBOOT_ITB_OFFSET)..."
dd if="$UBOOT_ITB" of=/dev/mtdblock0 bs=4096 seek=$((UBOOT_ITB_OFFSET / 4096)) conv=fsync status=progress

# ── verify ───────────────────────────────────────────────────────────────────
echo ""
echo "Verifying writes..."
if cmp -s -n "$IDBLOADER_SIZE" "$IDBLOADER" <(dd if=/dev/mtdblock0 bs=4096 skip=$((IDBLOADER_OFFSET / 4096)) count=$(( (IDBLOADER_SIZE + 4095) / 4096 )) 2>/dev/null); then
    echo "  idbloader.img: OK"
else
    echo "  idbloader.img: MISMATCH — flash may have failed"
fi
if cmp -s -n "$UBOOT_ITB_SIZE" "$UBOOT_ITB" <(dd if=/dev/mtdblock0 bs=4096 skip=$((UBOOT_ITB_OFFSET / 4096)) count=$(( (UBOOT_ITB_SIZE + 4095) / 4096 )) 2>/dev/null); then
    echo "  u-boot.itb: OK"
else
    echo "  u-boot.itb: MISMATCH — flash may have failed"
fi

# Erase old Mender partitions if they exist
if [[ -c /dev/mtd4 ]]; then
    echo "Erasing mtd4 (old uboot_env)..."
    flash_erase /dev/mtd4 0 0
fi

if [[ -c /dev/mtd6 ]]; then
    echo "Erasing mtd6 (old uboot)..."
    flash_erase /dev/mtd6 0 0
fi

echo ""
echo "SPI flash complete."
echo ""
echo "Boot order: mmc1 (SD) → mmc0 (eMMC) → nvme → usb → pxe → dhcp"
echo ""
echo "Reboot to test:"
echo "  sudo reboot"
