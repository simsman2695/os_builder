Building an image using the **rkbin** repository (Radxa's fork of Rockchip binary tools) typically involves using the pre-compiled binaries and helper scripts to package bootloader components like the SPL, DDR init, and Trust/ATF (Arm Trusted Firmware) into a format the Rockchip SoC can boot.

In most cases, you don't build an image using *only* `rkbin`. Instead, `rkbin` is a dependency used by a primary build system like U-Boot or a dedicated image creation script.

### 1. Identify Your Target Hardware

The `rkbin` repository is organized by SoC. You need to know your board's chip (e.g., RK3588, RK3568, RK3399). Files are generally located in the `bin/` directory and configuration files in `RKBOOT/`.

### 2. Common Usage: Integration with U-Boot

If you are compiling U-Boot for a Radxa board, you usually point the build environment to `rkbin` to include the proprietary DDR and Trust binaries.

* **Clone both:**
```bash
git clone https://github.com/radxa/u-boot.git
git clone https://github.com/radxa/rkbin.git

```


* **Set the path:** When building U-Boot, you often set an environment variable or pass a path so the build script can find the binaries:
```bash
export ROCKCHIP_TPL=../rkbin/bin/rk35/rk3588_ddr_lp4_2112MHz_v1.08.bin
export ROCKCHIP_BL31=../rkbin/bin/rk35/rk3588_bl31_v1.38.elf

```



### 3. Manual Image Creation (Using Tools)

If you want to manually pack a loader image (e.g., `idbloader.img`), you use the tools provided in the `tools/` directory (like `loaderimage` or `mkimage`).

* **Example for creating a bootloader image:**
The repository contains `.ini` files in the `RKBOOT/` folder that define which binaries should be packed together.
```bash
./tools/boot_merger RKBOOT/RK3588MINIALL.ini

```


This command reads the configuration and outputs a unified loader file (e.g., `rk3588_loader_v1.xx.bin`).

### 4. Key Components in rkbin

* **bin/**: Contains the actual binary blobs (DDR initialization, BL31/Trust, SPL).
* **tools/**: Contains Linux/Windows executables like `boot_merger`, `loaderimage`, and `mkkrnlimg` used to package these binaries.
* **RKBOOT/**: Contains `.ini` templates that describe how to combine the binaries for specific chips.

### Summary of Workflow

1. **Clone** the repo.
2. **Locate** the `.ini` file for your SoC in `RKBOOT/`.
3. **Use** the `tools/boot_merger` (or similar script in `scripts/`) to pack the binaries specified in that `.ini`.
