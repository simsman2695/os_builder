# RK3588 OS Builder

Automated build system for creating bootable Ubuntu 24.04 images for RK3588-based boards. Currently supports the **Radxa Rock 5B**.

The pipeline fetches the board device-tree from Radxa's kernel fork, cross-compiles the Rockchip BSP kernel (5.10.226), downloads and customises an Ubuntu 24.04 arm64 rootfs, and assembles a raw `dd`-able `.img` for SD card or eMMC.

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

### Kernel source

The Rockchip BSP kernel must be checked out alongside this repo:

```
cpedge/
├── kernel/          # Rockchip BSP 5.10.226 source tree
├── os_builder/      # This repo
├── u-boot/          # U-Boot source (cloned automatically on first build)
├── rkbin/           # Rockchip BL31 + DDR blobs (cloned automatically)
├── kernels/         # Kernel build output (created automatically)
└── os_images/       # Image output (created automatically)
```

Clone the kernel if you haven't already:

```bash
cd /path/to/cpedge
git clone https://github.com/radxa/kernel.git -b stable-5.10-rock5
```

## Quick start

Build everything for the Rock 5B:

```bash
./build.sh rock-5b
```

The `rootfs` and `image` stages require root privileges. If running all stages:

```bash
sudo ./build.sh rock-5b
```

## Stages

The build is split into independent stages that can be run individually:

| Stage | Script | Sudo | Description |
|---|---|---|---|
| `prerequisites` | `00-check-prerequisites.sh` | No | Verify host tools, kernel source, disk space |
| `fetch-dts` | `01-fetch-dts.sh` | No | Download Rock 5B DTS from Radxa's GitHub |
| `kernel` | `02-build-kernel.sh` | No | Cross-compile Image, DTBs, and modules |
| `download-rootfs` | `03-download-rootfs.sh` | No | Download Ubuntu 24.04 arm64 base tarball |
| `rootfs` | `04-customize-rootfs.sh` | **Yes** | Extract, qemu-chroot, install packages and kernel |
| `uboot` | `05-build-uboot.sh` | No | Build U-Boot from source (or use prebuilt binaries) |
| `image` | `06-assemble-image.sh` | **Yes** | Assemble raw `.img` with GPT + bootloader + rootfs |

### Running specific stages

```bash
# Check that all host tools are installed
./build.sh rock-5b prerequisites

# Only fetch DTS and build the kernel
./build.sh rock-5b fetch-dts kernel

# Only download and customise the rootfs, then assemble the image
sudo ./build.sh rock-5b rootfs image
```

Stages are run in the order you specify on the command line.

## Output

### Kernel artefacts

```
../kernels/5.10.226/rk3588/
├── Image
├── Image.gz
├── rk3588-rock-5b.dtb
├── config
└── modules/lib/modules/5.10.226/
```

### OS image

```
../os_images/5.10.226/rk3588/
├── rock-5b-ubuntu-24.04.img
├── rock-5b-ubuntu-24.04.img.gz
└── rock-5b-ubuntu-24.04.img.sha256
```

## Writing to SD card

```bash
sudo dd if=../os_images/5.10.226/rk3588/rock-5b-ubuntu-24.04.img of=/dev/sdX bs=4M status=progress
sync
```

Replace `/dev/sdX` with your actual SD card device.

## Default credentials

| User | Password | Notes |
|---|---|---|
| `cpedge` | `cpedge` | Has passwordless sudo |

Change the password on first boot.

## Serial console

The image is configured for serial output on the Rockchip debug UART (`ttyFIQ0` at 1500000 baud). Connect a USB-to-TTL adapter to the Rock 5B debug header and use:

```bash
screen /dev/ttyUSB0 1500000
```

## U-Boot

The `uboot` stage builds U-Boot from source using Radxa's fork and Rockchip's rkbin blobs (BL31 + DDR). On first run, it shallow-clones both repos into `../u-boot/` and `../rkbin/` automatically. Subsequent runs reuse the existing clones.

The build produces `idbloader.img` and `u-boot.itb`, which the `image` stage writes to the correct sector offsets.

Alternatively, you can skip the source build by either:

1. Setting `UBOOT_IDBLOADER_URL` and `UBOOT_ITB_URL` in `config/boards/rock-5b.conf` to download prebuilt binaries
2. Placing `idbloader.img` and `u-boot.itb` manually in `tmp/rock-5b/`

## Logs

Every build run writes a timestamped log to `logs/build-YYYYMMDD-HHMMSS.log`. The log captures all terminal output from every stage with ANSI colour codes stripped for readability.

## Configuration

### Global settings

`config/global.conf` — kernel source path, output directories, cross-compiler, Ubuntu version.

### Board settings

`config/boards/rock-5b.conf` — SoC, defconfig, DTS source, partition layout, serial console.

### Overlay files

Static files in `overlay/rock-5b/` are copied directly into the rootfs. The defaults set:

- `/etc/hostname` — `rock-5b`
- `/etc/fstab` — mount rootfs by label
- `/etc/netplan/01-netcfg.yaml` — DHCP on both ethernet ports

## Adding a new board

1. Create `config/boards/<board>.conf` (use `rock-5b.conf` as a template)
2. Create `overlay/<board>/` with board-specific files
3. Run `./build.sh <board>`

## Directory structure

```
os_builder/
├── build.sh                  # Main entry point
├── config/
│   ├── global.conf           # Paths, toolchain, Ubuntu version
│   └── boards/
│       └── rock-5b.conf      # Board-specific settings
├── scripts/
│   ├── lib/
│   │   └── common.sh         # Logging, error handling, cleanup, config loader
│   ├── 00-check-prerequisites.sh
│   ├── 01-fetch-dts.sh
│   ├── 02-build-kernel.sh
│   ├── 03-download-rootfs.sh
│   ├── 04-customize-rootfs.sh
│   ├── 05-build-uboot.sh
│   └── 06-assemble-image.sh
├── overlay/
│   └── rock-5b/              # Static files merged into rootfs
├── patches/
│   └── kernel/               # Kernel patches (empty initially)
└── logs/                     # Build logs (gitignored)
```
