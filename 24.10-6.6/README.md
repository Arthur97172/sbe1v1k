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

## LuCI（Web 管理界面）

镜像内置 LuCI（`luci-light` 组合 + `luci-mod-admin-full`），由 `uhttpd` + `rpcd` 提供服务，
默认监听 `0.0.0.0:80` 与 `0.0.0.0:443`（`redirect_https` 关闭）。刷机后浏览器打开
`http://<设备地址>/` 即可；`/etc/config/luci` 的 `option lang` 为 `auto`，所有模块都装了
`luci-i18n-*-zh-cn`，浏览器语言为中文时自动切换。

版本（取自镜像内 `/usr/lib/opkg/status`，随 feeds 更新会变化）：

| 组件 | 版本 |
| --- | --- |
| `luci-base` | 26.202.46438~d040071 |
| `luci-light` | 23.024.33244~34dee82 |
| `luci-mod-admin-full` | 19.253.48496~3f93650 |

共 51 个 `luci-*` 包，分三类：

- **核心**：`luci-base`、`luci-light`、`luci-compat`、`luci-mod-admin-full`、
  `luci-mod-network`、`luci-mod-status`、`luci-mod-system`、`luci-lib-*`、
  `luci-proto-ipv6`、`luci-proto-ppp`、`luci-app-package-manager`；
  主题只有 `luci-theme-bootstrap`（未装 argon 等第三方主题）。
- **上游应用**（feeds `luci`）：`luci-app-firewall`、`luci-app-ddns`、`luci-app-upnp`、
  `luci-app-ttyd`。
- **项目与三方应用**：
  - 本项目 feeds（`sources/apps`）：`luci-app-fcc`、`luci-app-ledfancontrol`、
    `luci-app-nssecm`、`luci-app-online-upgrade`、`luci-app-substore`
  - 三方 feeds（`sources/thirdparty-feed`）：`luci-app-bandix-plus`、`luci-app-cpu-status`、
    `luci-app-nikki`、`luci-app-openclash`、`luci-app-passwall`、`luci-app-poweroffdevice`、
    `luci-app-wifihistory`
  - 代理后端（`sources/passwall-selected`）：`chinadns-ng`、`dns2socks`、`ipt2socks`、
    `microsocks`、`shadowsocksr-libev`、`simple-obfs`、`tcping`；另有 `xray`、`sing-box`、
    `mihomo`、`ruby` 等运行依赖，均不带 LuCI 界面包之外的额外前端。

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

`.github/workflows/build-24.10-6.6.yml`（`name: 📦 Build 24.10-6.6`）在 `main` 分支上，
`24.10-6.6/**` 或工作流本身变更时触发（也可手动 `workflow_dispatch`，可指定源码包 tag）。

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
