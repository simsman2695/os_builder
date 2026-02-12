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
    vim curl less wget
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

# ── chroot: install virtualization packages (QEMU, libvirt, LXC) ────────────
log_info "Installing virtualization packages (QEMU, libvirt, LXC) ..."
chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    qemu-system-arm \
    qemu-utils \
    qemu-efi-aarch64 \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    lxc \
    lxc-utils \
    busybox-static \
    nftables \
    iptables \
    dnsmasq-base \
    bridge-utils
apt-get clean
rm -rf /var/lib/apt/lists/*
systemctl enable lxc-net.service 2>/dev/null || true
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

# ── add Oibaf PPA for Mesa 25.3+ (Rocket NPU needs Teflon userspace) ─────────
# On 24.04 the stock Mesa is too old, so add the Oibaf PPA before GPU install.
# On 25.04+ Mesa 25.3+ is in the repos so the PPA is not needed.
if [[ "${NPU_DRIVER:-}" == "rocket" && "${UBUNTU_VERSION}" == "24.04" ]]; then
    log_info "Adding Oibaf PPA for Mesa 25.3+ (Teflon/Rocket userspace) ..."
    chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends software-properties-common
add-apt-repository -y ppa:oibaf/graphics-drivers
apt-get update
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOTEOF
fi

# ── install GPU userspace (based on GPU_DRIVER setting) ─────────────────────
if [[ "${GPU_DRIVER:-mali-blob}" == "panthor" || "${GPU_DRIVER:-}" == "tyr" ]]; then
    # Panthor: install Mesa (Oibaf PPA provides 25.3+ when rocket, else Ubuntu stock)
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

    # Panthor requires Mali CSF firmware (mali_csffw.bin) — not included in
    # Ubuntu base rootfs. Download from the linux-firmware repo.
    log_info "Installing Panthor GPU firmware (mali_csffw.bin) ..."
    PANTHOR_FW_DIR="${ROOTFS_DIR}/lib/firmware/arm/mali/arch10.8"
    ensure_dir "$PANTHOR_FW_DIR"
    if [[ ! -f "${PANTHOR_FW_DIR}/mali_csffw.bin" ]]; then
        wget -q "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/arm/mali/arch10.8/mali_csffw.bin" \
            -O "${PANTHOR_FW_DIR}/mali_csffw.bin"
    fi
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

# ── install NPU runtime (based on NPU_DRIVER setting) ───────────────────────
if [[ "${NPU_DRIVER:-rknpu}" == "rknpu" ]]; then
    # RKNPU2: download proprietary runtime, copy into rootfs
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

    # Install rknnlite2 Python runtime
    log_info "Installing rknn-toolkit-lite2 (Python RKNN runtime) ..."
    chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
pip3 install --no-cache-dir --break-system-packages rknn-toolkit-lite2 2>/dev/null || \
    echo "WARNING: rknn-toolkit-lite2 install failed (inference test will be skipped)"
CHROOTEOF

elif [[ "${NPU_DRIVER:-}" == "rocket" ]]; then
    # Rocket: Mesa Teflon provides the TFLite external delegate (libteflon.so)
    # that routes inference to the NPU via the Rocket kernel driver.
    # tflite-runtime only has aarch64 wheels up to Python 3.11, so we install
    # Python 3.11 from deadsnakes alongside the system 3.12.
    log_info "Installing Python 3.11 + TFLite runtime for Rocket NPU ..."
    chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends software-properties-common
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update
apt-get install -y --no-install-recommends python3.11 python3.11-venv python3.11-dev
apt-get clean
rm -rf /var/lib/apt/lists/*

python3.11 -m ensurepip --upgrade 2>/dev/null || \
    curl -sSf https://bootstrap.pypa.io/get-pip.py | python3.11 - --ignore-installed
python3.11 -m pip install --no-cache-dir --ignore-installed "numpy<2" || true
python3.11 -m pip install --no-cache-dir tflite-runtime || \
    echo "WARNING: tflite-runtime install failed (inference test will be skipped)"
CHROOTEOF

    log_info "Downloading MobileNet V1 quantized TFLite model ..."
    ensure_dir "${ROOTFS_DIR}/usr/local/lib/hw-test/models"
    TFLITE_MODEL="${ROOTFS_DIR}/usr/local/lib/hw-test/models/mobilenet_v1_1.0_224_quant.tflite"
    if [[ ! -f "$TFLITE_MODEL" ]]; then
        wget -q "https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224_quant.tgz" \
            -O "${TMP_DIR}/mobilenet_v1_quant.tgz"
        tar xf "${TMP_DIR}/mobilenet_v1_quant.tgz" -C "${TMP_DIR}/"
        cp "${TMP_DIR}/mobilenet_v1_1.0_224_quant.tflite" "$TFLITE_MODEL"
        rm -f "${TMP_DIR}/mobilenet_v1_quant.tgz"
    fi

    # Install Mesa Teflon delegate (libteflon.so) for Rocket NPU inference.
    # Ubuntu 25.04+ ships Mesa 25.3+ in the repos (includes libteflon).
    # Ubuntu 24.04 needs a source build since even the Oibaf PPA only has 25.2.
    if [[ "${UBUNTU_VERSION}" == "24.04" ]]; then
        log_info "Building Mesa Teflon delegate (libteflon.so) from source (24.04) ..."
        MESA_VERSION="25.3.3"
        MESA_TARBALL="${TMP_DIR}/mesa-${MESA_VERSION}.tar.xz"
        if [[ ! -f "$MESA_TARBALL" ]]; then
            wget -q "https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz" \
                -O "$MESA_TARBALL"
        fi

        # Install build dependencies inside chroot
        # Note: Ubuntu 24.04 ships meson 1.3.2 but Mesa 25.3 requires >= 1.4.0,
        # so we install meson via pip3 instead of the apt package.
        chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    gcc g++ ninja-build pkg-config python3-pip python3-packaging \
    python3-setuptools \
    python3-mako python3-yaml python3-ply \
    flex bison \
    libdrm-dev libexpat1-dev libelf-dev zlib1g-dev
pip3 install --break-system-packages meson>=1.4.0
CHROOTEOF

        # Extract, configure, build (only the teflon target)
        ensure_dir "${ROOTFS_DIR}/tmp/mesa-build"
        tar xf "$MESA_TARBALL" -C "${ROOTFS_DIR}/tmp/mesa-build/" --strip-components=1

        chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
# Override cross-compiler env vars inherited from host — inside the
# qemu-user chroot we are already aarch64 so use native gcc.
unset CROSS_COMPILE
export CC=gcc
export CXX=g++

cd /tmp/mesa-build
meson setup build \
    -Dgallium-drivers=rocket \
    -Dvulkan-drivers= \
    -Dteflon=true \
    -Dglx=disabled \
    -Degl=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dplatforms= \
    -Dllvm=disabled \
    -Dbuildtype=release \
    -Dprefix=/usr

ninja -C build src/gallium/targets/teflon/libteflon.so

# Install just the teflon delegate library
install -m 755 build/src/gallium/targets/teflon/libteflon.so /usr/lib/aarch64-linux-gnu/
CHROOTEOF

        # Clean up build tree and build-only deps
        rm -rf "${ROOTFS_DIR}/tmp/mesa-build"
        chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
pip3 uninstall -y --break-system-packages meson
apt-get remove -y gcc g++ ninja-build pkg-config python3-pip flex bison \
    python3-setuptools \
    python3-mako python3-ply \
    libexpat1-dev libelf-dev zlib1g-dev
# Note: python3-yaml is deliberately kept — netplan.io depends on it
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOTEOF
    else
        # Ubuntu 25.04+: Mesa 25.3+ is in the repos, install libteflon directly
        log_info "Installing Mesa Teflon delegate from repos (${UBUNTU_VERSION}) ..."
        chroot "$ROOTFS_DIR" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends libteflon1
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOTEOF
    fi
fi

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

# ── generate version-correct branding ────────────────────────────────────────
# The overlay ships static 24.04 branding; overwrite with the actual version.
log_info "Writing os-release and issue for cpedgeOS ${UBUNTU_VERSION} ..."
cat > "${ROOTFS_DIR}/etc/os-release" <<EOF
NAME="cpedgeOS"
PRETTY_NAME="cpedgeOS ${UBUNTU_VERSION}"
VERSION_ID="${UBUNTU_VERSION}"
VERSION="${UBUNTU_VERSION}"
ID=cpedgeos
ID_LIKE=ubuntu
HOME_URL="https://github.com/cpedge"
EOF

echo "cpedgeOS ${UBUNTU_VERSION} \\n \\l" > "${ROOTFS_DIR}/etc/issue"

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
