#!/usr/bin/env bash
# 导出“已装配源码包”，供 GitHub Actions 下载后直接编译。
#
# 为什么需要它：sources/buildroot 不是单纯的上游 clone，而是
#   qsdk 14.0 基座 + 若干 codelinaro 钉定 commit + 本项目 P-B/build-fixes
#   + target/linux/feeds + openwrt-patches + files/ overlay
# 的装配结果（见 docs/BUILD_TREE_ASSEMBLY.md）。逐仓库重建无法逐字节复现，
# 因此把已验证的装配树整体打包，作为 Release 资产发布，由 CI 下载。
#
# 产出（默认 <工作区>/dist）：
#   sbe1v1k-sources-buildroot-<stamp>.tar.zst   sources/buildroot（不含构建产物）
#   sbe1v1k-sources-feeds-<stamp>.tar.zst       sources/{luci,apps,thirdparty,...}
#   sbe1v1k-sources-dl-<stamp>.tar.zst          sources/buildroot/dl（离线下载缓存）
#   SHA256SUMS
#
# 不包含：build_dir、staging_dir、tmp、bin（可由编译再生），
#         buildroot/files（由 scripts/render-overlay.sh 从 24.10-6.6/files 渲染，
#         源码包里的旧副本不应参与构建），
#         qsdk14/、codelinaro/（审计用参考副本，编译不需要），
#         key-build*（私钥，禁止发布）。
#
# dl/ 单独成包：它是编译期第三方 tarball 的缓存（1.7 GB），带上它 CI 才能
# 离线复现同一批输入，避免依赖上游 URL 的可用性。
#
# 用法：scripts/ci/export-sources.sh [输出目录] [stamp]

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)      # <repo>/24.10-6.6
ROOT=${SBE_ROOT:-$(CDPATH= cd -- "$PROJ/.." && pwd)}
OUT=${1:-$ROOT/dist}
STAMP=${2:-$(date -u +%Y%m%d)}

[ -d "$ROOT/sources/buildroot" ] || { echo "缺少 $ROOT/sources/buildroot" >&2; exit 1; }
mkdir -p "$OUT"

echo "[export] buildroot -> $OUT/sbe1v1k-sources-buildroot-$STAMP.tar.zst"
tar -C "$ROOT/sources" --zstd -cf "$OUT/sbe1v1k-sources-buildroot-$STAMP.tar.zst" \
	--exclude='buildroot/build_dir' \
	--exclude='buildroot/staging_dir' \
	--exclude='buildroot/tmp' \
	--exclude='buildroot/bin' \
	--exclude='buildroot/dl' \
	--exclude='buildroot/files' \
	--exclude='buildroot/key-build' \
	--exclude='buildroot/key-build.pub' \
	--exclude='buildroot/key-build.ucert' \
	--exclude='buildroot/key-build.ucert.revoke' \
	--exclude='buildroot/.config.*.bak' \
	--exclude='buildroot/.config.*backup' \
	buildroot

echo "[export] feeds/apps -> $OUT/sbe1v1k-sources-feeds-$STAMP.tar.zst"
tar -C "$ROOT/sources" --zstd -cf "$OUT/sbe1v1k-sources-feeds-$STAMP.tar.zst" \
	luci \
	apps \
	thirdparty \
	thirdparty-feed \
	passwall-selected \
	local-relayout \
	PROVENANCE.md \
	README.md

echo "[export] dl 缓存 -> $OUT/sbe1v1k-sources-dl-$STAMP.tar.zst"
tar -C "$ROOT/sources" --zstd -cf "$OUT/sbe1v1k-sources-dl-$STAMP.tar.zst" buildroot/dl

echo "[export] 校验和"
( cd "$OUT" && sha256sum sbe1v1k-sources-*-"$STAMP".tar.zst | tee SHA256SUMS )

echo "[export] 完成。请把三个 .tar.zst 与 SHA256SUMS 上传到固定的 Release（例如 sources-v1），"
echo "         并在 docs/CI_BUILD.md 记录新的 SHA-256。"
