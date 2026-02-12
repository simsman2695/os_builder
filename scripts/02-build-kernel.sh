#!/usr/bin/env bash
# 02-build-kernel.sh — cross-compile kernel Image, DTBs, and modules
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"

log_step "Building kernel for ${BOARD_NAME} (${KERNEL_VERSION})"

# ── build flags (LLVM=1 for Rust kernel builds, else GCC cross-compile) ─────
MAKE_FLAGS=(ARCH="${ARCH}")
if [[ "${KERNEL_LLVM:-}" == "1" ]]; then
    MAKE_FLAGS+=(LLVM=1)
else
    MAKE_FLAGS+=(CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}")
fi

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

# ── apply Tyr patches (Rust GPU driver + DRM infra) ─────────────────────────
if [[ "${USE_TYR:-false}" == "true" ]]; then
    TYR_PATCH_DIR="${BUILDER_DIR}/patches/kernel-tyr"
    if [[ -d "$TYR_PATCH_DIR" ]]; then
        tyr_applied=0
        tyr_skipped=0
        log_info "Applying Tyr patches from ${TYR_PATCH_DIR} ..."
        for patch in "$TYR_PATCH_DIR"/*.patch; do
            [[ -f "$patch" ]] || continue
            if git apply --check "$patch" 2>/dev/null; then
                git apply "$patch"
                tyr_applied=$((tyr_applied + 1))
            else
                tyr_skipped=$((tyr_skipped + 1))
            fi
        done
        log_info "Tyr patches: ${tyr_applied} applied, ${tyr_skipped} skipped (already applied or N/A)"
        [[ $tyr_applied -gt 0 ]] || die "No Tyr patches could be applied — kernel source may be incompatible"
    else
        die "Tyr patch directory not found: ${TYR_PATCH_DIR}"
    fi
fi

# ── defconfig ────────────────────────────────────────────────────────────────
log_info "Configuring: ${KERNEL_DEFCONFIG}"
make "${MAKE_FLAGS[@]}" "${KERNEL_DEFCONFIG}"

# ── merge config fragments (if any) ─────────────────────────────────────────
if [[ -v KERNEL_CONFIG_FRAGMENTS && ${#KERNEL_CONFIG_FRAGMENTS[@]} -gt 0 ]]; then
    log_info "Merging config fragments: ${KERNEL_CONFIG_FRAGMENTS[*]}"
    fragment_paths=()
    for frag in "${KERNEL_CONFIG_FRAGMENTS[@]}"; do
        fragment_paths+=("${BUILDER_DIR}/${frag}")
    done
    env "${MAKE_FLAGS[@]}" scripts/kconfig/merge_config.sh -m .config "${fragment_paths[@]}"
    make "${MAKE_FLAGS[@]}" olddefconfig
fi

# ── merge extra config (e.g., Panthor/Tyr for mainline) ──────────────────────
if [[ -n "${KERNEL_EXTRA_CONFIG:-}" ]]; then
    extra_config_path="${BUILDER_DIR}/${KERNEL_EXTRA_CONFIG}"
    if [[ -f "$extra_config_path" ]]; then
        log_info "Merging extra config: ${KERNEL_EXTRA_CONFIG}"
        env "${MAKE_FLAGS[@]}" scripts/kconfig/merge_config.sh -m .config "$extra_config_path"
        make "${MAKE_FLAGS[@]}" olddefconfig
    else
        log_warn "Extra config not found: ${extra_config_path}"
    fi
fi

# ── build Image ──────────────────────────────────────────────────────────────
log_info "Building Image (${MAKE_JOBS} jobs) ..."
make "${MAKE_FLAGS[@]}" -j"${MAKE_JOBS}" Image

# ── build DTBs ───────────────────────────────────────────────────────────────
log_info "Building DTBs ..."
make "${MAKE_FLAGS[@]}" -j"${MAKE_JOBS}" dtbs

# ── build modules ────────────────────────────────────────────────────────────
log_info "Building modules ..."
make "${MAKE_FLAGS[@]}" -j"${MAKE_JOBS}" modules

# ── install modules to output ────────────────────────────────────────────────
MODULES_STAGING="${KERNEL_OUT}/modules"
rm -rf "$MODULES_STAGING"
make "${MAKE_FLAGS[@]}" INSTALL_MOD_PATH="$MODULES_STAGING" modules_install

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
