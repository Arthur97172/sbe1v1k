#!/bin/sh
# 检查 CodeLinaro 厂商内核是否有比当前固定版本更新的发布；可选交互式升级。
#
#   scripts/check-kernel.sh                     只读检查 win_qsdk.common.* 家族；
#                                               发现更新版本时（交互终端）询问是否升级
#   scripts/check-kernel.sh --all               加上 win.linux.6.6.* 与 NHSS.* 家族
#   scripts/check-kernel.sh --upstream          附带读上游 linux-6.6.y 的 SUBLEVEL（仅参考）
#   scripts/check-kernel.sh --yes               有更新就不问，直接升级到最新的那条
#   scripts/check-kernel.sh --no-prompt         只报告，永不询问
#   scripts/check-kernel.sh upgrade <ref>       升级到指定分支（--dry-run 只打印计划）
#   scripts/check-kernel.sh rollback            把最近一次升级整体还原
#
# 检查只发 HTTP GET 读分支列表与单个 Makefile；升级会浅克隆该分支的内核树
# （数 GB）、换掉 qca/src/linux-6.6，并同步版本串。**不编译、不联网上传、
# 不接触任何设备**。
#
# 升级自动匹配的三处（缺一就会出现 uname -r 与真实代码错位）：
#   1. qca/src/linux-6.6                —— 换成新 ref 的工作树（去 .git）
#   2. include/kernel-6.6               —— LINUX_VERSION-6.6 = .<新 SUBLEVEL>
#   3. build-fixes/0002-kernel-6.6-report-*.patch —— 重命名并更新版本/提交记录
# 旧树备份在 sources/.kernel-backup/ 下（**不能**放进 qca/src/：那里的
# linux-*.* 会被 ipq95xx/Makefile:13 的 glob 一起匹配）。
#
# 注意：分支名不含内核版本。实测 win_qsdk.common.1.10.r2 是 6.6.47，
# 而 win_qsdk.common.1.0.r48 是 6.6.147 —— 只能读 Makefile 的 SUBLEVEL 判断。
#
# 状态词：PASS / FAIL / UNVERIFIED / BLOCKED / SOURCE_UNAVAILABLE / NOT TESTED。
# 退出码：0=PASS（已最新或升级完成）1=FAIL 2=UNVERIFIED（有更新，未升级）
#        3=BLOCKED（读不到远端）

set -eu
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/.." && pwd)

# GitLab API 端点（项目路径需 URL 编码）。原始文件端点 /-/raw/ 会返回 429。
API=${SBE_KERNEL_API:-https://git.codelinaro.org/api/v4/projects/clo%2Fqsdk%2Foss%2Fkernel%2Flinux-ipq-6.6}
GITURL=${SBE_KERNEL_GIT_URL:-https://git.codelinaro.org/clo/qsdk/oss/kernel/linux-ipq-6.6}
SLEEP=${SBE_KERNEL_SLEEP:-2}

CMD=check
REF=
ALL=0
UPSTREAM=0
YES=0
DRY=0
FORCE=0
NOPROMPT=${SBE_KERNEL_NO_PROMPT:-0}

for arg in "$@"; do
	case "$arg" in
	check|upgrade|rollback) CMD=$arg ;;
	--all)       ALL=1 ;;
	--upstream)  UPSTREAM=1 ;;
	--yes|-y)    YES=1 ;;
	--dry-run)   DRY=1 ;;
	--force)     FORCE=1 ;;
	--no-prompt) NOPROMPT=1 ;;
	-h|--help)   sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*)          echo "未知参数: $arg" >&2; exit 2 ;;
	*)           REF=$arg ;;
	esac
done

if [ -n "${SBE_ROOT:-}" ]; then
	ROOT=$SBE_ROOT
else
	ROOT=
	d=$PROJ
	while [ "$d" != / ]; do
		if [ -d "$d/sources/buildroot" ]; then ROOT=$d; break; fi
		d=$(dirname "$d")
	done
fi

INC=
TREE=
BKROOT=
if [ -n "$ROOT" ]; then
	INC="$ROOT/sources/buildroot/include/kernel-6.6"
	TREE="$ROOT/sources/buildroot/qca/src/linux-6.6"
	BKROOT="$ROOT/sources/.kernel-backup"
fi
PATCHDIR="$PROJ/build/build-fixes"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sbe-kernel.XXXXXX")
WORK=
BK=
SWAPPING=0

die() { printf '%s\n' "$*" >&2; exit 1; }

cleanup() {
	# 换树/改版本串之后出错：自动还原，避免留下半换状态
	if [ "$SWAPPING" = 1 ] && [ -n "$BK" ]; then
		if [ -f "$BK/state" ] && [ -d "$BK/tree" ]; then
			printf '\n升级未完成，正在自动回滚到 %s…\n' "$BK" >&2
			rollback_from "$BK" >&2 ||
				printf 'WARNING 自动回滚失败，请手工处理 %s\n' "$BK" >&2
		else
			printf 'WARNING 备份不完整，请检查 %s 与 %s\n' "$BK" "$TREE" >&2
		fi
	fi
	if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
	rm -rf "$TMP"
}

trap cleanup EXIT INT TERM

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

ask() { # ask <提示>；--yes 直接通过，非交互一律拒绝
	[ "$YES" = 1 ] && return 0
	if [ ! -t 0 ]; then
		printf 'SKIP  非交互环境，未加 --yes，已取消\n' >&2
		return 1
	fi
	printf '%s [y/N] ' "$1" >&2
	ans=
	read -r ans || ans=
	case $ans in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# get <api-path> <out>；429/5xx/网络错误按 10s、20s、30s 退避重试
LAST_CODE=
get() {
	g_path=$1
	g_out=$2
	g_try=0
	while [ "$g_try" -lt 4 ]; do
		g_try=$((g_try + 1))
		g_code=$(curl -sS -L --max-time 45 -o "$g_out" -w '%{http_code}' \
			"$API$g_path" 2>/dev/null) || g_code=000
		case $g_code in
		200) return 0 ;;
		429|500|502|503|504|000)
			[ "$g_try" -ge 4 ] && break
			printf '      限流/网络错误（HTTP %s），%ds 后重试…\n' "$g_code" $((g_try * 10)) >&2
			sleep $((g_try * 10))
			;;
		*) break ;;
		esac
	done
	LAST_CODE=$g_code
	return 1
}

# ref → URL 参数（/ 需编码）
enc() { printf '%s' "$1" | sed 's|/|%2F|g'; }

# mksub <Makefile> → SUBLEVEL（读不到则为空）
mksub() { sed -n 's/^SUBLEVEL = \([0-9]*\)$/\1/p' "$1" | head -n 1; }

# kernelver <ref> → 6.6.147（读远端 Makefile；失败返回非零）
kernelver() {
	k_out="$TMP/mk.$$"
	get "/repository/files/Makefile/raw?ref=$(enc "$1")" "$k_out" || return 1
	k_v=$(sed -n 's/^VERSION = \([0-9]*\)$/\1/p' "$k_out" | head -n 1)
	k_p=$(sed -n 's/^PATCHLEVEL = \([0-9]*\)$/\1/p' "$k_out" | head -n 1)
	k_s=$(mksub "$k_out")
	k_x=$(sed -n 's/^EXTRAVERSION = \([-rc0-9]*\)$/\1/p' "$k_out" | head -n 1)
	[ -n "$k_v" ] && [ -n "$k_p" ] && [ -n "$k_s" ] || return 1
	printf '%s.%s.%s%s\n' "$k_v" "$k_p" "$k_s" "$k_x"
}

# ---------------------------------------------------------------------------
# 本地固定点
# ---------------------------------------------------------------------------
read_current() {
	CUR=
	if [ -n "$INC" ] && [ -f "$INC" ]; then
		CUR=$(sed -n 's/^LINUX_VERSION-6\.6 = \.\([0-9]*\).*/\1/p' "$INC" | head -n 1)
	fi
	TREESUB=
	if [ -n "$TREE" ] && [ -f "$TREE/Makefile" ]; then
		TREESUB=$(mksub "$TREE/Makefile")
	fi
}

# ---------------------------------------------------------------------------
# 升级：换树 + 同步版本串
# ---------------------------------------------------------------------------
rollback_from() { # rollback_from <备份目录>
	rb=$1
	[ -f "$rb/state" ] || { echo "备份缺少 state: $rb" >&2; return 1; }
	# shellcheck disable=SC1090
	. "$rb/state"
	[ -d "$rb/tree" ] || { echo "备份缺少 tree: $rb" >&2; return 1; }
	rm -rf "$TREE"
	mkdir -p "$(dirname "$TREE")"
	mv "$rb/tree" "$TREE"
	sed -i "s|^LINUX_VERSION-6\.6 = .*|LINUX_VERSION-6.6 = .$old_version|" "$INC"
	rm -f "$PATCHDIR"/0002-kernel-6.6-report-*.patch
	cp "$rb/0002.patch" "$PATCHDIR/$old_patch"
	rm -rf "$rb"
	pass "已回滚到 6.6.$old_version（$TREE、$INC、$old_patch）"
}

do_upgrade() { # do_upgrade <ref>
	u_ref=$1
	[ -n "$u_ref" ] || die "upgrade 需要分支名，例如: $0 upgrade win_qsdk.common.1.0.r50"
	read_current
	[ -n "$CUR" ] || die "读不到 $INC 的 LINUX_VERSION-6.6"
	[ -n "$TREESUB" ] || die "找不到内核树 $TREE/Makefile"

	u_pre=
	if kernelver "$u_ref" > "$TMP/pre" 2>/dev/null; then
		u_pre=$(cat "$TMP/pre")
	fi
	if [ -z "$u_pre" ]; then
		printf 'SOURCE_UNAVAILABLE  预检读不到 %s 的版本（HTTP %s），克隆后再判定\n' \
			"$u_ref" "${LAST_CODE:-?}"
		u_expect='克隆后确定'
		u_sub=
	else
		u_sub=$(printf '%s' "$u_pre" | sed 's/^[0-9]*\.[0-9]*\.\([0-9]*\).*/\1/')
		u_expect=$u_pre
		if [ "$u_sub" -le "$CUR" ] && [ "$FORCE" != 1 ]; then
			printf 'SKIP  %s 是 6.6.%s，不高于当前的 6.6.%s（要强制升级加 --force）\n' \
				"$u_ref" "$u_sub" "$CUR"
			return 0
		fi
	fi

	printf '\n将执行\n'
	printf '  ref          %s（%s）\n' "$u_ref" "$u_expect"
	printf '  下载         %s（浅克隆，数 GB，首次可能 10-40 分钟）\n' "$GITURL"
	printf '  换树         %s → %s/linux-6.6.%s-<时间戳>/tree\n' "$TREE" "$BKROOT" "$CUR"
	printf '  版本串       %s：.%s → %s\n' "$INC" "$CUR" \
		"$(if [ -n "$u_sub" ]; then printf '.%s' "$u_sub"; else printf '新 SUBLEVEL'; fi)"
	printf '  补丁记录     %s/0002-kernel-6.6-report-6.6.%s.patch → 同步新版本\n' "$PATCHDIR" "$CUR"
	printf '  不执行       编译（换树后需自己跑全量 make）\n'

	if [ "$DRY" = 1 ]; then
		printf '\nSKIP  --dry-run：未做任何改动\n'
		return 0
	fi
	ask "确认升级?" || { printf 'SKIP  已取消\n'; return 0; }

	# 1) 下载
	WORK="$ROOT/sources/.kernel-upgrade"
	rm -rf "$WORK"
	mkdir -p "$WORK"
	printf '正在克隆 %s …\n' "$u_ref"
	git clone --depth 1 --single-branch --branch "$u_ref" "$GITURL" "$WORK/src" \
		|| die "FAIL 克隆失败：$u_ref"

	# 2) 克隆后复核
	u_newsub=$(mksub "$WORK/src/Makefile")
	u_ver=$(sed -n 's/^VERSION = \([0-9]*\)$/\1/p' "$WORK/src/Makefile" | head -n 1)
	u_pat=$(sed -n 's/^PATCHLEVEL = \([0-9]*\)$/\1/p' "$WORK/src/Makefile" | head -n 1)
	[ "$u_ver" = 6 ] && [ "$u_pat" = 6 ] && [ -n "$u_newsub" ] \
		|| die "FAIL 克隆到的不是 6.6 内核树：VERSION=$u_ver PATCHLEVEL=$u_pat SUBLEVEL=$u_newsub"
	if [ "$u_newsub" -le "$CUR" ] && [ "$FORCE" != 1 ]; then
		die "FAIL 克隆到的是 6.6.$u_newsub，不高于当前的 6.6.$CUR（要强制升级加 --force）"
	fi
	u_sha=$(git -C "$WORK/src" rev-parse HEAD)
	rm -rf "$WORK/src/.git"

	# 3) 备份旧树与记录。备份放在 sources/.kernel-backup：**不能**放进 qca/src，
	#    否则 qca/src/linux-*.* 的 glob（ipq95xx/Makefile:13）会把备份一起匹配。
	oldp=$(ls -1 "$PATCHDIR"/0002-kernel-6.6-report-6.6.*.patch 2>/dev/null | head -n 1 || true)
	[ -n "$oldp" ] || die "FAIL 找不到 0002 补丁记录（$PATCHDIR）"
	old_patch=$(basename "$oldp")

	ts=$(date +%Y%m%d-%H%M%S)
	BK="$BKROOT/linux-6.6.$CUR-$ts"
	mkdir -p "$BK"
	cp "$oldp" "$BK/0002.patch"
	cat > "$BK/state" <<EOF
old_version=$CUR
old_patch=$old_patch
new_version=$u_newsub
new_sha=$u_sha
ref=$u_ref
created=$ts
EOF
	# state/补丁备份就绪后才置位：此后任何失败都由 cleanup 自动回滚
	SWAPPING=1
	mv "$TREE" "$BK/tree"

	# 4) 换树
	mkdir -p "$TREE"
	rsync -a "$WORK/src/" "$TREE/"
	rm -rf "$WORK"
	WORK=

	# 5) 版本串
	sed -i "s|^LINUX_VERSION-6\.6 = .*|LINUX_VERSION-6.6 = .$u_newsub|" "$INC"
	grep -q "^LINUX_VERSION-6.6 = \.$u_newsub\$" "$INC" \
		|| die "FAIL 写 $INC 失败"

	# 6) 补丁记录：改名 + 更新版本与提交号
	newp="$PATCHDIR/0002-kernel-6.6-report-6.6.$u_newsub.patch"
	sed -e "s|report the pinned 6\.6\.$CUR source version|report the pinned 6.6.$u_newsub source version|" \
	    -e "s|(6\.6\.$CUR, [0-9a-f]*)|(6.6.$u_newsub, $u_sha)|" \
	    -e "s|^+LINUX_VERSION-6\.6 = .*|+LINUX_VERSION-6.6 = .$u_newsub|" \
	    "$oldp" > "$newp"
	# 只查版本字段：补丁里的 LINUX_KERNEL_HASH-6.6.<旧> 是上下文行，本就不改
	if grep -qE "^\+LINUX_VERSION-6\.6 = \.$CUR\$|report the pinned 6\.6\.$CUR |\(6\.6\.$CUR, " "$newp"; then
		printf 'WARNING 补丁记录仍有 6.6.%s 的版本字段，请人工复核 %s\n' "$CUR" "$newp" >&2
	fi
	[ "$newp" = "$oldp" ] || rm -f "$oldp"

	SWAPPING=0
	u_newsha8=$(printf '%s' "$u_sha" | cut -c1-8)
	printf '\n'
	pass "内核树已换成 $u_ref（6.6.$u_newsub，${u_newsha8}）"
	pass "版本串已同步：$INC = .$u_newsub"
	pass "补丁记录已更新：$(basename "$newp")"
	printf 'UNVERIFIED  新内核尚未编译，也未做过任何真机验证（NOT TESTED）\n'
	cat <<EOF

下一步
  cd $ROOT
  make -C sources/buildroot target/linux/clean
  ./24.10-6.6/build/sbe1v1k-build.sh defconfig
  ./24.10-6.6/build/sbe1v1k-build.sh -j"\$(nproc)"
  ./24.10-6.6/scripts/ci/verify-image.sh

注意
  - target/linux/feeds/ipq95xx/config-6.6 可能缺新符号，defconfig 后留意告警/差异；
  - files-6.6 的 sbe1v1k DTS 由 make 每次拷进新树，无需手工处理；
  - CI 用的是 sources-v1 源码包，需重新导出上传后才生效（须另行批准）；
  - 回滚：./24.10-6.6/scripts/check-kernel.sh rollback
EOF
}

do_rollback() {
	[ -n "$ROOT" ] || die "找不到装配树（可用 SBE_ROOT 指定）"
	rb=
	if [ -d "$BKROOT" ]; then
		rb=$(ls -1dt "$BKROOT"/*/ 2>/dev/null | head -n 1 || true)
	fi
	[ -n "$rb" ] || die "没有可回滚的备份（$BKROOT 为空）"
	rb=${rb%/}
	# shellcheck disable=SC1090
	. "$rb/state"
	printf '将回滚到 6.6.%s：恢复 %s、%s、%s\n' "$old_version" "$TREE" "$INC" "$old_patch"
	if [ "$DRY" = 1 ]; then
		printf '\nSKIP  --dry-run：未做任何改动\n'
		return 0
	fi
	ask "确认回滚?" || { printf 'SKIP  已取消\n'; return 0; }
	rollback_from "$rb"
}

# ---------------------------------------------------------------------------
# 检查
# ---------------------------------------------------------------------------
check() {
	printf '当前固定的内核\n'

	[ -n "$INC" ] || fail "找不到装配树（可用 SBE_ROOT 指定）"
	read_current
	if [ -n "$CUR" ]; then
		pass "include/kernel-6.6 LINUX_VERSION-6.6 = .$CUR（上报版本 6.6.$CUR）"
	else
		fail "读不到 include/kernel-6.6 的 LINUX_VERSION-6.6"
	fi
	if [ -n "$TREESUB" ]; then
		pass "qca/src/linux-6.6 Makefile SUBLEVEL = $TREESUB（实际代码 6.6.$TREESUB）"
		if [ -n "$CUR" ] && [ "$TREESUB" != "$CUR" ]; then
			fail "两处不一致：上报 6.6.$CUR，代码 6.6.$TREESUB（同步 build-fixes/0002 后再谈升级）"
		fi
	else
		printf 'SOURCE_UNAVAILABLE  本机没有 qca/src/linux-6.6（%s），只比对 include/kernel-6.6\n' "$TREE"
	fi
	[ -n "$CUR" ] || { printf '\n结论: FAIL 无法确定当前版本\n'; exit 1; }

	printf '\n远端候选\n'
	if ! get "/repository/branches?per_page=100" "$TMP/branches.json"; then
		if [ "$LAST_CODE" = 429 ]; then
			printf '\n结论: BLOCKED CodeLinaro 限流（HTTP 429），稍后重试\n'
		else
			printf '\n结论: BLOCKED 读不到分支列表（HTTP %s）\n' "${LAST_CODE:-?}"
		fi
		exit 3
	fi

	grep -o '"name":"[^"]*"' "$TMP/branches.json" | cut -d'"' -f4 > "$TMP/all.refs" || true
	grep -E '^win_qsdk\.common\.' "$TMP/all.refs" > "$TMP/cand.refs" || true
	if [ "$ALL" = 1 ]; then
		grep -E '^win\.linux\.6\.6|^NHSS\.' "$TMP/all.refs" >> "$TMP/cand.refs" || true
	fi
	if [ "$UPSTREAM" = 1 ]; then
		grep -E '^linux-6\.6\.y' "$TMP/all.refs" > "$TMP/up.refs" || true
	fi

	if [ ! -s "$TMP/cand.refs" ]; then
		printf '\n结论: BLOCKED 分支列表为空或解析失败\n'
		exit 3
	fi

	NEWER=0
	: > "$TMP/hits"
	while IFS= read -r ref; do
		[ -n "$ref" ] || continue
		if ver=$(kernelver "$ref"); then
			sub=$(printf '%s' "$ver" | sed 's/^[0-9]*\.[0-9]*\.\([0-9]*\).*/\1/')
			if [ "$sub" -gt "$CUR" ]; then
				mark='← 新于当前'
				NEWER=$((NEWER + 1))
			elif [ "$sub" -eq "$CUR" ]; then
				mark='与当前同级'
			else
				mark='早于当前'
			fi
			printf '  %-34s %-10s %s\n' "$ref" "$ver" "$mark"
			printf '%s\t%s\n' "$sub" "$ref" >> "$TMP/hits"
		else
			printf '  %-34s %-10s %s\n' "$ref" '?' 'SOURCE_UNAVAILABLE（HTTP '"${LAST_CODE:-?}"'）'
		fi
		sleep "$SLEEP"
	done < "$TMP/cand.refs"

	if [ "$UPSTREAM" = 1 ] && [ -s "$TMP/up.refs" ]; then
		ref='linux-6.6.y/linux-6.6.y'
		if ver=$(kernelver "$ref"); then
			printf '  %-34s %-10s %s\n' "$ref" "$ver" '上游稳定线，无 QSDK 补丁，不可直接替换'
		fi
	fi

	printf '\n'
	if [ "$FAILS" -gt 0 ]; then
		printf '结论: FAIL 本地固定点不一致，先修正再评估升级\n'
		exit 1
	fi

	if [ "$NEWER" -eq 0 ]; then
		printf '结论: PASS 已是最新（当前 6.6.%s 为该家族最高 SUBLEVEL）\n' "$CUR"
		return 0
	fi

	printf '结论: UNVERIFIED 发现 %s 个比 6.6.%s 更新的厂商分支：\n' "$NEWER" "$CUR"
	sort -k1,1nr "$TMP/hits" | awk -F'\t' -v cur="$CUR" \
		'$1+0 > cur+0 { printf "        %s (6.6.%s)\n", $2, $1 }'
	best=$(sort -k1,1nr "$TMP/hits" | awk -F'\t' -v cur="$CUR" '$1+0 > cur+0 { print $2; exit }')
	best_sub=$(sort -k1,1nr "$TMP/hits" | awk -F'\t' -v cur="$CUR" '$1+0 > cur+0 { print $1; exit }')

	if [ "$NOPROMPT" = 1 ] || { [ "$YES" != 1 ] && [ ! -t 0 ]; }; then
		cat <<EOF

升级可以自动完成三处同步（不编译）：
  ./24.10-6.6/scripts/check-kernel.sh upgrade $best
只想看计划：加 --dry-run；还原：rollback。
EOF
		exit 2
	fi

	if ask "是否升级到 $best（6.6.$best_sub）?"; then
		do_upgrade "$best"
	else
		printf 'SKIP  已取消，未做任何改动\n'
		exit 2
	fi
}

case $CMD in
check)    check ;;
upgrade)  do_upgrade "$REF" ;;
rollback) do_rollback ;;
esac
