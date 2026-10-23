# 24.10-6.6 — Spectrum SBE1V1K 固件构建输入

OpenWrt 24.10-SNAPSHOT + QSDK 14.0，目标板 `spectrum_sbe1v1k`（IPQ9574，Linux 6.6）。

本目录只放**编译必需**的文件；装配好的源码树（约 2.4 GB）不在这里，而是作为
Release 资产 `sources-v1` 保存，由 CI 下载并校验 SHA-256 后解包到 `sources/`。

## 目录

```
24.10-6.6/
├── build/                    构建输入
│   ├── sbe1v1k-build.sh      构建入口（定位 sources/、渲染 overlay、固定时钟、调 make）
│   ├── host-shims.txt        宿主机工具清单（host-bin 软链按它重建）
│   ├── deterministic-bin/    date 垫片（固定 SOURCE_DATE_EPOCH）
│   ├── config-seed/          defconfig 种子
│   ├── build-fixes/  local-packages/  p-b/   装配期改动与本地软件包
├── files/                    固件 overlay（唯一来源，构建时渲染进装配树）
│   ├── etc/banner                /etc/banner，`%V`/`%R` 由渲染脚本替换
│   ├── etc/uci-defaults/99-wireless-defaults   首启入口（boot 以 source 执行）
│   ├── etc/init.d/wireless-defaults            每次开机执行（START=95）
│   └── usr/lib/sbe1v1k/wireless-defaults       实际逻辑（UCI marker 幂等）
└── scripts/
    ├── render-overlay.sh     把 files/ 整体复制进 sources/buildroot/files 并替换版本占位符
    └── ci/
        ├── prepare-tree.sh   仅 CI：重写 feeds 绝对路径、重建 host-bin、固定时间戳
        ├── verify-image.sh   从最终 sysupgrade 镜像解出 rootfs 做静态校验
        └── export-sources.sh 本地导出源码包（发布到 sources-* Release）
```

## 本机构建

装配树位于 `<工作区>/sources/buildroot`（本目录的上一级目录里）。

```sh
./24.10-6.6/build/sbe1v1k-build.sh defconfig            # 生成 .config
./24.10-6.6/build/sbe1v1k-build.sh -j"$(nproc)"         # 完整编译
./24.10-6.6/build/sbe1v1k-build.sh -j"$(nproc)" target/install   # 只重做 rootfs/镜像
./24.10-6.6/scripts/ci/verify-image.sh                  # 静态校验
```

产物在 `sources/buildroot/bin/targets/ipq95xx/generic/`，只交付三个文件：

- `openwrt-ipq95xx-generic-spectrum_sbe1v1k-squashfs-sysupgrade.bin`
- `openwrt-ipq95xx-generic-spectrum_sbe1v1k-fit-uImage.itb`
- `openwrt-ipq95xx-generic-spectrum_sbe1v1k-initramfs-fit-uImage.itb`

## CI

`.github/workflows/build.yml` 在 `main` 分支上，`24.10-6.6/**` 或工作流本身变更时
触发（也可手动 `workflow_dispatch`，可指定源码包 tag）。

流程：下载并校验源码包 → 解包到 `sources/` → `prepare-tree.sh` → `render-overlay.sh`
（占位符没替换成功就立刻失败）→ 编译 → `verify-image.sh` → 上传日志/产物 →
**每次运行新建一个 Release**，tag 为 `v<run>-<attempt>-<sha8>`，资产恰好三个固件文件。

## 注意

- `files/` 由 `include/image.mk` 原样复制进 rootfs，**不经过** `VERSION_SED_SCRIPT`，
  所以 banner 里的 `%V`/`%R` 必须由 `render-overlay.sh` 在构建前替换。
- `/etc/rc.d/S95wireless-defaults` 由 `include/rootfs.mk` 的 `prepare_rootfs`
  自动生成，条件是 `etc/init.d/wireless-defaults` 首行**精确**为
  `#!/bin/sh /etc/rc.common` 且权限 0755。
- `/etc/uci-defaults/*` 由 `/etc/init.d/boot` 以 `.` 方式加载，成功后删除，
  因此那里的包装脚本不能 `exec`、`exit` 或 `set -e`。
- 构建与校验过程不接触任何设备；产物未经真机验证前记为 `UNVERIFIED`。
