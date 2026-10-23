#!/usr/bin/env bash
# 25.12-6.12 Stage 1 编译后的静态检查（不接触设备、不执行目标二进制）。
#
# 检查对象是最终交付物本身：本目标的 sysupgrade 镜像是
#   <fit kernel> | pad-to 64k | <squashfs rootfs> | pad-rootfs
# （与上游 qualcommbe/qcom_rdp433 相同的布局），所以先按 64 KiB 对齐定位
# squashfs 偏移，再从镜像里解出根文件系统核对。
#
# 检查项：
#   1. 三个交付镜像齐全、非空，打印尺寸与 SHA-256；
#   2. /etc/banner 与渲染后 overlay 逐字节一致、无占位符、版本行是 25.12；
#   3. 无线默认值三件套哈希/权限一致，/etc/rc.d/S95wireless-defaults 存在；
#   4. LuCI 基础文件存在（与 24.10-6.6 镜像保持一致的选择）；
#   5. apk/opkg 包数据库存在并打印包数量。
#
# 用法：scripts/ci/verify-image.sh [工作区根目录]

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)      # <repo>/25.12-6.12

if [ -n "${SBE_ROOT:-}" ]; then
	ROOT=$SBE_ROOT
else
	ROOT=${1:-}
	if [ -z "$ROOT" ]; then
		d=$PROJ
		while [ "$d" != / ]; do
			if [ -d "$d/sources/buildroot-25.12-6.12" ]; then ROOT=$d; break; fi
			d=$(dirname "$d")
		done
	fi
fi
[ -n "$ROOT" ] || { echo "找不到工作区根（含 sources/buildroot-25.12-6.12），可用 SBE_ROOT 指定" >&2; exit 1; }

BR=${SBE_BUILDROOT:-$ROOT/sources/buildroot-25.12-6.12}
OUT="$BR/bin/targets/qualcommbe/ipq95xx"
OVERLAY="$PROJ/files"
fail=0

say()  { printf '%s\n' "$*"; }
ok()   { printf 'PASS   %s\n' "$*"; }
bad()  { printf 'FAIL   %s\n' "$*"; fail=1; }

SBE_ROOT="$ROOT" SBE_BUILDROOT="$BR" "$PROJ/scripts/render-overlay.sh"

IMG="$OUT/sbe1v1k-squashfs-sysupgrade.bin"
FIT="$OUT/sbe1v1k-fit-uImage.itb"
INITRAMFS="$OUT/sbe1v1k-initramfs-fit-uImage.itb"

for f in "$IMG" "$FIT" "$INITRAMFS"; do
	if [ -s "$f" ]; then
		ok "存在 $(basename "$f") ($(stat -c %s "$f") 字节)"
		sha256sum "$f"
	else
		bad "缺少或为空：$f"
	fi
done
[ -s "$IMG" ] || exit 1

# ---- 定位 squashfs 并解包 ---------------------------------------------------
TMPBASE=${SBE_TMPDIR:-/var/tmp}
TMP=$(mktemp -d "$TMPBASE/sbe-verify.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

UNSQ="$BR/staging_dir/host/bin/unsquashfs4"
[ -x "$UNSQ" ] || UNSQ=$(command -v unsquashfs || true)
[ -n "$UNSQ" ] && [ -x "$UNSQ" ] || { bad "缺少 unsquashfs4"; exit 1; }

# kernel 是 FIT（sbe1v1k-fit-uImage.itb），pad-to 64k 之后紧跟 squashfs。
KSIZE=$(stat -c %s "$FIT")
OFF=$(( (KSIZE + 65535) / 65536 * 65536 ))
magic=$(dd if="$IMG" bs=1 skip="$OFF" count=4 status=none | od -An -tx1 | tr -d ' \n')
if [ "$magic" != "68737173" ] && [ "$magic" != "73717368" ]; then
	# 回退：在镜像里搜索 squashfs 魔数并逐个尝试。
	OFF=""
	while IFS=: read -r pos _; do
		[ -n "$pos" ] || continue
		if "$UNSQ" -o "$pos" -s "$IMG" >/dev/null 2>&1; then OFF=$pos; break; fi
	done < <(grep -abo -a 'hsqs' "$IMG" | head -n 20)
	[ -n "$OFF" ] || { bad "在镜像中找不到 squashfs 超级块"; exit 1; }
fi
say "[verify] squashfs 偏移 $OFF"

set +e
"$UNSQ" -no-progress -o "$OFF" -d "$TMP/rootfs" "$IMG" >"$TMP/unsquashfs.log" 2>&1
rc=$?
set -e
case "$rc" in
	0) ok "squashfs 解包完成" ;;
	2) ok "squashfs 解包完成（rc=2：设备节点权限，非 root 预期）" ;;
	*) bad "squashfs 解包失败 rc=$rc"; sed -n '1,20p' "$TMP/unsquashfs.log"; exit 1 ;;
esac

ROOTFS="$TMP/rootfs"
[ -d "$ROOTFS/etc" ] || { bad "解包结果缺少 /etc"; exit 1; }

# ---- overlay 文件 -----------------------------------------------------------
check_overlay() {
	local rel=$1 src="$BR/files/$1"
	if [ ! -f "$OVERLAY/$1" ]; then bad "overlay 缺少 $rel"; return; fi
	if [ ! -f "$src" ]; then bad "渲染后的 overlay 缺少 $rel"; return; fi
	if [ ! -f "$ROOTFS/$rel" ]; then bad "镜像缺少 /$rel"; return; fi
	local a b
	a=$(sha256sum "$src" | cut -d' ' -f1)
	b=$(sha256sum "$ROOTFS/$rel" | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then ok "/$rel 与渲染后 overlay 一致 ($a)"; else bad "/$rel 哈希不一致"; fi
	local ma mb
	ma=$(stat -c %a "$src")
	mb=$(stat -c %a "$ROOTFS/$rel")
	if [ "$ma" = "$mb" ]; then ok "/$rel 权限 $mb"; else bad "/$rel 权限 $mb，期望 $ma"; fi
}

check_overlay etc/banner
check_overlay etc/uci-defaults/99-wireless-defaults
check_overlay etc/init.d/wireless-defaults
check_overlay usr/lib/sbe1v1k/wireless-defaults

if grep -Eq '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$ROOTFS/etc/banner"; then
	bad "镜像内 /etc/banner 仍含未替换的占位符"
else
	ok "镜像内 /etc/banner 无占位符"
fi

VLINE=$(grep -m1 '^ Version:' "$ROOTFS/etc/banner" || true)
say "版本行:${VLINE:- <缺失>}"
printf '%s' "$VLINE" | grep -Eq '^ Version: 25\.12-SNAPSHOT \(sbe1v1k-' \
	&& ok "版本行为本项目实际版本串" \
	|| bad "版本行不是 25.12-SNAPSHOT (sbe1v1k-…) 形式"

head -n1 "$ROOTFS/etc/init.d/wireless-defaults" | grep -Fxq '#!/bin/sh /etc/rc.common' \
	&& ok "/etc/init.d/wireless-defaults 首行为 rc.common" \
	|| bad "/etc/init.d/wireless-defaults 首行不是 '#!/bin/sh /etc/rc.common'"

RCD="$ROOTFS/etc/rc.d/S95wireless-defaults"
if [ -L "$RCD" ]; then
	tgt=$(readlink "$RCD")
	[ "$tgt" = "../init.d/wireless-defaults" ] \
		&& ok "/etc/rc.d/S95wireless-defaults -> $tgt" \
		|| bad "/etc/rc.d/S95wireless-defaults 指向 $tgt"
else
	bad "缺少 /etc/rc.d/S95wireless-defaults（开机不执行）"
fi

[ -f "$ROOTFS/etc/uci-defaults/99-wireless-defaults" ] \
	&& ok "首启入口 /etc/uci-defaults/99-wireless-defaults 在镜像中" \
	|| bad "镜像缺少首启入口 /etc/uci-defaults/99-wireless-defaults"

[ -f "$ROOTFS/etc/uci-defaults/99-ttyd-disable" ] \
	&& ok "首启入口 /etc/uci-defaults/99-ttyd-disable 在镜像中（ttyd 默认关闭）" \
	|| bad "镜像缺少 /etc/uci-defaults/99-ttyd-disable（ttyd 会默认开启）"

# ---- LuCI 基础栈 ------------------------------------------------------------
for f in etc/config/uhttpd etc/init.d/uhttpd www/cgi-bin/luci; do
	[ -e "$ROOTFS/$f" ] && ok "存在 /$f" || bad "缺少 /$f"
done
# 25.12 把 rpcd 装在 /sbin，24.10 在 /usr/sbin；两处都接受。
if [ -e "$ROOTFS/sbin/rpcd" ] || [ -e "$ROOTFS/usr/sbin/rpcd" ]; then
	ok "存在 rpcd（/sbin/rpcd 或 /usr/sbin/rpcd）"
else
	bad "缺少 rpcd"
fi

# ---- 包数据库 ---------------------------------------------------------------
# apk 数据库在 25.12 是 /lib/apk/db/installed（老版本/opkg 为 /usr/lib/...）。
APKDB=""
for c in lib/apk/db/installed usr/lib/apk/db/installed; do
	[ -f "$ROOTFS/$c" ] && { APKDB=$ROOTFS/$c; break; }
done
if [ -n "$APKDB" ]; then
	n=$(grep -c '^P:' "$APKDB" || true)
	ok "apk 包数量 $n（/${APKDB#$ROOTFS/}）"
elif [ -f "$ROOTFS/usr/lib/opkg/status" ]; then
	n=$(grep -c '^Package:' "$ROOTFS/usr/lib/opkg/status" || true)
	ok "opkg 包数量 $n"
else
	bad "缺少 apk/opkg 包数据库"
fi

exit "$fail"
