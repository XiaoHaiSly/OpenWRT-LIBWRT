#!/bin/bash
# 软件源专用脚本（在 ./wrt 目录下运行）
# 用法：Feed.sh config | collect | firmware | project
set -eo pipefail

# 填入你的 Cloudflare Pages 域名（例如 openwrt-feed.pages.dev）
# 若保持默认，则固件不写入源，也不进行推送
FEED_HOST="你的项目名.pages.dev"

feed_ready() {
	case "$FEED_HOST" in ""|*你的项目名*) return 1 ;; *) return 0 ;; esac
}

CONF_DIR="$GITHUB_WORKSPACE/Config"

# 解析 PACKAGES.txt 并转为 .config 格式
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
	cat "$CONF_DIR/$WRT_CONFIG.txt" > .config
	grep -hE '^(# )?CONFIG_(KERNEL_|TARGET_|CCACHE|DEVEL|FEED_)' "$CONF_DIR/GENERAL.txt" >> .config || true
	echo "CONFIG_ALL_KMODS=m" >> .config
	if [ "$WRT_FEED_USER" = "true" ]; then
		normalize_packages >> .config
	fi
	;;

collect)
	OUT="$GITHUB_WORKSPACE/feed-out"
	rm -rf "$OUT" && mkdir -p "$OUT"

	# 1. 收集内核模块
	KDIR="$OUT/kmods/$WRT_SUBTARGET"
	mkdir -p "$KDIR"
	cp -f bin/targets/*/*/packages/*.apk "$KDIR"/
	VM=$(find build_dir -maxdepth 4 -name .vermagic -path '*linux-*' | head -n 1)
	[ -n "$VM" ] || { echo "ERROR: .vermagic not found"; exit 1; }
	cat "$VM" > "$KDIR/vermagic"
	make_index "$KDIR"
	echo "kmods: $(ls "$KDIR"/*.apk | wc -l) packages, vermagic $(cat "$KDIR/vermagic")"

	# 2. 收集用户态插件
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
	feed_ready || { echo "FEED_HOST not set, skip writing feed into firmware"; exit 0; }
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
