#!/usr/bin/env bash
# flash-spi-uboot.sh — flash inindev mainline U-Boot to SPI NOR on Rock 5B
#
# Run this ON THE TARGET BOARD (not the build host).
# Requires: mtd-utils (flash_erase, flashcp), root access.
#
# Usage:
#   sudo ./flash-spi-uboot.sh
#
# This replaces the SPI bootloader with a standard mainline U-Boot that
# supports extlinux.conf boot from SD card, NVMe, eMMC, etc.
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

command -v flash_erase >/dev/null || die "flash_erase not found. Install mtd-utils: apt install mtd-utils"
command -v flashcp >/dev/null      || die "flashcp not found. Install mtd-utils: apt install mtd-utils"

# ── show current MTD layout ──────────────────────────────────────────────────
echo "Current SPI flash layout:"
cat /proc/mtd
echo ""

# ── build combined mtd0 image ────────────────────────────────────────────────
# mtd0 starts at SPI offset 0x8000 and is 0x378000 bytes.
# idbloader.img goes at mtd0 offset 0x0 (SPI 0x8000)
# u-boot.itb goes at mtd0 offset 0x38000 (SPI 0x40000, where SPL expects it)
MTD0_SIZE=$(cat /sys/class/mtd/mtd0/size)
MTD0_IMG=$(mktemp /tmp/spi_mtd0.XXXXXX)
trap "rm -f $MTD0_IMG" EXIT

echo "Building combined SPI image for mtd0 (${MTD0_SIZE} bytes)..."

dd if=/dev/zero of="$MTD0_IMG" bs=1 count="$MTD0_SIZE" status=none

# idbloader at offset 0 within mtd0
dd if="$IDBLOADER" of="$MTD0_IMG" conv=notrunc status=none
echo "  idbloader.img written at mtd0 offset 0x0 (SPI 0x8000)"

# u-boot.itb at offset 0x38000 within mtd0 (= SPI 0x40000)
dd if="$UBOOT_ITB" of="$MTD0_IMG" seek=$((0x38000)) bs=1 conv=notrunc status=none
echo "  u-boot.itb written at mtd0 offset 0x38000 (SPI 0x40000)"

# ── confirm before flashing ──────────────────────────────────────────────────
echo ""
echo "This will REPLACE the SPI bootloader with mainline U-Boot."
echo "The Mender bootloader will be erased."
echo ""
echo "Partitions to be modified:"
echo "  mtd0 (idbloader) — new mainline SPL + u-boot.itb"
echo "  mtd4 (uboot_env) — erase old Mender environment"
echo "  mtd6 (uboot)     — erase old Mender U-Boot"
echo ""
read -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── flash ────────────────────────────────────────────────────────────────────
echo ""
echo "Erasing mtd0 (idbloader)..."
flash_erase /dev/mtd0 0 0

echo "Writing new bootloader to mtd0..."
flashcp -v "$MTD0_IMG" /dev/mtd0

# Erase old Mender U-Boot environment so new U-Boot uses defaults
if [[ -c /dev/mtd4 ]]; then
    echo "Erasing mtd4 (uboot_env)..."
    flash_erase /dev/mtd4 0 0
fi

# Erase old Mender U-Boot binary (no longer needed)
if [[ -c /dev/mtd6 ]]; then
    echo "Erasing mtd6 (old uboot)..."
    flash_erase /dev/mtd6 0 0
fi

echo ""
echo "SPI flash complete."
echo ""
echo "New boot order: mmc1 (SD) → mmc0 (eMMC) → nvme → usb → pxe → dhcp"
echo ""
echo "Insert your SD card and reboot to test:"
echo "  sudo reboot"
