#!/usr/bin/env bash
# 04-customize-rootfs.sh — extract, chroot, and configure the rootfs [sudo]
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"
require_sudo

log_step "Customizing rootfs for ${BOARD_NAME}"

ROOTFS_TARBALL="${TMP_DIR}/ubuntu-base-${UBUNTU_VERSION}-arm64.tar.gz"
ROOTFS_DIR="${TMP_DIR}/rootfs"

[[ -f "$ROOTFS_TARBALL" ]] || die "Rootfs tarball not found. Run 03-download-rootfs.sh first."

# ── clean up stale mounts / previous rootfs ──────────────────────────────────
# Always unmount any leftover bind-mounts from a previous interrupted run,
# even if the rootfs dir was only partially removed.
for mp in dev/pts proc sys; do
    mountpoint -q "${ROOTFS_DIR}/${mp}" 2>/dev/null && umount -lf "${ROOTFS_DIR}/${mp}" || true
done
if [[ -d "$ROOTFS_DIR" ]]; then
    log_info "Removing previous rootfs (${ROOTFS_DIR}) for clean build."
    rm -rf "$ROOTFS_DIR"
fi

ensure_dir "$ROOTFS_DIR"
log_info "Extracting rootfs tarball ..."
tar xpf "$ROOTFS_TARBALL" -C "$ROOTFS_DIR"

# ── set up qemu + mounts for chroot ─────────────────────────────────────────
if command -v qemu-aarch64-static &>/dev/null; then
    QEMU_BIN="$(command -v qemu-aarch64-static)"
elif command -v qemu-aarch64 &>/dev/null; then
    QEMU_BIN="$(command -v qemu-aarch64)"
else
    die "No qemu-aarch64 binary found. Install qemu-user-static or qemu-user-binfmt."
fi
QEMU_BASENAME="$(basename "$QEMU_BIN")"
cp "$QEMU_BIN" "${ROOTFS_DIR}/usr/bin/${QEMU_BASENAME}"

# Create minimal device nodes instead of bind-mounting host /dev.
# Bind-mounting /dev can fail inside qemu-user chroots due to AppArmor
# or namespace restrictions (e.g. /dev/null permission denied).
ensure_dir "${ROOTFS_DIR}/dev/pts"
ensure_dir "${ROOTFS_DIR}/dev/shm"
mknod -m 666 "${ROOTFS_DIR}/dev/null"    c 1 3 2>/dev/null || true
mknod -m 666 "${ROOTFS_DIR}/dev/zero"    c 1 5 2>/dev/null || true
mknod -m 666 "${ROOTFS_DIR}/dev/full"    c 1 7 2>/dev/null || true
mknod -m 666 "${ROOTFS_DIR}/dev/random"  c 1 8 2>/dev/null || true
mknod -m 666 "${ROOTFS_DIR}/dev/urandom" c 1 9 2>/dev/null || true
mknod -m 666 "${ROOTFS_DIR}/dev/tty"     c 5 0 2>/dev/null || true
mknod -m 600 "${ROOTFS_DIR}/dev/console" c 5 1 2>/dev/null || true
ln -sf /proc/self/fd   "${ROOTFS_DIR}/dev/fd"
ln -sf /proc/self/fd/0 "${ROOTFS_DIR}/dev/stdin"
ln -sf /proc/self/fd/1 "${ROOTFS_DIR}/dev/stdout"
ln -sf /proc/self/fd/2 "${ROOTFS_DIR}/dev/stderr"

mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
cleanup_push "umount -lf ${ROOTFS_DIR}/dev/pts"

mount -t proc proc "${ROOTFS_DIR}/proc"
cleanup_push "umount -lf ${ROOTFS_DIR}/proc"

mount -t sysfs sys "${ROOTFS_DIR}/sys"
cleanup_push "umount -lf ${ROOTFS_DIR}/sys"

# DNS resolution inside chroot
cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"

# ── chroot: install packages ────────────────────────────────────────────────
log_info "Installing packages inside chroot ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get dist-upgrade -y --no-install-recommends
apt-get install -y --no-install-recommends \
    systemd systemd-sysv udev kmod dbus \
    systemd-timesyncd \
    iproute2 iputils-ping net-tools \
    openssh-server sudo \
    netplan.io \
    wpasupplicant \
    cloud-guest-utils e2fsprogs \
    locales \
    vim-tiny less wget
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOTEOF

# ── chroot: install hardware test tools ──────────────────────────────────────
log_info "Installing hardware test tools (stress-ng, fio, i2c-tools, etc.) ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    stress-ng \
    fio \
    i2c-tools \
    pciutils \
    usbutils \
    lshw \
    hdparm \
    alsa-utils \
    iperf3 \
    ethtool \
    dmidecode \
    bc \
    python3 \
    python3-pip \
    python3-numpy \
    python3-pil \
    fonts-dejavu-core
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOTEOF

# ── chroot: create user ─────────────────────────────────────────────────────
log_info "Creating user cpedge ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
if ! id cpedge &>/dev/null; then
    useradd -m -s /bin/bash -G sudo cpedge
    echo "cpedge:cpedge" | chpasswd
fi
# Allow sudo without password (dev convenience — tighten for production)
echo "cpedge ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cpedge
chmod 0440 /etc/sudoers.d/cpedge
CHROOTEOF

# ── chroot: enable serial console ───────────────────────────────────────────
log_info "Enabling serial console on ${SERIAL_TTY} ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<CHROOTEOF
systemctl enable serial-getty@${SERIAL_TTY}.service 2>/dev/null || true
CHROOTEOF

# ── chroot: enable HDMI console ─────────────────────────────────────────────
log_info "Enabling HDMI console on tty1 ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<CHROOTEOF
systemctl enable getty@tty1.service 2>/dev/null || true
CHROOTEOF

# ── chroot: mask services that block boot without network ─────────────────
log_info "Masking systemd-networkd-wait-online (prevents infinite boot hang without DHCP) ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
CHROOTEOF

# ── install GPU userspace (based on GPU_DRIVER setting) ─────────────────────
if [[ "${GPU_DRIVER:-mali-blob}" == "panthor" ]]; then
    # Panthor: install Mesa from Ubuntu repos (24.04 has Mesa 24.0+ with Panthor support)
    log_info "Installing Mesa for Panthor GPU (open-source driver) ..."
    chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    mesa-vulkan-drivers \
    mesa-utils \
    libgl1-mesa-dri \
    libgles2 \
    libegl1
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOTEOF
else
    # Mali blob: download and install proprietary userspace
    log_info "Installing Mali GPU userspace (libmali-valhall-g610) ..."
    MALI_DL="${TMP_DIR}/libmali-valhall-g610.so"
    if [[ ! -f "$MALI_DL" ]]; then
        wget -q "${LIBMALI_URL}" -O "$MALI_DL"
    fi
    ensure_dir "${ROOTFS_DIR}/usr/lib/aarch64-linux-gnu"
    cp "$MALI_DL" "${ROOTFS_DIR}/usr/lib/aarch64-linux-gnu/libmali-valhall-g610.so"
    chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
cd /usr/lib/aarch64-linux-gnu
ln -sf libmali-valhall-g610.so libmali.so
ln -sf libmali.so libEGL.so.1
ln -sf libmali.so libGLESv2.so.2
ln -sf libmali.so libgbm.so.1
ln -sf libmali.so libOpenCL.so.1
ldconfig
CHROOTEOF
fi

# ── install RKNPU2 runtime (download on host, copy into rootfs) ─────────────
log_info "Installing RKNPU2 runtime (librknnrt) ..."
RKNPU2_DL="${TMP_DIR}/rknpu2.tar.gz"
if [[ ! -f "$RKNPU2_DL" ]]; then
    wget -q "${RKNPU2_URL}" -O "$RKNPU2_DL"
fi
RKNPU2_EXTRACT="${TMP_DIR}/rknpu2-extract"
rm -rf "$RKNPU2_EXTRACT"
mkdir -p "$RKNPU2_EXTRACT"
tar xf "$RKNPU2_DL" -C "$RKNPU2_EXTRACT"
cp "${RKNPU2_EXTRACT}/rknpu2-master/runtime/RK3588/Linux/librknn_api/aarch64/librknnrt.so" \
    "${ROOTFS_DIR}/usr/lib/"
cp "${RKNPU2_EXTRACT}/rknpu2-master/runtime/RK3588/Linux/rknn_server/aarch64/usr/bin/rknn_server" \
    "${ROOTFS_DIR}/usr/bin/"
cp "${RKNPU2_EXTRACT}/rknpu2-master/runtime/RK3588/Linux/rknn_server/aarch64/usr/bin/start_rknn.sh" \
    "${ROOTFS_DIR}/usr/bin/"
chmod +x "${ROOTFS_DIR}/usr/bin/rknn_server" "${ROOTFS_DIR}/usr/bin/start_rknn.sh"
chroot "$ROOTFS_DIR" ldconfig

# Copy MobileNet RKNN model for NPU inference test
MOBILENET_MODEL="${RKNPU2_EXTRACT}/rknpu2-master/examples/rknn_mobilenet_demo/model/RK3588/mobilenet_v1.rknn"
if [[ -f "$MOBILENET_MODEL" ]]; then
    log_info "Copying MobileNet RKNN model for NPU inference test ..."
    ensure_dir "${ROOTFS_DIR}/usr/local/lib/hw-test/models"
    cp "$MOBILENET_MODEL" "${ROOTFS_DIR}/usr/local/lib/hw-test/models/"
else
    log_info "MobileNet RKNN model not found in rknpu2 archive, skipping NPU inference test setup"
fi

rm -rf "$RKNPU2_EXTRACT"

# ── install rknnlite2 Python runtime ─────────────────────────────────────────
log_info "Installing rknn-toolkit-lite2 (Python RKNN runtime) ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
pip3 install --no-cache-dir --break-system-packages rknn-toolkit-lite2 2>/dev/null || \
    echo "WARNING: rknn-toolkit-lite2 install failed (inference test will be skipped)"
CHROOTEOF

# ── chroot: configure locale ────────────────────────────────────────────────
chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
CHROOTEOF

# ── install kernel artefacts ────────────────────────────────────────────────
log_info "Installing kernel Image + DTB + modules into rootfs ..."
ensure_dir "${ROOTFS_DIR}/boot"

[[ -f "${KERNEL_OUT}/Image" ]] || die "Kernel Image not found at ${KERNEL_OUT}/Image. Build kernel first."

cp "${KERNEL_OUT}/Image" "${ROOTFS_DIR}/boot/Image"

for dtb in "${DTB_TARGETS[@]}"; do
    if [[ -f "${KERNEL_OUT}/${dtb}" ]]; then
        cp "${KERNEL_OUT}/${dtb}" "${ROOTFS_DIR}/boot/${dtb}"
    fi
done

# Install modules
if [[ -d "${KERNEL_OUT}/modules/lib/modules" ]]; then
    rsync -a "${KERNEL_OUT}/modules/lib/modules/" "${ROOTFS_DIR}/lib/modules/"
fi

# ── extlinux.conf is generated in 06-assemble-image.sh ──────────────────────
# The PARTUUID isn't known until the GPT partition is created, so extlinux.conf
# must be generated during image assembly, not here.
ensure_dir "${ROOTFS_DIR}/boot/extlinux"

# ── apply overlay files ─────────────────────────────────────────────────────
OVERLAY_DIR="${BUILDER_DIR}/overlay/${BOARD}"
if [[ -d "$OVERLAY_DIR" ]]; then
    log_info "Applying overlay from ${OVERLAY_DIR} ..."
    rsync -a "${OVERLAY_DIR}/" "${ROOTFS_DIR}/"
fi

# ── fix SSH authorized_keys ownership/permissions ──────────────────────────
if [[ -d "${ROOTFS_DIR}/home/cpedge/.ssh" ]]; then
    log_info "Setting SSH authorized_keys permissions ..."
    chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
chown -R cpedge:cpedge /home/cpedge/.ssh
chmod 700 /home/cpedge/.ssh
chmod 600 /home/cpedge/.ssh/authorized_keys
CHROOTEOF
fi

# ── enable networking services and generate networkd configs ────────────────
log_info "Enabling systemd-networkd, systemd-resolved, timesyncd, and generating netplan config ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
systemctl enable systemd-networkd.service 2>/dev/null || true
systemctl enable systemd-resolved.service 2>/dev/null || true
systemctl enable systemd-timesyncd.service 2>/dev/null || true
netplan generate 2>/dev/null || true
CHROOTEOF

# ── enable rootfs resize service ───────────────────────────────────────────
if [[ -f "${ROOTFS_DIR}/usr/local/bin/resize-rootfs" ]]; then
    log_info "Enabling first-boot rootfs resize service ..."
    chmod +x "${ROOTFS_DIR}/usr/local/bin/resize-rootfs"
    chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
systemctl daemon-reload 2>/dev/null || true
systemctl enable resize-rootfs-firstboot.service 2>/dev/null || true
CHROOTEOF
fi

# ── enable hardware test service ────────────────────────────────────────────
if [[ -f "${ROOTFS_DIR}/usr/local/bin/hw-test" ]]; then
    log_info "Enabling hardware test first-boot service ..."
    chmod +x "${ROOTFS_DIR}/usr/local/bin/hw-test"
    chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
systemctl daemon-reload 2>/dev/null || true
systemctl enable hw-test-firstboot.service 2>/dev/null || true
CHROOTEOF
fi

# ── final cleanup inside rootfs ─────────────────────────────────────────────
rm -f "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static" "${ROOTFS_DIR}/usr/bin/qemu-aarch64"
# Write a static resolv.conf with systemd-resolved stub + public fallback.
# The symlink to /run/systemd/resolve/stub-resolv.conf breaks if resolved
# hasn't started yet, leaving DNS completely dead on first boot.
rm -f "${ROOTFS_DIR}/etc/resolv.conf"
cat > "${ROOTFS_DIR}/etc/resolv.conf" <<'DNSEOF'
nameserver 127.0.0.53
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0 trust-ad
DNSEOF

log_step "Rootfs customization complete → ${ROOTFS_DIR}"
