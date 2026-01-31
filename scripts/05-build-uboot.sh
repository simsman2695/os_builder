#!/usr/bin/env bash
# 05-build-uboot.sh — build U-Boot from source or fetch prebuilt binaries
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"

log_step "U-Boot stage for ${BOARD_NAME}"

ensure_dir "$TMP_DIR"

IDBLOADER="${TMP_DIR}/idbloader.img"
UBOOT_ITB="${TMP_DIR}/u-boot.itb"

# ── option 1: download prebuilt binaries ─────────────────────────────────────
if [[ -n "${UBOOT_IDBLOADER_URL:-}" && -n "${UBOOT_ITB_URL:-}" ]]; then
    if [[ ! -f "$IDBLOADER" ]]; then
        log_info "Downloading idbloader.img ..."
        wget -q -O "$IDBLOADER" "$UBOOT_IDBLOADER_URL" \
            || die "Failed to download idbloader.img"
    fi
    if [[ ! -f "$UBOOT_ITB" ]]; then
        log_info "Downloading u-boot.itb ..."
        wget -q -O "$UBOOT_ITB" "$UBOOT_ITB_URL" \
            || die "Failed to download u-boot.itb"
    fi
    log_info "U-Boot binaries ready (prebuilt)."
    log_step "U-Boot stage complete."
    exit 0
fi

# ── option 2: manually placed binaries ───────────────────────────────────────
if [[ -f "$IDBLOADER" && -f "$UBOOT_ITB" ]]; then
    log_info "Found manually placed U-Boot binaries in ${TMP_DIR} — will use those."
    log_step "U-Boot stage complete."
    exit 0
fi

# ── option 3: build from source ──────────────────────────────────────────────
if [[ -z "${UBOOT_REPO:-}" ]]; then
    log_warn "No U-Boot binary URLs or repo configured in ${BOARD}.conf."
    log_warn "The assembled image will NOT be bootable without U-Boot."
    log_info ""
    log_info "To provide U-Boot binaries, either:"
    log_info "  1. Set UBOOT_IDBLOADER_URL and UBOOT_ITB_URL in config/boards/${BOARD}.conf"
    log_info "  2. Manually place idbloader.img and u-boot.itb in ${TMP_DIR}/"
    log_info "  3. Set UBOOT_REPO and UBOOT_DEFCONFIG to build from source"
    log_step "U-Boot stage complete (no binaries)."
    exit 0
fi

require_cmd make python3 swig "${CC}"

# ── clone repos if missing ───────────────────────────────────────────────────
if [[ ! -d "${UBOOT_SRC}/.git" ]]; then
    log_info "Cloning U-Boot repo into ${UBOOT_SRC} ..."
    git clone --depth 1 -b "${UBOOT_BRANCH}" "${UBOOT_REPO}" "${UBOOT_SRC}" \
        || die "Failed to clone U-Boot repo"
else
    log_info "U-Boot source already present at ${UBOOT_SRC}"
fi

if [[ ! -d "${RKBIN_SRC}/.git" ]]; then
    log_info "Cloning rkbin repo into ${RKBIN_SRC} ..."
    git clone --depth 1 "${RKBIN_REPO}" "${RKBIN_SRC}" \
        || die "Failed to clone rkbin repo"
else
    log_info "rkbin already present at ${RKBIN_SRC}"
fi

# ── resolve BL31 and TPL paths (glob for latest version, fall back to config)
RKBIN_SRC_ABS="$(realpath "${RKBIN_SRC}")"

bl31_file=""
bl31_glob=$(ls "${RKBIN_SRC_ABS}"/bin/rk35/rk3588_bl31_v*.elf 2>/dev/null | sort -V | tail -1) || true
if [[ -n "$bl31_glob" ]]; then
    bl31_file="$bl31_glob"
    log_info "BL31: ${bl31_file}"
elif [[ -f "${RKBIN_SRC_ABS}/${RKBIN_BL31}" ]]; then
    bl31_file="${RKBIN_SRC_ABS}/${RKBIN_BL31}"
    log_info "BL31 (config fallback): ${bl31_file}"
else
    die "Cannot find BL31 ELF in rkbin. Expected pattern: bin/rk35/rk3588_bl31_v*.elf"
fi

tpl_file=""
tpl_glob=$(ls "${RKBIN_SRC_ABS}"/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_*_v*.bin 2>/dev/null | sort -V | tail -1) || true
if [[ -n "$tpl_glob" ]]; then
    tpl_file="$tpl_glob"
    log_info "TPL: ${tpl_file}"
elif [[ -f "${RKBIN_SRC_ABS}/${RKBIN_TPL}" ]]; then
    tpl_file="${RKBIN_SRC_ABS}/${RKBIN_TPL}"
    log_info "TPL (config fallback): ${tpl_file}"
else
    die "Cannot find DDR TPL blob in rkbin. Expected pattern: bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_*_v*.bin"
fi

# ── build U-Boot ─────────────────────────────────────────────────────────────
log_info "Building U-Boot (defconfig: ${UBOOT_DEFCONFIG}) ..."

export BL31="${bl31_file}"
export ROCKCHIP_TPL="${tpl_file}"

# Radxa's U-Boot branch predates GCC 12; suppress warnings promoted to errors.
UBOOT_KCFLAGS="-Wno-error=enum-int-mismatch -Wno-error=dangling-pointer="

make -C "${UBOOT_SRC}" CROSS_COMPILE="${CROSS_COMPILE}" "${UBOOT_DEFCONFIG}" \
    || die "U-Boot defconfig failed"

make -C "${UBOOT_SRC}" CROSS_COMPILE="${CROSS_COMPILE}" KCFLAGS="${UBOOT_KCFLAGS}" -j"${MAKE_JOBS}" \
    || die "U-Boot build failed"

# Build u-boot.itb (FIT image with ATF) — not always produced by the default target
if [[ ! -f "${UBOOT_SRC}/u-boot.itb" ]]; then
    log_info "Building u-boot.itb ..."
    make -C "${UBOOT_SRC}" CROSS_COMPILE="${CROSS_COMPILE}" KCFLAGS="${UBOOT_KCFLAGS}" \
        -j"${MAKE_JOBS}" u-boot.itb \
        || die "u-boot.itb build failed"
fi

# ── assemble idbloader.img (TPL + SPL) if the build didn't produce one ──────
if [[ ! -f "${UBOOT_SRC}/idbloader.img" ]]; then
    log_info "Assembling idbloader.img from TPL + SPL ..."
    "${UBOOT_SRC}/tools/mkimage" -n rk3588 -T rksd \
        -d "${tpl_file}:${UBOOT_SRC}/spl/u-boot-spl.bin" \
        "${UBOOT_SRC}/idbloader.img" \
        || die "Failed to assemble idbloader.img"
fi

# ── copy outputs ─────────────────────────────────────────────────────────────
[[ -f "${UBOOT_SRC}/idbloader.img" ]] || die "Build did not produce idbloader.img"
[[ -f "${UBOOT_SRC}/u-boot.itb" ]]    || die "Build did not produce u-boot.itb"

cp "${UBOOT_SRC}/idbloader.img" "${IDBLOADER}"
cp "${UBOOT_SRC}/u-boot.itb"    "${UBOOT_ITB}"

log_info "idbloader.img → ${IDBLOADER}"
log_info "u-boot.itb    → ${UBOOT_ITB}"

log_step "U-Boot stage complete."
