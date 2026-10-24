#!/usr/bin/env bash
# 构建“带厂商 Wi-Fi 固件”的本机自用镜像。
#
# 这个镜像会把这 6 个专有 blob 打进 rootfs（LICENSE_REVIEW_REQUIRED，项目决策
# N-3），**只能在本机自用，不得上传**：公开仓库的 CI 走的是另一个分支
# （workflow 里关掉 sbe-wifi-firmware，并用 SBE_PUBLIC_IMAGE=1 校验）。
#
# 启动后的自动流程（无需人工干预）：
#   S09sbe-wifi-cal  → 从本机 eMMC 0:ART 生成 cal-pci-*.bin
#   S10boot          → kmodloader 加载 ath12k（此时固件与校准都已就位）
#   S19wpad / S95wireless-defaults → 按无线默认值起 hostapd
#
# 用法：scripts/local/build-wifi-image.sh [make 目标，默认 world]

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.12
ROOT=$(CDPATH= cd -- "$PROJ/.." && pwd)
FW="$PROJ/build/local-packages/sbe-wifi-firmware/files"
TARGET=${1:-world}

# 绝不在 CI 里跑：那里没有 blob，跑出来的是无固件镜像，而且上传即违规。
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
	echo "拒绝在 GitHub Actions 中运行：本脚本会产出含专有固件的镜像。" >&2
	exit 1
fi

[ -f "$FW/FILES-SHA256" ] || { echo "缺少 $FW/FILES-SHA256" >&2; exit 1; }
if ! ( cd "$FW" && sha256sum -c FILES-SHA256 ); then
	echo "固件 blob 缺失或哈希不符，先补齐 build/local-packages/sbe-wifi-firmware/files/" >&2
	exit 1
fi

echo "[wifi-image] 构建 $TARGET（含厂商固件）"
"$PROJ/build/sbe1v1k-build.sh" "$TARGET" -j"$(nproc)"

echo "[wifi-image] 静态校验（默认模式：要求镜像带固件且哈希一致）"
"$PROJ/scripts/ci/verify-image.sh" "$ROOT"

OUT="$ROOT/sources/buildroot-25.12-6.12/bin/targets/qualcommbe/ipq95xx"
echo "[wifi-image] 产物（含厂商固件，禁止上传）："
sha256sum "$OUT/sbe1v1k-squashfs-sysupgrade.bin" \
          "$OUT/sbe1v1k-fit-uImage.itb" \
          "$OUT/sbe1v1k-initramfs-fit-uImage.itb"
