#!/bin/sh
# 把文件 B（build/custom-packages.conf）的开关落到装配树 .config，并反查生效情况。
#
# 背景：24.10 CI 不跑 Configure 步骤，.config 直接来自源码包。defconfig 对未知包
# 或依赖不满足的包是**静默丢弃**的，所以本脚本在 defconfig 之后逐条反查，
# 少一个就以非零退出并指名，避免发布一个悄悄少包的镜像。
#
# 用法：
#   scripts/custom-packages.sh                # 应用 + make defconfig + 反查
#   scripts/custom-packages.sh --no-defconfig # 只改 .config + 反查（不跑 make）
#   scripts/custom-packages.sh --check        # 只反查当前 .config，不改不跑
#   scripts/custom-packages.sh --config FILE  # 换一个开关清单
#
# 环境：SBE_ROOT 指定项目根（默认向上查找 sources/buildroot）；跑 defconfig 需要
# 构建环境（host-bin 在 PATH 里），通常经由 build/sbe1v1k-build.sh 调用。
#
# 本脚本不联网、不接触任何设备、不写入口令。

set -eu
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/.." && pwd)
CONF="$PROJ/build/custom-packages.conf"
OPTIONS="$PROJ/build/custom-packages-options.conf"
MODE=apply

die() { echo "[custom] FAIL: $*" >&2; exit 1; }
say() { echo "[custom] $*"; }

while [ "$#" -gt 0 ]; do
	case "$1" in
	--no-defconfig) MODE=edit ;;
	--check)        MODE=check ;;
	--list-enabled) MODE=list ;;
	--config)       [ "$#" -ge 2 ] || die "--config 需要一个文件参数"; CONF=$2; shift ;;
	--options)      [ "$#" -ge 2 ] || die "--options 需要一个文件参数"; OPTIONS=$2; shift ;;
	--no-options)   OPTIONS= ;;
	-h|--help)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)              die "未知参数: $1" ;;
	esac
	shift
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
[ -n "$ROOT" ] || die "找不到装配树 sources/buildroot（可用 SBE_ROOT 指定）"
BUILDROOT="$ROOT/sources/buildroot"
CONFIG="$BUILDROOT/.config"

[ -f "$CONF" ] || die "缺少开关清单: $CONF"

# ---------------------------------------------------------------------------
# 解析文件 B
#
# 只认两种行：
#   CUSTOM_PACKAGES="$CUSTOM_PACKAGES pkg ..."      → 启用
#   # CUSTOM_PACKAGES="$CUSTOM_PACKAGES pkg ..."    → 关闭
# 其他内容（包括本文件的说明性注释）一律忽略。$CUSTOM_PACKAGES 这个词是语法
# 占位符，会被丢弃；等价的 CUSTOM_PACKAGES="pkg ..." 写法也接受。
# ---------------------------------------------------------------------------
PARSE_AWK='
{
	line = $0
	if (line ~ /^[ \t]*#[ \t]*CUSTOM_PACKAGES[ \t]*=/) {
		state = "OFF"
		sub(/^[ \t]*#[ \t]*/, "", line)
	} else if (line ~ /^[ \t]*CUSTOM_PACKAGES[ \t]*=/) {
		state = "ON"
	} else {
		next
	}
	n = split(line, part, "\"")
	if (n < 3) next
	words = split(part[2], word, /[ \t]+/)
	for (i = 1; i <= words; i++) {
		p = word[i]
		if (p == "" || p == "$CUSTOM_PACKAGES" || p == "\"$CUSTOM_PACKAGES\"") continue
		print state, p
	}
}'

PARSED=$(awk "$PARSE_AWK" "$CONF")
ON_LIST=$(printf '%s\n' "$PARSED" | awk '$1=="ON"{print $2}' | awk '!seen[$0]++' | tr '\n' ' ')
OFF_LIST=$(printf '%s\n' "$PARSED" | awk '$1=="OFF"{print $2}' | awk '!seen[$0]++' | tr '\n' ' ')

# 包名白名单校验：拒绝空值、路径、shell 元字符，避免把奇怪内容写进 .config。
for p in $ON_LIST $OFF_LIST; do
	case "$p" in
	*[!A-Za-z0-9._+-]*) die "非法包名: '$p'" ;;
	esac
done

# 同一包既启用又关闭 → 配置自相矛盾，直接失败。
for p in $OFF_LIST; do
	case " $ON_LIST " in
	*" $p "*) die "包 '$p' 在文件 B 中同时被启用和关闭" ;;
	esac
done

if [ -z "${ON_LIST# }" ] && [ -z "${OFF_LIST# }" ]; then
	die "文件 B 没有解析出任何包（检查 CUSTOM_PACKAGES= 行的引号）"
fi

# 只输出启用清单（供 verify-image.sh 断言“已启用就必须装进镜像”），
# 不读写 .config。
if [ "$MODE" = list ]; then
	for p in $ON_LIST; do printf '%s\n' "$p"; done
	exit 0
fi

say "开关清单: $CONF"
say "启用: ${ON_LIST:-（无）}"
say "关闭: ${OFF_LIST:-（无）}"

# ---------------------------------------------------------------------------
# 反查
# ---------------------------------------------------------------------------
verify_config() {
	missing=
	for p in $ON_LIST; do
		grep -Fqx "CONFIG_PACKAGE_$p=y" "$CONFIG" || missing="$missing $p"
	done
	if [ -n "$missing" ]; then
		echo "[custom] FAIL: 以下包在 .config 中不是 =y（defconfig 可能静默丢弃了）:" >&2
		for p in $missing; do echo "  - $p" >&2; done
		exit 1
	fi
	say "反查通过: ${ON_LIST} 全部为 =y"

	for p in $OFF_LIST; do
		if grep -Fqx "CONFIG_PACKAGE_$p=y" "$CONFIG"; then
			echo "[custom] WARN: '$p' 已要求关闭，但仍被其他选项选为 =y（依赖关系？）" >&2
		fi
	done
}

[ "$MODE" = check ] || [ -f "$CONFIG" ] || die "缺少 $CONFIG（先跑一次 defconfig）"

if [ "$MODE" = check ]; then
	verify_config
	exit 0
fi

# ---------------------------------------------------------------------------
# 改写 .config：只动 CONFIG_PACKAGE_<name> 的整行，其余原样保留
# （不做全局重排，保证与现有 .config 字节级一致）。
# ---------------------------------------------------------------------------
cp -p "$CONFIG" "$CONFIG.custom.bak"
say "已备份: $CONFIG.custom.bak"

EDIT_AWK='
BEGIN {
	non = split(on, a, " ")
	for (i = 1; i <= non; i++) {
		if (a[i] == "" || (a[i] in want)) continue
		want[a[i]] = "y"; order[++nord] = a[i]
	}
	noff = split(off, b, " ")
	for (i = 1; i <= noff; i++) {
		if (b[i] == "" || (b[i] in want)) continue
		want[b[i]] = "n"; order[++nord] = b[i]
	}
}
{
	line = $0
	name = ""
	if (line ~ /^CONFIG_PACKAGE_/) {
		eq = index(line, "=")
		if (eq > 16) name = substr(line, 16, eq - 16)
	} else if (line ~ /^# CONFIG_PACKAGE_/) {
		t = substr(line, 3)
		if (sub(/ is not set$/, "", t) && t ~ /^CONFIG_PACKAGE_/) name = substr(t, 16)
	}
	if (name != "" && (name in want)) {
		seen[name] = 1
		if (want[name] == "y") print "CONFIG_PACKAGE_" name "=y"
		else print "# CONFIG_PACKAGE_" name " is not set"
		next
	}
	print
}
END {
	# 只追加“启用”的包。关闭的包如果 .config 里本来就没有对应行，写
	# "# ... is not set" 在 Kconfig 里等价于缺省，反而破坏字节级一致，
	# 所以直接省略。
	for (i = 1; i <= nord; i++) {
		nm = order[i]
		if (nm in seen || want[nm] != "y") continue
		print "CONFIG_PACKAGE_" nm "=y"
	}
}'

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT INT TERM
awk -v on="$ON_LIST" -v off="$OFF_LIST" "$EDIT_AWK" "$CONFIG" > "$TMP"
# 保留原文件权限/属主（.config 一般 0644）
cat "$TMP" > "$CONFIG"
# 技术性固定选项：每轮原样重放（Kconfig 不可见符号会被 defconfig 丢弃，
# 重新打开父应用时回到默认值；只依赖 seed 挡不住这种漂移）。
if [ -n "$OPTIONS" ]; then
	[ -f "$OPTIONS" ] || die "缺少选项清单: $OPTIONS"
	OPT_AWK='
	FNR == NR {
		if ($0 ~ /^CONFIG_[A-Za-z0-9_.+-]+=/) {
			eq = index($0, "=")
			sym = substr($0, 1, eq - 1)
			val = substr($0, eq + 1)
		} else if ($0 ~ /^# CONFIG_[A-Za-z0-9_.+-]+ is not set$/) {
			t = $0; sub(/^# /, "", t); sub(/ is not set$/, "", t)
			sym = t; val = "n"
		} else {
			next
		}
		if (!(sym in want)) order[++n] = sym
		want[sym] = val
		next
	}
	{
		line = $0; sym = ""
		if (line ~ /^CONFIG_[A-Za-z0-9_.+-]+=/) {
			eq = index(line, "="); sym = substr(line, 1, eq - 1)
		} else if (line ~ /^# CONFIG_[A-Za-z0-9_.+-]+ is not set$/) {
			t = line; sub(/^# /, "", t); sub(/ is not set$/, "", t); sym = t
		}
		if (sym != "" && (sym in want)) {
			seen[sym] = 1
			if (want[sym] == "n") print "# " sym " is not set"
			else print sym "=" want[sym]
			next
		}
		print
	}
	END {
		# 与文件 B 不同：这里连 "is not set" 也要补写。父应用关闭时
		# defconfig 会丢弃不可见子选项；重新打开时必须在上一次 defconfig
		# 之前把显式负值放回去，否则 Kconfig 会套用默认值（多个默认是 y）。
		for (i = 1; i <= n; i++) {
			s = order[i]
			if (s in seen) continue
			if (want[s] == "n") print "# " s " is not set"
			else print s "=" want[s]
		}
	}'
	awk "$OPT_AWK" "$OPTIONS" "$CONFIG" > "$TMP"
	cat "$TMP" > "$CONFIG"
	say "已重放固定选项: $OPTIONS"
fi

say "已改写: $CONFIG"

# ---------------------------------------------------------------------------
# defconfig + 反查
# ---------------------------------------------------------------------------
if [ "$MODE" = apply ]; then
	command -v make >/dev/null 2>&1 || die "PATH 中没有 make（去掉 --no-defconfig 时需要构建环境）"
	LOG=$(mktemp)
	trap 'rm -f "$TMP" "$LOG"' EXIT INT TERM
	say "运行 make defconfig ..."
	if ! ( cd "$BUILDROOT" && make defconfig ) >"$LOG" 2>&1; then
		tail -n 40 "$LOG" >&2
		die "make defconfig 失败（完整输出见上）"
	fi
	# 打印 defconfig 中被丢弃/新增的提示行，便于在 CI 日志里定位
	grep -iE 'warning|not found|unknown|error' "$LOG" | head -n 20 || true
fi

verify_config

if [ "$MODE" = apply ]; then
	say "完成：.config 已应用文件 B 并生效"
else
	say "完成：.config 已应用文件 B（未跑 defconfig，生效情况未验证）"
fi
