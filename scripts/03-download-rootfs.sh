#!/usr/bin/env bash
# 03-download-rootfs.sh — download Ubuntu arm64 base tarball
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"

log_step "Downloading Ubuntu ${UBUNTU_VERSION} arm64 rootfs"

ensure_dir "$TMP_DIR"

ROOTFS_TARBALL="${TMP_DIR}/ubuntu-base-${UBUNTU_VERSION}-arm64.tar.gz"

# Remove any existing file that isn't a valid gzip (e.g. empty/corrupt from a failed download)
if [[ -f "$ROOTFS_TARBALL" ]] && ! file "$ROOTFS_TARBALL" | grep -q gzip; then
    log_warn "Removing invalid tarball from previous run: ${ROOTFS_TARBALL}"
    rm -f "$ROOTFS_TARBALL"
fi

if [[ -f "$ROOTFS_TARBALL" ]]; then
    log_info "Rootfs tarball already downloaded: ${ROOTFS_TARBALL}"
else
    log_info "Downloading ${UBUNTU_ROOTFS_URL} ..."
    if ! wget -O "$ROOTFS_TARBALL" "$UBUNTU_ROOTFS_URL"; then
        rm -f "$ROOTFS_TARBALL"
        die "Failed to download rootfs tarball."
    fi
    log_info "Saved ${ROOTFS_TARBALL}"
fi

log_step "Rootfs download complete."
