# Session Resume Prompt — Rock 5B OS Builder

Copy everything below the line into a new Claude Code session to resume.

---

## Context

I'm building a custom Ubuntu 24.04 ARM64 image for the Radxa Rock 5B (RK3588) using the os_builder project at `/home/matt/GitHub/cpedge/os_builder`. The board has a working Cachengo OS on NVMe (SSH: `cachengo@<board-ip>`) with a custom Mender U-Boot 2017.09 on SPI flash.

## What's been done

### 1. Kernel switched from 5.10 to 6.1 (COMPLETE)
- Backed up old kernel: `/home/matt/GitHub/cpedge/kernel-5.10-backup`
- Cloned Radxa 6.1 kernel: `git clone --depth 1 -b linux-6.1-stan-rkr4.1 https://github.com/radxa/kernel.git` at `/home/matt/GitHub/cpedge/kernel`
- Kernel version is **6.1.84**

### 2. Build system files modified (COMPLETE)
- **`config/boards/rock-5b.conf`** — `KERNEL_VERSION="auto"`, `DTS_BRANCH="linux-6.1-stan-rkr4.1"`, `DTS_FILES=()` (6.1 has Rock 5B DTS built-in), added `KERNEL_CONFIG_FRAGMENTS=("arch/arm64/configs/rk3588_linux.config")`
- **`scripts/01-fetch-dts.sh`** — Early exit when `DTS_FILES` is empty (skip stage cleanly)
- **`scripts/02-build-kernel.sh`** — After defconfig, merges `KERNEL_CONFIG_FRAGMENTS` using `scripts/kconfig/merge_config.sh` + `make olddefconfig`
- **`scripts/lib/common.sh`** — Auto-detect `KERNEL_VERSION="auto"` by reading VERSION/PATCHLEVEL/SUBLEVEL from kernel Makefile

### 3. Build completed successfully (COMPLETE)
- Full build ran: `./build.sh --prebuilt-uboot rock-5b`
- Image at: `/home/matt/GitHub/cpedge/os_images/6.1.84/rk3588/rock-5b-cpedgeos-24.04.img`
- Build log: `/home/matt/GitHub/cpedge/os_builder/logs/build-20260131-162157.log`
- Image verified: U-Boot binaries at correct sectors, kernel Image (valid ARM64), DTB, extlinux.conf, rootfs all correct

### 4. Boot failure diagnosed (COMPLETE)
The board doesn't boot from our SD card image. Root cause identified:

- **SPI flash has U-Boot 2017.09 with Mender OTA** (custom Cachengo firmware)
- The Mender U-Boot's `bootcmd` is hardcoded to run `mender_setup` and load kernel/DTB via Mender-specific variables — **it never reads extlinux.conf**
- `boot_targets=nvme mmc1 mmc0 ...` — NVMe first, so with NVMe present it always boots the Cachengo OS
- Without NVMe, the Mender boot script fails and U-Boot sits at a prompt (serial only, no HDMI) — hence "no heartbeat LED, no display"
- The SD card IS visible (`mmcblk0`) and all our files are correct — the problem is purely the SPI U-Boot ignoring extlinux

### 5. SPI flash script created (COMPLETE, NOT YET RUN)
- **`scripts/flash-spi-uboot.sh`** — provisioning script to run ON the Rock 5B board
- Replaces Mender U-Boot with inindev mainline U-Boot (2024.01-rc5) on SPI
- Layout: idbloader at SPI 0x8000 (mtd0 offset 0), u-boot.itb at SPI 0x40000 (mtd0 offset 0x38000) — confirmed from SPL string `jump to 0x40000`
- Also erases mtd4 (Mender env) and mtd6 (old Mender U-Boot)
- Prebuilt U-Boot binaries in: `/home/matt/GitHub/cpedge/os_builder/tmp/rock-5b/idbloader.img` and `u-boot.itb`

## What's next

1. **Flash SPI on the board** — scp idbloader.img, u-boot.itb, and flash-spi-uboot.sh to the Rock 5B, run it via SSH:
   ```bash
   scp /home/matt/GitHub/cpedge/os_builder/tmp/rock-5b/idbloader.img \
       /home/matt/GitHub/cpedge/os_builder/tmp/rock-5b/u-boot.itb \
       /home/matt/GitHub/cpedge/os_builder/scripts/flash-spi-uboot.sh \
       cachengo@<board-ip>:/tmp/
   ssh cachengo@<board-ip>
   sudo apt install mtd-utils
   sudo /tmp/flash-spi-uboot.sh
   ```

2. **Test SD card boot** — remove NVMe, insert SD card, reboot. Expect inindev U-Boot → extlinux.conf → kernel 6.1.84 → heartbeat LED + HDMI console

3. **Serial cable arriving today** — USB-UART adapter for UART2 debug console (1500000 baud). Useful if SPI flash or boot has issues.

4. **Recovery if SPI flash goes wrong** — Rockchip maskrom mode (hold maskrom button + USB) with rkdeveloptool

## Key files
- Board config: `config/boards/rock-5b.conf`
- Build entry: `build.sh`
- Scripts: `scripts/01-fetch-dts.sh`, `scripts/02-build-kernel.sh`, `scripts/04-customize-rootfs.sh`, `scripts/05-build-uboot.sh`, `scripts/06-assemble-image.sh`
- Common lib: `scripts/lib/common.sh`
- SPI flash script: `scripts/flash-spi-uboot.sh`
- SPI docs: `docs/spi-build.md`, `docs/rkbin-1.md`
- GPU future ref: `docs/Tyr - A Rust GPU driver for Arm Mali GPUs - CNX Software.pdf` (Tyr Rust driver for Mali G610, Linux 6.18+, not relevant yet)

## SPI flash details (current board state)
```
mtd0: 00378000 @ 0x8000  "idbloader"
mtd1: 00040000 @ 0x380000 "vnvm"
mtd2: 00030000 @ 0x3c0000 "reserved_space"
mtd3: 00008000 @ 0x3f0000 "reserved1"
mtd4: 00008000 @ 0x3f8000 "uboot_env"
mtd5: 00400000 @ 0x400000 "reserved2"
mtd6: 003fe000 @ 0x800000 "uboot"
mtd7: 003f0000 @ 0xbfe000 "uboot2"
```

NVMe system: `cachengo@B020111-794e7e2`, root on nvme0n1p2, /uboot on nvme0n1p1, /data on nvme0n1p4
