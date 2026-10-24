#!/usr/bin/env bash
# 把厂商树里的 NSS 源码打成公开可下载的 Release 资产 nss-src-v1.tar.gz。
#
# 为什么需要：CI 的装配树里没有厂商 QSDK 树（sources/buildroot，数十 GB，
# 不入库），而默认设备 spectrum_sbe1v1k 的 DEVICE_PACKAGES 依赖
# kmod-qca-ssdk-nohnat / kmod-qca-nss-dp / kmod-qca-nss-ppe。没有源码就装
# 不上这三个包，而补丁 0009 又删掉了主线 PPE 节点 —— 结果是没有以太网的
# 镜像。因此把四个包的源码单独发布，CI 在 prepare-tree.sh 里下载。
#
# 只打包源码，不含任何二进制固件：
#   qca-ssdk  qca-nss-phy  qca-nss-dp  qca-nss-ppe
#
# 授权：四个包内的 .c/.h/Makefile 全部是 ISC（部分文件带 SPDX 行，其余在
# 文件头写明同样的 ISC 许可文本）。脚本最后会复核一次，并生成
# NOTICE-ISC.txt 一并打包。
#
# 用法：
#   scripts/ci/export-nss-src.sh [输出目录]      # 默认 /var/tmp/sbe-nss
#   scripts/ci/export-nss-src.sh --upload [输出目录]
#
# --upload 需要环境变量 GH_TOKEN，并且发布到 Arthur97172/sbe1v1k 的
# nss-src-v1 Release（公开仓库 → 资产可匿名下载，CI 不需要 token）。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)
ROOT=$(CDPATH= cd -- "$PROJ/.." && pwd)

REPO=Arthur97172/sbe1v1k
TAG=nss-src-v1
NAME=nss-src-v1
PKGS="qca-ssdk qca-nss-phy qca-nss-dp qca-nss-ppe"

UPLOAD=0
if [ "${1:-}" = "--upload" ]; then
	UPLOAD=1
	shift
fi
OUT=${1:-/var/tmp/sbe-nss}

SRC_BASE=${SBE_NSS_SRC_BASE:-$ROOT/sources/buildroot/qca/src/nss/base}
[ -d "$SRC_BASE" ] || { echo "缺少 NSS 源码目录：$SRC_BASE" >&2; exit 1; }

for p in $PKGS; do
	[ -d "$SRC_BASE/$p" ] || { echo "缺少源码目录：$SRC_BASE/$p" >&2; exit 1; }
done

# ---- 授权复核 ---------------------------------------------------------------
bad=0
for p in $PKGS; do
	# 每个包里必须能找到 ISC 声明；出现 GPL/Apache/机密字样则停下人工复核。
	if ! grep -rqE 'SPDX-License-Identifier: ISC|Permission to use, copy, modify, and/or distribute' \
	     "$SRC_BASE/$p" --include='*.c' --include='*.h' --include='Makefile' --include='*.mk'; then
		echo "授权复核：$p 里找不到 ISC 声明" >&2; bad=1
	fi
	hits=$(grep -rliE 'GNU General Public|Apache License|Confidential' "$SRC_BASE/$p" 2>/dev/null || true)
	if [ -n "$hits" ]; then
		echo "授权复核：$p 里出现需人工确认的许可字样：" >&2
		printf '%s\n' "$hits" | sed 's/^/  /' >&2
		bad=1
	fi
done
[ "$bad" = 0 ] || { echo "授权复核未通过，拒绝打包" >&2; exit 1; }

# 源码目录里不允许混入二进制（避免把固件/预编译产物发出去）。
blobs=$(find $(for p in $PKGS; do printf '%s ' "$SRC_BASE/$p"; done) \
	\( -name '*.bin' -o -name '*.fw' -o -name '*.o' -o -name '*.ko' \
	   -o -name '*.a' -o -name '*.so*' -o -name '*.apk' \) 2>/dev/null || true)
if [ -n "$blobs" ]; then
	echo "源码目录里出现二进制文件，拒绝打包：" >&2
	printf '%s\n' "$blobs" | sed 's/^/  /' >&2
	exit 1
fi

# ---- 组装 -------------------------------------------------------------------
rm -rf "$OUT/$NAME"
mkdir -p "$OUT/$NAME"
for p in $PKGS; do
	cp -a "$SRC_BASE/$p" "$OUT/$NAME/$p"
done

cat > "$OUT/$NAME/NOTICE-ISC.txt" <<'EOF'
NSS source bundle (nss-src-v1)
==============================

Contents: qca-ssdk, qca-nss-phy, qca-nss-dp, qca-nss-ppe, taken verbatim from
the QSDK 14.x vendor tree.

License: ISC, as stated in every source file (either as an SPDX line or as the
full ISC permission text in the file header). Copyright remains with The Linux
Foundation and Qualcomm Innovation Center, Inc. / Qualcomm Technologies, Inc.
and/or its subsidiaries.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.

No binary firmware is included: this bundle contains source only.  The
portability patches that make these sources build against Linux 6.12 live in
25.12-6.12/nss/patches/ and are applied by 25.12-6.12/nss/install.sh.
EOF

# 固定时间戳，不用 git 提交时间：否则每次提交后重新打包都会得到新的 sha256，
# 而 nss/nss-src.tar.gz.sha256 是提交进仓库、供 CI 校验的期望值。
# 取值与 prepare-tree.sh 的 SBE_SOURCE_DATE_EPOCH 默认值一致（2026-10-23T00:00:00Z）。
EPOCH=${SOURCE_DATE_EPOCH:-${SBE_SOURCE_DATE_EPOCH:-1792713600}}

# 可复现打包：固定排序、mtime、属主，gzip 不带时间戳。
tar -C "$OUT" --sort=name --mtime="@$EPOCH" --owner=0 --group=0 \
	--numeric-owner -cf - "$NAME" | gzip -9n > "$OUT/$NAME.tar.gz"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

echo
echo "产物："
ls -l "$OUT/$NAME.tar.gz"
cat "$OUT/$NAME.tar.gz.sha256"

if [ "$UPLOAD" = 1 ]; then
	[ -n "${GH_TOKEN:-}" ] || { echo "--upload 需要 GH_TOKEN 环境变量" >&2; exit 1; }
	if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
		gh release create "$TAG" --repo "$REPO" \
			--title "NSS 源码包（QSDK 14.x，ISC）" \
			--notes "供 25.12-6.12 CI 构建使用的 NSS 源码（ISC）。

内容：qca-ssdk、qca-nss-phy、qca-nss-dp、qca-nss-ppe，逐字取自 QSDK 14.x 厂商树；
仅源码，不含任何二进制固件。CI 在 prepare-tree.sh 里按
25.12-6.12/nss/nss-src.tar.gz.sha256 校验后解包。
"
	fi
	gh release upload "$TAG" "$OUT/$NAME.tar.gz" "$OUT/$NAME.tar.gz.sha256" \
		--repo "$REPO" --clobber
	echo "已上传到 $REPO 的 $TAG"
fi
