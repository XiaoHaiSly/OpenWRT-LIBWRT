#!/bin/bash
# 软件源（feed）专用脚本，在 ./wrt 目录下运行
#   Feed.sh config    软件源编译：生成 .config（目标平台 + ALL_KMODS + PACKAGES.txt）
#   Feed.sh collect   软件源编译：筛选产物，生成 packages.adb 索引到 $GITHUB_WORKSPACE/feed-out
#   Feed.sh firmware  固件编译：把软件源地址写进固件（/etc/apk/repositories.d/customfeeds.list）
#   Feed.sh project   发布：输出 Pages 项目名（未填写则输出空）
set -eo pipefail

# ============================================================
# 【只需要改这一行】填你的 Cloudflare Pages 域名，例如 openwrt-feed.pages.dev
# 项目名就是第一段（openwrt-feed），不用带 https://，也不用加结尾 /
# 没改（还是下面的占位文字）时：固件不写软件源，也不推送到 Cloudflare
# ============================================================
FEED_HOST="你的项目名.pages.dev"
# ============================================================

#是否已填写
feed_ready() {
	case "$FEED_HOST" in ""|*你的项目名*) return 1 ;; *) return 0 ;; esac
}

CONF_DIR="$GITHUB_WORKSPACE/Config"

#解析 PACKAGES.txt，输出 .config 格式的行
#  CONFIG_PACKAGE_xxx=y/m -> 统一成 =m（只编译，不进固件）
#  CONFIG_PACKAGE_xxx=n   -> 保持 n（不编译）
#  其它 CONFIG_ 行        -> 原样保留，例如 CONFIG_NODEJS_26=y
#  只写包名的行           -> 自动补成 CONFIG_PACKAGE_包名=m
normalize_packages() {
	[ -f "$CONF_DIR/PACKAGES.txt" ] || return 0
	tr -d '\r' < "$CONF_DIR/PACKAGES.txt" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk '
		/^$/ || /^#/ { next }
		/^CONFIG_PACKAGE_.*=y$/ { sub(/=y$/, "=m"); print; next }
		/^CONFIG_/ { print; next }
		{ print "CONFIG_PACKAGE_" $0 "=m" }'
}

make_index() {
	( cd "$1" && "$APK" mkndx --root "$TOP" --keys-dir "$TOP" --allow-untrusted --output packages.adb ./*.apk )
}

TOP="$PWD"
APK="$TOP/staging_dir/host/bin/apk"

case "$1" in
config)
	#目标平台和设备列表，保证内核配置与固件一致
	cat "$CONF_DIR/$WRT_CONFIG.txt" > .config
	#与固件共用的参数：内核选项、设备/多配置、ccache、feed 开关
	grep -hE '^(# )?CONFIG_(KERNEL_|TARGET_|CCACHE|DEVEL|FEED_)' "$CONF_DIR/GENERAL.txt" >> .config || true
	#所有内核模块都编译成 m，和固件保持完全一致的内核（vermagic）
	echo "CONFIG_ALL_KMODS=m" >> .config
	#插件：只有第一个平台编译用户态插件，其余平台只出 kmod
	if [ "$WRT_FEED_USER" = "true" ]; then
		normalize_packages >> .config
	fi
	;;

collect)
	OUT="$GITHUB_WORKSPACE/feed-out"
	rm -rf "$OUT" && mkdir -p "$OUT"

	#内核模块：bin/targets/<target>/<subtarget>/packages，按子平台分目录
	KDIR="$OUT/kmods/$WRT_SUBTARGET"
	mkdir -p "$KDIR"
	cp -f bin/targets/*/*/packages/*.apk "$KDIR"/
	VM=$(find build_dir -maxdepth 4 -name .vermagic -path '*linux-*' | head -n 1)
	[ -n "$VM" ] || { echo "ERROR: .vermagic not found"; exit 1; }
	cat "$VM" > "$KDIR/vermagic"
	make_index "$KDIR"
	echo "kmods: $(ls "$KDIR"/*.apk | wc -l) packages, vermagic $(cat "$KDIR/vermagic")"

	#用户态插件：只保留最终 .config 里 =m 的包（不含固件默认的 y 包，避免覆盖固件里的核心组件）
	if [ "$WRT_FEED_USER" = "true" ]; then
		ARCH=$(grep -oP '^CONFIG_TARGET_ARCH_PACKAGES="\K[^"]+' .config)
		UDIR="$OUT/packages/$ARCH"
		mkdir -p "$UDIR" ./tmp
		grep -oP '^CONFIG_PACKAGE_\K[^=]+(?==m$)' .config | sort -u > ./tmp/feed-m.txt
		python3 - ./tmp/feed-m.txt "$APK" "$UDIR" bin/packages/"$ARCH"/*/ <<'PY'
import json, os, shutil, subprocess, sys
mfile, apk, dst = sys.argv[1:4]
want = set(open(mfile).read().split())
n = 0
for src in sys.argv[4:]:
    adb = os.path.join(src, "packages.adb")
    if not os.path.exists(adb):
        continue
    data = json.loads(subprocess.check_output([apk, "adbdump", "--format", "json", adb]))
    pkgs = data["packages"] if isinstance(data, dict) else data
    for p in pkgs:
        name = p["name"]
        base = name
        for t in p.get("tags", []):
            if t.startswith("openwrt:abiversion="):
                abi = t.split("=")[-1]
                if base.endswith(abi):
                    base = base[: -len(abi)]
        if base in want or name in want:
            f = os.path.join(src, "%s-%s.apk" % (name, p["version"]))
            if os.path.exists(f):
                shutil.copy2(f, dst)
                n += 1
print("userspace: %d packages" % n)
PY
		if ls "$UDIR"/*.apk >/dev/null 2>&1; then
			make_index "$UDIR"
		else
			echo "WARNING: no userspace package collected, check Config/PACKAGES.txt"
			rmdir "$UDIR" || true
		fi
	fi
	;;

firmware)
	feed_ready || { echo "FEED_HOST not set in Scripts/Feed.sh, skip writing feed into firmware"; exit 0; }
	ARCH=$(grep -oP '^CONFIG_TARGET_ARCH_PACKAGES="\K[^"]+' .config)
	HOST=${FEED_HOST#http://}; HOST=${HOST#https://}; HOST=${HOST%%/*}
	URL="https://$HOST"
	mkdir -p files/etc/apk/repositories.d
	cat > files/etc/apk/repositories.d/customfeeds.list <<LIST
$URL/packages/$ARCH/packages.adb
$URL/kmods/$WRT_SUBTARGET/packages.adb
LIST
	echo "custom feed written:"; cat files/etc/apk/repositories.d/customfeeds.list
	;;

project)
	if feed_ready; then
		HOST=${FEED_HOST#http://}; HOST=${HOST#https://}; HOST=${HOST%%/*}
		echo "${HOST%%.*}"
	fi
	;;

*)
	echo "usage: Feed.sh config|collect|firmware|project"; exit 1
	;;
esac
