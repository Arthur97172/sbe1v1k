# 25.12-6.12 — Spectrum SBE1V1K 固件构建输入

OpenWrt 25.12（`openwrt-25.12`）+ 主线 Linux 6.12，目标板 `spectrum_sbe1v1k`
（IPQ9574）。**Stage 1**：可编译基线，使用上游 `qualcommbe/ipq95xx`
（设备树 `ipq9574-rdp433`，主线 PPE 以太网 + ath12k），**尚未集成 QSDK 14.x NSS/Wi-Fi**。

与 `24.10-6.6/` 不同，本目录不需要源码包：上游源码 + 官方 feeds + 本项目补丁
即可装配出完整构建树，CI 全流程可复现（见 `scripts/ci/prepare-tree.sh` 里固定的提交）。

## 目录

```
25.12-6.12/
├── build/                    构建输入
│   ├── sbe1v1k-build.sh      构建入口（定位 sources/、渲染 overlay、固定时钟、调 make）
│   ├── host-shims.txt        宿主机工具清单（host-bin 软链按它重建）
│   ├── deterministic-bin/    date 垫片（固定 SOURCE_DATE_EPOCH）
│   ├── config-seed/          defconfig 种子
│   └── local-packages/       项目自带软件包（sbe1v1k-defaults：ttyd 默认关闭）
├── files/                    固件 overlay（唯一来源，构建时渲染进装配树）
│   ├── etc/banner                /etc/banner，`%V`/`%R` 由渲染脚本替换
│   ├── etc/uci-defaults/99-wireless-defaults   首启入口（boot 以 source 执行）
│   ├── etc/init.d/wireless-defaults            每次开机执行（START=95）
│   └── usr/lib/sbe1v1k/wireless-defaults       实际逻辑（UCI marker 幂等）
├── patches/                  对上游 25.12 的补丁
│   └── 0001-qualcommbe-add-spectrum-sbe1v1k.patch
└── scripts/
    ├── render-overlay.sh     把 files/ 整体复制进装配树并替换版本占位符
    └── ci/
        ├── prepare-tree.sh   仅 CI：克隆上游、钉定 feeds、应用补丁、装本地包
        └── verify-image.sh   从最终 sysupgrade 镜像解出 rootfs 做静态校验
```

## 与上游的差别

`patches/0001-qualcommbe-add-spectrum-sbe1v1k.patch` 只做两件事：

1. `target/linux/qualcommbe/Makefile` 增加 `pwm` 特性（`kmod-leds-pwm` 依赖 `PWM_SUPPORT`）；
2. `target/linux/qualcommbe/image/ipq95xx.mk` 增加 `Device/spectrum_sbe1v1k`：

   - `DEVICE_IMG_PREFIX := sbe1v1k` 与 `KERNEL_SUFFIX := -fit-uImage.itb`
     → 三个交付物分别是 `sbe1v1k-squashfs-sysupgrade.bin`、
     `sbe1v1k-fit-uImage.itb`、`sbe1v1k-initramfs-fit-uImage.itb`；
   - `DEVICE_DTS := ipq9574-rdp433`（Stage 1 复用上游 RDP433 设备树）；
   - 自带 `kmod-leds-pwm`、`kmod-hwmon-pwmfan`。

   `Device/Init` 在设备定义体之前执行，因此设备体内覆盖
   `DEVICE_IMG_PREFIX` / `KERNEL_SUFFIX` 才会生效，这也是文件名可控的原因。

## Stage 1 已知限制（未在真机验证，状态 `UNVERIFIED`）

- 设备树沿用 RDP433（NOR+NAND 布局）；真实板使用 eMMC，vendor 升级脚本走
  `mmc_do_upgrade` / `0:HLOS` + `rootfs`，Stage 1 镜像**不具备**该布局。
- 以太网是主线 PPE 驱动，不是 QSDK NSS-dp；无 NSS 硬件加速。
- 无线为 ath12k 上游驱动，无 QSDK NSS Wi-Fi 插件。
- 板级细节（PWM LED/风扇、板级 MAC、LAN/WAN 端口映射）在 Stage 2 随 NSS 端口一起加入。

因此 Stage 1 产物只用于确认“25.12 + 6.12 能为本板编译出正确命名的镜像”，
**在 Stage 2/3 完成前不要刷入设备**。

## 本机构建

装配树位于 `<工作区>/sources/buildroot-25.12-6.12`。

```sh
cp 25.12-6.12/build/config-seed/ipq95xx-spectrum-sbe1v1k.seed \
   sources/buildroot-25.12-6.12/.config
./25.12-6.12/build/sbe1v1k-build.sh defconfig
./25.12-6.12/build/sbe1v1k-build.sh world -j"$(nproc)"
./25.12-6.12/scripts/ci/verify-image.sh
```

产物在 `sources/buildroot-25.12-6.12/bin/targets/qualcommbe/ipq95xx/`，只交付三个文件：

- `sbe1v1k-squashfs-sysupgrade.bin`
- `sbe1v1k-fit-uImage.itb`
- `sbe1v1k-initramfs-fit-uImage.itb`

## CI

`.github/workflows/build-25.12-6.12.yml`（`name: 📦 Build 25.12-6.12`）在 `main` 分支上，
`.github/workflows/build-25.12-6.12.yml` 或 `25.12-6.12/**` 变更时触发（也可手动
`workflow_dispatch`）。

流程：`prepare-tree.sh`（克隆上游并钉定提交、`feeds update/install`、应用补丁、
装本地包）→ 写 `.config` + `defconfig` → `world` 编译 → `verify-image.sh` →
上传日志/产物 → **每次运行新建一个 Release**，tag 为
`v<run>-<attempt>-<sha8>-25.12-6.12`，资产恰好三个固件文件。

## 注意

- `files/` 由 `include/image.mk` 原样复制进 rootfs，**不经过** `VERSION_SED_SCRIPT`，
  所以 banner 里的 `%V`/`%R` 必须由 `render-overlay.sh` 在构建前替换。
- 构建树的 `version` 文件必须让**最后一个 `-` 分段是十六进制**（这里是上游提交短
  SHA，如 `sbe1v1k-25.12-stage1-f3f5c2e5`）：`base-files` 把包版本拼成
  `<COMMITCOUNT>~<该分段>`，而 apk 3.x 的 `~` 后缀只接受十六进制，非十六进制
  （如 `stage1`）会让 `package/base-files` 编译失败。
- 25.12 默认使用 apk（`CONFIG_USE_APK=y`），镜像内包数据库是
  `/lib/apk/db/installed`（25.12 的位置；脚本也兼容 `/usr/lib/apk/db/installed`
  与 opkg 的 `/usr/lib/opkg/status`）。
- `/etc/rc.d/S95wireless-defaults` 由 `include/rootfs.mk` 的 `prepare_rootfs`
  自动生成，条件是 `etc/init.d/wireless-defaults` 首行**精确**为
  `#!/bin/sh /etc/rc.common` 且权限 0755。
- 构建与校验过程不接触任何设备；产物未经真机验证前记为 `UNVERIFIED`。
