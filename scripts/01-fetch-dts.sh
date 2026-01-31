#!/usr/bin/env bash
# 01-fetch-dts.sh — download Rock 5B DTS from Radxa's kernel fork
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"

log_step "Fetching DTS for ${BOARD_NAME}"

DTS_DIR="${KERNEL_SRC}/arch/arm64/boot/dts/rockchip"
ensure_dir "$DTS_DIR"

# ── download each DTS file via GitHub raw URL ────────────────────────────────
RAW_BASE="https://raw.githubusercontent.com/radxa/kernel/${DTS_BRANCH}"

for dts_path in "${DTS_FILES[@]}"; do
    filename="$(basename "$dts_path")"
    dest="${KERNEL_SRC}/${dts_path}"
    url="${RAW_BASE}/${dts_path}"

    if [[ -f "$dest" ]]; then
        log_info "DTS already exists: ${dest} (skipping download)"
        continue
    fi

    log_info "Downloading ${filename} ..."
    if ! wget -q -O "$dest" "$url"; then
        die "Failed to download ${url}"
    fi
    log_info "Saved ${dest}"
done

# ── also fetch common includes the DTS may reference ────────────────────────
# The BSP tree should already have the rk3588.dtsi; check and warn if missing.
for inc in rk3588.dtsi rk3588s.dtsi; do
    if [[ ! -f "${DTS_DIR}/${inc}" ]]; then
        log_warn "Expected include ${DTS_DIR}/${inc} not found — kernel BSP may be incomplete."
    fi
done

# ── patch the rockchip DTS Makefile to build our DTB ─────────────────────────
DTS_MAKEFILE="${DTS_DIR}/Makefile"
if [[ -f "$DTS_MAKEFILE" ]]; then
    for dtb in "${DTB_TARGETS[@]}"; do
        if ! grep -q "$dtb" "$DTS_MAKEFILE"; then
            log_info "Adding ${dtb} to ${DTS_MAKEFILE}"
            echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += ${dtb}" >> "$DTS_MAKEFILE"
        else
            log_info "${dtb} already in DTS Makefile."
        fi
    done
else
    log_warn "DTS Makefile not found at ${DTS_MAKEFILE} — DTB may need manual build."
fi

log_step "DTS fetch complete."
