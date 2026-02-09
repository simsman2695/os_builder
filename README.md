# RK3588 OS Builder

Automated build system for creating bootable Ubuntu images for RK3588-based boards. Currently supports the **Radxa Rock 5B**. Builds Ubuntu 24.04 by default; also supports 25.04.

Supports two kernel profiles with different GPU and NPU stacks:

| Profile | Kernel | GPU | NPU | Serial |
|---------|--------|-----|-----|--------|
| `6.1` (default) | Radxa vendor 6.1 | Mali blob (proprietary) | RKNPU2 (proprietary) | `ttyFIQ0` |
| `6.18` | Mainline 6.18 | Panthor + Mesa (open-source) | Rocket + Teflon (open-source) | `ttyS2` |
| `6.18` + `--tyr` | Panfrost `tyr-mini-demo` | Tyr (Rust) + Mesa (open-source) | Rocket + Teflon (open-source) | `ttyS2` |

## Prerequisites

### Host system

Ubuntu 22.04+ (x86_64) with the following packages:

```bash
sudo apt install gcc-12-aarch64-linux-gnu g++-12-aarch64-linux-gnu \
  device-tree-compiler bison flex bc libssl-dev \
  parted qemu-user-binfmt rsync wget curl git \
  python3 python3-pyelftools swig
```

> **Note:** On older Ubuntu (22.04), install `qemu-user-static` instead of `qemu-user-binfmt`. The build scripts accept either `qemu-aarch64-static` or `qemu-aarch64`.

For `--tyr` builds (Rust GPU driver), you also need the Rust/LLVM toolchain:

```bash
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup component add rust-src
cargo install bindgen-cli

# LLVM
sudo apt install clang lld llvm
```

## Quick start

Build with the default vendor kernel (6.1) and Ubuntu 24.04:

```bash
sudo ./build.sh rock-5b
```

Build with the mainline kernel (6.18, open-source GPU + NPU):

```bash
sudo KERNEL_PROFILE=6.18 ./build.sh rock-5b
```

Build with Ubuntu 25.04 (faster — no Mesa source build needed):

```bash
sudo UBUNTU_VERSION=25.04 KERNEL_PROFILE=6.18 ./build.sh rock-5b
```

Build with the experimental Tyr Rust GPU driver (requires `KERNEL_PROFILE=6.18`):

```bash
sudo KERNEL_PROFILE=6.18 ./build.sh --tyr rock-5b
```

Use prebuilt U-Boot instead of building from source:

```bash
sudo ./build.sh --prebuilt-uboot rock-5b
```

## Stages

The build is split into independent stages that can be run individually:

| Stage | Script | Sudo | Description |
|---|---|---|---|
| `prerequisites` | `00-check-prerequisites.sh` | No | Verify host tools, kernel source, disk space |
| `fetch-kernel` | `01-fetch-kernel.sh` | No | Clone or switch kernel source based on `KERNEL_PROFILE` |
| `fetch-dts` | `01-fetch-dts.sh` | No | Download Rock 5B DTS from Radxa's GitHub (if needed) |
| `kernel` | `02-build-kernel.sh` | No | Cross-compile Image, DTBs, and modules |
| `download-rootfs` | `03-download-rootfs.sh` | No | Download Ubuntu arm64 base tarball |
| `rootfs` | `04-customize-rootfs.sh` | **Yes** | Extract, qemu-chroot, install packages, GPU/NPU userspace, kernel |
| `uboot` | `05-build-uboot.sh` | No | Build U-Boot from source (or use prebuilt binaries) |
| `image` | `06-assemble-image.sh` | **Yes** | Assemble raw `.img` with GPT + bootloader + rootfs |

### Running specific stages

```bash
# Check that all host tools are installed
./build.sh rock-5b prerequisites

# Only fetch and build the kernel
./build.sh rock-5b fetch-kernel kernel

# Only customise the rootfs and assemble the image
sudo ./build.sh rock-5b rootfs image
```

Stages are run in the order you specify on the command line.

## Kernel profiles

Profiles live in `config/kernel-profiles/` and are selected by `KERNEL_PROFILE`:

### 6.1 (default) -- Vendor kernel

- Radxa's `linux-6.1-stan-rkr4.1` branch
- Mali G610 blob GPU (`libmali-valhall-g610.so`)
- RKNPU2 proprietary NPU runtime (`librknnrt.so`, `rknn_server`)
- Serial console on `ttyFIQ0` (Rockchip FIQ debugger)

### 6.18 -- Mainline kernel

- Radxa's `linux-6.18.2` branch
- Panthor open-source GPU driver (Mesa, kernel module)
- Rocket open-source NPU driver (`/dev/accel/accel0`, DRM accel subsystem)
- Mesa Teflon TFLite delegate (`libteflon.so`, built from Mesa 25.3.3 source)
- Panthor firmware (`mali_csffw.bin`) downloaded from linux-firmware
- Serial console on `ttyS2` (standard UART2)

The kernel config fragment `config/kernel/rk3588-panthor.config` enables Panthor GPU, Rocket NPU, RK3588 platform support, and display output for the mainline profile.

### 6.18 + --tyr -- Experimental Rust GPU driver

- Panfrost's `tyr-mini-demo` branch from `gitlab.freedesktop.org/panfrost/linux.git`
- Tyr Rust GPU driver (uses Panthor uAPI — same Mesa userspace and firmware)
- Built with `LLVM=1` (required for Rust kernel support)
- Kernel config fragment: `config/kernel/rk3588-tyr.config`
- Requires Rust/LLVM toolchain on the host (rustc, bindgen, clang, lld)
- **Experimental/prototype** — Tyr is under active development

## GPU and NPU stacks

### Vendor kernel (6.1)

```
GPU:  Application -> libmali.so (proprietary) -> Mali kernel driver -> Mali G610
NPU:  Application -> rknnlite2 -> librknnrt.so -> rknpu kernel module -> NPU (6 TOPS)
```

### Mainline kernel (6.18)

```
GPU:  Application -> Mesa (Panthor Gallium) -> panthor kernel driver -> Mali G610
NPU:  TFLite -> libteflon.so (Mesa delegate) -> Rocket kernel driver -> NPU (6 TOPS)
```

The Rocket NPU inference pipeline requires:
- Python 3.11 + `tflite-runtime` + `numpy<2` (installed from deadsnakes PPA, since PyPI wheels only cover up to Python 3.11)
- `libteflon.so` — on Ubuntu 24.04 this is built from Mesa 25.3.3 source; on 25.04+ it's installed directly from the repos (`libteflon1`)
- MobileNet V1 quantized `.tflite` model (downloaded during build)

## Hardware testing

The image includes a hardware validation suite at `/usr/local/bin/hw-test` that tests CPU, memory, GPU, storage, network, USB, audio, display, thermal, and NPU subsystems.

```bash
sudo hw-test --quick        # Detection only (seconds)
sudo hw-test --functional   # Detection + functional tests (minutes)
sudo hw-test --stress       # Full stress tests (10-30 minutes)
sudo hw-test --report       # Generate HTML report
```

A systemd service runs `hw-test --quick` automatically on first boot.

### NPU testing

The NPU test automatically detects which driver is active:

- **Rocket** (`/dev/accel/accel0`): Runs MobileNet V1 via TFLite + Teflon delegate (python3.11)
- **RKNPU** (`/dev/rknpu`): Runs MobileNet V1 via rknnlite2 + optional PP-OCR test

When Teflon is available, inference runs on the NPU hardware. Without it, TFLite falls back to CPU and the test reports which backend was used.

## Output

### Kernel artefacts

```
../kernels/<version>/rk3588/
├── Image
├── Image.gz
├── rk3588-rock-5b.dtb
├── config
└── modules/lib/modules/<version>/
```

### OS image

```
../os_images/<version>/rk3588/
├── rock-5b-cpedgeos-<ubuntu-ver>.img
├── rock-5b-cpedgeos-<ubuntu-ver>.img.gz
└── rock-5b-cpedgeos-<ubuntu-ver>.img.sha256
```

Where `<ubuntu-ver>` is `24.04` or `25.04` depending on `UBUNTU_VERSION`.

## Writing to SD card

```bash
sudo dd if=../os_images/<version>/rk3588/rock-5b-cpedgeos-24.04.img of=/dev/sdX bs=4M status=progress
sync
```

Replace `/dev/sdX` with your actual SD card device.

## Default credentials

| User | Password | Notes |
|---|---|---|
| `cpedge` | `cpedge` | Has passwordless sudo |

Change the password on first boot.

## Serial console

The serial console device depends on the kernel profile:

| Profile | Device | Baud rate | Notes |
|---------|--------|-----------|-------|
| 6.1 | `ttyFIQ0` | 1500000 | Rockchip FIQ debugger UART |
| 6.18 | `ttyS2` | 1500000 | Standard UART2 (mainline) |

Connect a USB-to-TTL adapter to the Rock 5B debug header:

```bash
screen /dev/ttyUSB0 1500000
```

## U-Boot

The `uboot` stage builds U-Boot from source using Radxa's fork and Rockchip's rkbin blobs (BL31 + DDR). On first run, it shallow-clones both repos into `../u-boot/` and `../rkbin/` automatically. Subsequent runs reuse the existing clones.

The build produces `idbloader.img` and `u-boot.itb`, which the `image` stage writes to the correct sector offsets.

Alternatively, you can skip the source build by either:

1. Using `--prebuilt-uboot` flag to download known-good binaries
2. Setting `UBOOT_IDBLOADER_URL` and `UBOOT_ITB_URL` in `config/boards/rock-5b.conf`
3. Placing `idbloader.img` and `u-boot.itb` manually in `tmp/rock-5b/`

## Configuration

### Config load order

1. `config/global.conf` -- paths, toolchain, Ubuntu version
2. `config/boards/rock-5b.conf` -- SoC, partition layout, bootloader, URLs
3. `config/kernel-profiles/<profile>.conf` -- kernel branch, GPU/NPU driver, serial console

Later files override earlier ones, so kernel profiles have final say on `SERIAL_TTY`, `GPU_DRIVER`, `NPU_DRIVER`, etc.

Environment variables `KERNEL_PROFILE` and `UBUNTU_VERSION` can be set before invoking `build.sh` to override the kernel profile and Ubuntu version respectively.

### Overlay files

Static files in `overlay/rock-5b/` are copied directly into the rootfs. The defaults provide:

- `/etc/hostname` -- `rock-5b`
- `/etc/fstab` -- mount rootfs by label
- `/etc/netplan/01-netcfg.yaml` -- DHCP on all Ethernet interfaces (`en*` wildcard)
- `/usr/local/bin/hw-test` -- hardware validation suite
- `/usr/local/bin/resize-rootfs` -- first-boot rootfs expansion
- Systemd services for first-boot hw-test and rootfs resize

## Adding a new board

1. Create `config/boards/<board>.conf` (use `rock-5b.conf` as a template)
2. Create `overlay/<board>/` with board-specific files
3. Run `./build.sh <board>`

## Directory structure

```
os_builder/
├── build.sh                          # Main entry point
├── config/
│   ├── global.conf                   # Paths, toolchain, Ubuntu version
│   ├── boards/
│   │   └── rock-5b.conf             # Board-specific settings
│   ├── kernel-profiles/
│   │   ├── 6.1.conf                 # Vendor kernel (Mali + RKNPU2)
│   │   └── 6.18.conf                # Mainline kernel (Panthor + Rocket)
│   └── kernel/
│       ├── rk3588-panthor.config    # Kernel config fragment (Panthor + Rocket)
│       └── rk3588-tyr.config        # Kernel config fragment (Tyr Rust GPU + Rocket)
├── scripts/
│   ├── lib/
│   │   └── common.sh                # Logging, error handling, config loader
│   ├── 00-check-prerequisites.sh
│   ├── 01-fetch-kernel.sh
│   ├── 01-fetch-dts.sh
│   ├── 02-build-kernel.sh
│   ├── 03-download-rootfs.sh
│   ├── 04-customize-rootfs.sh
│   ├── 05-build-uboot.sh
│   └── 06-assemble-image.sh
├── overlay/
│   └── rock-5b/                     # Static files merged into rootfs
│       ├── etc/                     # hostname, fstab, netplan, systemd units
│       └── usr/local/
│           ├── bin/hw-test          # Hardware validation suite
│           └── lib/hw-test/         # NPU inference test scripts + models
├── patches/
│   └── kernel/                      # Kernel patches (applied during build)
├── docs/                            # Build notes and research
└── logs/                            # Build logs (timestamped, gitignored)
```

## Logs

Every build run writes a timestamped log to `logs/build-YYYYMMDD-HHMMSS.log`. The log captures all terminal output from every stage with ANSI colour codes stripped.
