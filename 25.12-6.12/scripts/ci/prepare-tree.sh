#!/usr/bin/env bash
# 在 CI 工作区里装配 OpenWrt 25.12 构建树。
#
# 与 24.10-6.6 不同，25.12 Stage 1 不需要私有 QSDK 源码包：上游
# openwrt/openwrt 的 openwrt-25.12 分支已经包含 qualcommbe/ipq95xx
# （Linux 6.12 + PPE 以太网），本项目的改动只有设备定义和 pwm 特性，
# 以补丁形式保存在 25.12-6.12/patches/。
#
# 步骤：
#   1. 若 sources/buildroot-25.12-6.12 不存在，克隆 openwrt/openwrt 并
#      检出固定的提交（OPENWRT_SHA）；
#   2. 生成 feeds.conf（openwrt-25.12 分支），feeds update 后把每个 feed
#      检出到记录的提交，再 feeds install -a；
#   3. 按顺序应用 25.12-6.12/patches/*.patch；
#   4. 写入 version（REVISION）与 version.date（固定 SOURCE_DATE_EPOCH）；
#   5. 重建 host-bin（Ubuntu runner 上没有 /usr/bin/gnu* 前缀）。
#
# 用法：scripts/ci/prepare-tree.sh [工作区根目录]
# 只允许在 CI 中运行（会改写 host-bin 指向）。

set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${SBE_CI:-}" != "1" ]; then
	echo "prepare-tree.sh 只用于 CI：请设置 GITHUB_ACTIONS=true 或 SBE_CI=1" >&2
	exit 1
fi

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.12
ROOT=${1:-$(CDPATH= cd -- "$PROJ/.." && pwd)}       # 工作区根（含 sources/）
BR="$ROOT/sources/buildroot-25.12-6.12"
EPOCH=${SBE_SOURCE_DATE_EPOCH:-1792713600}          # 2026-10-23T00:00:00Z

OPENWRT_URL=${OPENWRT_URL:-https://github.com/openwrt/openwrt.git}
OPENWRT_BRANCH=${OPENWRT_BRANCH:-openwrt-25.12}
OPENWRT_SHA=${OPENWRT_SHA:-f3f5c2e54bf432b444e36b1a77077ff476361825}

# REVISION 必须以十六进制分段结尾：base-files 把版本拼成
# "<COMMITCOUNT>~<REVISION 最后一个 '-' 分段>"，而 apk 3.x 的 '~' 后缀
# 只接受十六进制（sbe1v1k-25.12-stage1 → "~stage1" 会被拒绝）。
REVISION=${SBE_REVISION:-sbe1v1k-25.12-stage1-${OPENWRT_SHA:0:8}}

# feed 提交固定为 2026-10-23 本地装配时 feeds update 的结果。
feed_sha() {
	case "$1" in
	luci)      echo 75a306df84a020c57a631ef5b4c02ace56d93387 ;;
	packages)  echo 4a3574914f881a817f0615f1e9765c589eb9bbe2 ;;
	routing)   echo 48c808034414a2112cf9d5261a20a320e8d0d170 ;;
	telephony) echo 2618106d5846a4a542fdf5809f0d3ed228ce439b ;;
	video)     echo 094bf58da6682f895255a35a84349a79dab4bf95 ;;
	*)         echo "" ;;
	esac
}

mkdir -p "$ROOT/sources"

if [ ! -d "$BR" ]; then
	echo "[prepare] 克隆 $OPENWRT_URL ($OPENWRT_BRANCH)"
	git clone --filter=blob:none --no-checkout "$OPENWRT_URL" "$BR"
	git -C "$BR" fetch --depth 1 origin "$OPENWRT_SHA"
	git -C "$BR" checkout -q --detach "$OPENWRT_SHA"
else
	echo "[prepare] 复用已有构建树 $BR"
fi

if [ ! -f "$BR/feeds.conf" ]; then
	cp "$BR/feeds.conf.default" "$BR/feeds.conf"
fi

echo "[prepare] feeds update"
( cd "$BR" && ./scripts/feeds update -a )

echo "[prepare] 检出固定 feed 提交"
for feed in luci packages routing telephony video; do
	sha=$(feed_sha "$feed")
	[ -n "$sha" ] || continue
	[ -d "$BR/feeds/$feed/.git" ] || {
		echo "[prepare] 缺少 feed $feed" >&2; exit 1; }
	git -C "$BR/feeds/$feed" checkout -q "$sha"
done

echo "[prepare] feeds install -a"
( cd "$BR" && ./scripts/feeds install -a )

echo "[prepare] 应用项目补丁"
for p in "$PROJ"/patches/*.patch; do
	[ -e "$p" ] || continue
	echo "[prepare]   $(basename "$p")"
	patch -d "$BR" -p1 --forward --batch < "$p"
done

echo "[prepare] 安装项目自带软件包"
for d in "$PROJ"/build/local-packages/*/; do
	[ -d "$d" ] || continue
	name=$(basename "$d")
	rm -rf "$BR/package/$name"
	cp -a "$d" "$BR/package/$name"
	echo "[prepare]   package/$name"
done

echo "[prepare] 写入 version / version.date"
printf '%s\n' "$REVISION" > "$BR/version"
printf '%s\n' "$EPOCH" > "$BR/version.date"

echo "[prepare] 重建 host-bin（Ubuntu runner 无 gnu* 前缀）"
rm -rf "$PROJ/build/host-bin"
mkdir -p "$PROJ/build/host-bin"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	if [ -x "/usr/bin/$name" ]; then
		ln -sfn "/usr/bin/$name" "$PROJ/build/host-bin/$name"
	else
		echo "[prepare] 缺少宿主机工具：/usr/bin/$name" >&2
		exit 1
	fi
done < "$PROJ/build/host-shims.txt"

echo "[prepare] 完成"
