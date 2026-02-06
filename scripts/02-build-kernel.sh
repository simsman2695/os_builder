#!/usr/bin/env bash
# 02-build-kernel.sh — cross-compile kernel Image, DTBs, and modules
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"

log_step "Building kernel for ${BOARD_NAME} (${KERNEL_VERSION})"

ensure_dir "$KERNEL_OUT"

cd "$KERNEL_SRC"

# ── apply patches ────────────────────────────────────────────────────────────
PATCH_DIR="${BUILDER_DIR}/patches/kernel"
if [[ -d "$PATCH_DIR" ]]; then
    for patch in "$PATCH_DIR"/*.patch; do
        [[ -f "$patch" ]] || continue
        if git apply --check "$patch" 2>/dev/null; then
            log_info "Applying patch: $(basename "$patch")"
            git apply "$patch"
        else
            log_info "Patch already applied or N/A: $(basename "$patch")"
        fi
    done
fi

# ── defconfig ────────────────────────────────────────────────────────────────
log_info "Configuring: ${KERNEL_DEFCONFIG}"
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" \
    "${KERNEL_DEFCONFIG}"

# ── merge config fragments (if any) ─────────────────────────────────────────
if [[ -v KERNEL_CONFIG_FRAGMENTS && ${#KERNEL_CONFIG_FRAGMENTS[@]} -gt 0 ]]; then
    log_info "Merging config fragments: ${KERNEL_CONFIG_FRAGMENTS[*]}"
    ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" \
        scripts/kconfig/merge_config.sh -m .config "${KERNEL_CONFIG_FRAGMENTS[@]}"
    make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" olddefconfig
fi

# ── merge extra config (e.g., Panthor for mainline) ─────────────────────────
if [[ -n "${KERNEL_EXTRA_CONFIG:-}" ]]; then
    extra_config_path="${BUILDER_DIR}/${KERNEL_EXTRA_CONFIG}"
    if [[ -f "$extra_config_path" ]]; then
        log_info "Merging extra config: ${KERNEL_EXTRA_CONFIG}"
        ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" \
            scripts/kconfig/merge_config.sh -m .config "$extra_config_path"
        make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" olddefconfig
    else
        log_warn "Extra config not found: ${extra_config_path}"
    fi
fi

# ── build Image ──────────────────────────────────────────────────────────────
log_info "Building Image (${MAKE_JOBS} jobs) ..."
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" \
    -j"${MAKE_JOBS}" Image

# ── build DTBs ───────────────────────────────────────────────────────────────
log_info "Building DTBs ..."
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" \
    -j"${MAKE_JOBS}" dtbs

# ── build modules ────────────────────────────────────────────────────────────
log_info "Building modules ..."
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" \
    -j"${MAKE_JOBS}" modules

# ── install modules to output ────────────────────────────────────────────────
MODULES_STAGING="${KERNEL_OUT}/modules"
rm -rf "$MODULES_STAGING"
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" \
    INSTALL_MOD_PATH="$MODULES_STAGING" modules_install

# ── copy artefacts ───────────────────────────────────────────────────────────
log_info "Copying kernel artefacts to ${KERNEL_OUT}"
cp arch/arm64/boot/Image "${KERNEL_OUT}/Image"
gzip -kf "${KERNEL_OUT}/Image"  # also produce Image.gz

for dtb in "${DTB_TARGETS[@]}"; do
    dtb_path="arch/arm64/boot/dts/rockchip/${dtb}"
    if [[ -f "$dtb_path" ]]; then
        cp "$dtb_path" "${KERNEL_OUT}/${dtb}"
        log_info "Copied ${dtb}"
    else
        log_warn "DTB not found: ${dtb_path}"
    fi
done

cp .config "${KERNEL_OUT}/config"

log_step "Kernel build complete → ${KERNEL_OUT}"
