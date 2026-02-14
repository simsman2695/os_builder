#!/usr/bin/env bash
# 06-assemble-image.sh — create raw dd-able .img with GPT + rootfs [sudo]
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"
require_sudo

# Defaults for optional board config variables
BOOT_PART_ENABLE="${BOOT_PART_ENABLE:-false}"
WRITE_RAW_BOOTLOADER="${WRITE_RAW_BOOTLOADER:-true}"

log_step "Assembling image for ${BOARD_NAME}"

ensure_dir "$IMAGE_OUT"

ROOTFS_DIR="${TMP_DIR}/rootfs"
IMG_FILE="${IMAGE_OUT}/${IMAGE_NAME}"
IDBLOADER="${TMP_DIR}/idbloader.img"
UBOOT_ITB="${TMP_DIR}/u-boot.itb"

[[ -d "${ROOTFS_DIR}/etc" ]] || die "Rootfs not found at ${ROOTFS_DIR}. Run 04-customize-rootfs.sh first."

# ── calculate image size ───────────────────────────────────────────────────
if [[ "${IMAGE_SIZE_MB}" == "auto" ]]; then
    ROOTFS_USED_MB="$(du -sm "${ROOTFS_DIR}" | awk '{print $1}')"
    # Add 20% headroom + bootloader area, round up to nearest 64 MB
    HEADROOM_MB=$(( ROOTFS_USED_MB / 5 ))
    [[ "$HEADROOM_MB" -lt 128 ]] && HEADROOM_MB=128
    IMAGE_SIZE_MB=$(( ROOTFS_USED_MB + HEADROOM_MB + ROOTFS_OFFSET_MB ))
    IMAGE_SIZE_MB=$(( (IMAGE_SIZE_MB + 63) / 64 * 64 ))
    log_info "Rootfs is ${ROOTFS_USED_MB}M → auto-sized image to ${IMAGE_SIZE_MB}M"
fi

# ── create sparse image ─────────────────────────────────────────────────────
log_info "Creating ${IMAGE_SIZE_MB}M sparse image ..."
truncate -s "${IMAGE_SIZE_MB}M" "$IMG_FILE"

# ── GPT partition table ─────────────────────────────────────────────────────
log_info "Creating GPT partition table ..."
parted -s "$IMG_FILE" mklabel gpt

if [[ "$BOOT_PART_ENABLE" == "true" ]]; then
    # EFI System Partition (empty FAT16, triggers vendor U-Boot distro boot)
    # Use sector addressing throughout to avoid boundary collisions between
    # the ESP end and rootfs start (byte/MiB rounding can overlap by 1 sector).
    BOOT_START_S="${BOOT_PART_OFFSET_SECTOR}"
    BOOT_END_S=$(( BOOT_PART_OFFSET_SECTOR + BOOT_PART_SIZE_SECTORS - 1 ))
    ROOTFS_START_S=$(( BOOT_PART_OFFSET_SECTOR + BOOT_PART_SIZE_SECTORS ))
    log_info "Creating ESP: sector ${BOOT_START_S} – ${BOOT_END_S}"
    parted -s "$IMG_FILE" mkpart ESP fat16 "${BOOT_START_S}s" "${BOOT_END_S}s"
    parted -s "$IMG_FILE" set 1 esp on
    log_info "Creating rootfs: sector ${ROOTFS_START_S} – end"
    parted -s "$IMG_FILE" mkpart rootfs ext4 "${ROOTFS_START_S}s" 100%
    ROOTFS_PART_NUM=2
else
    parted -s "$IMG_FILE" mkpart rootfs ext4 "${ROOTFS_OFFSET_MB}MiB" 100%
    parted -s "$IMG_FILE" set 1 legacy_boot on
    ROOTFS_PART_NUM=1
fi

# ── set up loop device ──────────────────────────────────────────────────────
# Ensure loop devices are available (kernel built-in may need device nodes created)
if [[ ! -e /dev/loop-control ]]; then
    modprobe loop 2>/dev/null || true
fi
if [[ ! -e /dev/loop-control ]]; then
    log_info "Creating /dev/loop-control ..."
    mknod /dev/loop-control c 10 237
fi
# Create /dev/loopN nodes if missing (major 7, minor = N)
for i in $(seq 0 63); do
    [[ -e "/dev/loop${i}" ]] || mknod "/dev/loop${i}" b 7 "$i"
done

LOOP_DEV="$(losetup --find --show --partscan "$IMG_FILE")"
cleanup_push "losetup -d ${LOOP_DEV}"
log_info "Loop device: ${LOOP_DEV}"

# ── format ESP (if enabled) ───────────────────────────────────────────────────
if [[ "$BOOT_PART_ENABLE" == "true" ]]; then
    ESP_DEV="${LOOP_DEV}p1"
    for i in $(seq 1 10); do [[ -b "$ESP_DEV" ]] && break; sleep 0.5; done
    [[ -b "$ESP_DEV" ]] || die "ESP device ${ESP_DEV} did not appear."
    log_info "Formatting ${ESP_DEV} as FAT16 (ESP) ..."
    mkfs.fat -F 16 -n "ESP" "$ESP_DEV"
fi

# Wait for rootfs partition device to appear
PART_DEV="${LOOP_DEV}p${ROOTFS_PART_NUM}"
for i in $(seq 1 10); do
    [[ -b "$PART_DEV" ]] && break
    sleep 0.5
done
[[ -b "$PART_DEV" ]] || die "Partition device ${PART_DEV} did not appear."

# ── format rootfs partition ──────────────────────────────────────────────────
log_info "Formatting ${PART_DEV} as ${ROOTFS_FSTYPE} ..."
mkfs.ext4 -L "$ROOTFS_LABEL" -q "$PART_DEV"

# ── get PARTUUID of the new partition ────────────────────────────────────────
# The kernel needs PARTUUID to find root without an initramfs (LABEL= requires
# userspace tools). We use sfdisk to extract the partition UUID from the GPT.
PART_UUID="$(sfdisk --part-uuid "$LOOP_DEV" "$ROOTFS_PART_NUM")"
log_info "Partition UUID: ${PART_UUID}"

# ── mount and copy rootfs ───────────────────────────────────────────────────
MNT="${TMP_DIR}/mnt"
ensure_dir "$MNT"
mount "$PART_DEV" "$MNT"
cleanup_push "umount -lf ${MNT}"

log_info "Copying rootfs into image (this may take a while) ..."
rsync -aHAX "${ROOTFS_DIR}/" "${MNT}/"

# ── generate extlinux.conf with PARTUUID ─────────────────────────────────────
log_info "Generating /boot/extlinux/extlinux.conf ..."
ensure_dir "${MNT}/boot/extlinux"
cat > "${MNT}/boot/extlinux/extlinux.conf" <<EOF
default linux-${KERNEL_VERSION}
label linux-${KERNEL_VERSION}
    kernel /boot/Image
    fdt /boot/${DTB_TARGETS[0]}
    append root=PARTUUID=${PART_UUID} rootfstype=${ROOTFS_FSTYPE} rootwait rw console=${SERIAL_TTY},${SERIAL_BAUD}n8 console=tty1
EOF

sync

# ── unmount ──────────────────────────────────────────────────────────────────
umount "$MNT"
# Remove from cleanup stack (already unmounted)
unset '_CLEANUP_STACK[-1]'

# ── write bootloader at raw offsets ──────────────────────────────────────────
if [[ "${WRITE_RAW_BOOTLOADER}" == "true" ]]; then
    if [[ -f "$IDBLOADER" ]]; then
        log_info "Writing idbloader.img at sector ${UBOOT_IDBLOADER_OFFSET} ..."
        dd if="$IDBLOADER" of="$LOOP_DEV" seek="${UBOOT_IDBLOADER_OFFSET}" conv=notrunc,fsync bs=512 status=none
    else
        log_warn "idbloader.img not found — skipping (image will not boot)."
    fi

    if [[ -f "$UBOOT_ITB" ]]; then
        log_info "Writing u-boot.itb at sector ${UBOOT_ITB_OFFSET} ..."
        dd if="$UBOOT_ITB" of="$LOOP_DEV" seek="${UBOOT_ITB_OFFSET}" conv=notrunc,fsync bs=512 status=none
    else
        log_warn "u-boot.itb not found — skipping (image will not boot)."
    fi
else
    log_info "Skipping raw bootloader writes (WRITE_RAW_BOOTLOADER=false)"
fi

# ── detach loop ──────────────────────────────────────────────────────────────
losetup -d "$LOOP_DEV"
# Remove from cleanup stack (already detached)
unset '_CLEANUP_STACK[-1]'

# ── compress + checksum ──────────────────────────────────────────────────────
log_info "Compressing image ..."
gzip -kf "$IMG_FILE"

log_info "Generating SHA-256 checksum ..."
(cd "$IMAGE_OUT" && sha256sum "${IMAGE_NAME}" "${IMAGE_NAME}.gz" > "${IMAGE_NAME}.sha256")

log_step "Image assembly complete:"
log_info "  ${IMG_FILE}"
log_info "  ${IMG_FILE}.gz"
log_info "  ${IMG_FILE}.sha256"
log_info ""
log_info "Write to SD card:  sudo dd if=${IMG_FILE} of=/dev/sdX bs=4M status=progress"
