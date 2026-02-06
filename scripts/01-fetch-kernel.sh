#!/usr/bin/env bash
# 01-fetch-kernel.sh — clone or update kernel source based on selected profile
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BOARD="${1:?usage: $0 <board>}"
load_config "$BOARD"

log_step "Fetching kernel source for ${BOARD_NAME} (profile: ${KERNEL_PROFILE:-default})"

# Ensure KERNEL_REPO and KERNEL_BRANCH are set (from profile or defaults)
if [[ -z "${KERNEL_REPO:-}" ]]; then
    log_info "KERNEL_REPO not set — assuming kernel source already present at ${KERNEL_SRC}"
    exit 0
fi

# ── clone or update kernel repo ──────────────────────────────────────────────
if [[ ! -d "${KERNEL_SRC}/.git" ]]; then
    log_info "Cloning kernel from ${KERNEL_REPO} (branch: ${KERNEL_BRANCH}) ..."
    git clone --depth=1 -b "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${KERNEL_SRC}"
else
    cd "${KERNEL_SRC}"

    # Check current remote and branch
    current_remote=$(git remote get-url origin 2>/dev/null || echo "")
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [[ "${current_remote}" != "${KERNEL_REPO}" ]]; then
        log_info "Switching kernel repo from ${current_remote} to ${KERNEL_REPO}"
        git remote set-url origin "${KERNEL_REPO}"
        git fetch --depth=1 origin "+refs/heads/${KERNEL_BRANCH}:refs/remotes/origin/${KERNEL_BRANCH}"
        git checkout -B "${KERNEL_BRANCH}" "origin/${KERNEL_BRANCH}"
    elif [[ "${current_branch}" != "${KERNEL_BRANCH}" ]]; then
        log_info "Switching kernel branch from ${current_branch} to ${KERNEL_BRANCH}"
        git fetch --depth=1 origin "+refs/heads/${KERNEL_BRANCH}:refs/remotes/origin/${KERNEL_BRANCH}"
        git checkout -B "${KERNEL_BRANCH}" "origin/${KERNEL_BRANCH}"
    else
        log_info "Kernel source already at correct repo/branch. Updating..."
        git fetch --depth=1 origin "+refs/heads/${KERNEL_BRANCH}:refs/remotes/origin/${KERNEL_BRANCH}"
        git reset --hard "origin/${KERNEL_BRANCH}"
    fi
fi

log_step "Kernel source ready at ${KERNEL_SRC}"
