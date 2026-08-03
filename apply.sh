#!/bin/sh
# Apply the MR52 NSS overlay onto an OpenWrt 25.12 checkout.
# Usage: ./apply.sh /path/to/openwrt
set -e

OPENWRT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -n "$OPENWRT" ] && [ -f "$OPENWRT/feeds.conf.default" ] || {
	echo "usage: $0 /path/to/openwrt   (an openwrt-25.12 checkout)" >&2
	exit 1
}

echo ">> NSS packages -> package/qca-nss"
cp -r "$HERE/package-qca-nss" "$OPENWRT/package/qca-nss"

echo ">> kernel patches -> target/linux/ipq806x/patches-6.12"
cp "$HERE"/patches/kernel/990-*.patch "$OPENWRT/target/linux/ipq806x/patches-6.12/"

echo ">> mac80211 nss-redirect -> package/kernel/mac80211/patches/subsys"
cp "$HERE"/patches/mac80211/990-*.patch "$OPENWRT/package/kernel/mac80211/patches/subsys/"

echo ">> tracked-file modifications (MR52 DTS, mac80211 Makefile, target config)"
git -C "$OPENWRT" apply "$HERE/patches/tree-modifications.diff"

echo ">> rootfs overlay -> files/"
mkdir -p "$OPENWRT/files"
cp -r "$HERE"/config/files/. "$OPENWRT/files/"

echo ">> config seed -> .config"
cp "$HERE/config/diffconfig" "$OPENWRT/.config"

cat <<'EOF'

Done. Now:
  cd <openwrt>
  ./scripts/feeds update -a && ./scripts/feeds install -a
  make defconfig
  make -j$(nproc)     # build as a regular user, not root

Verify the image before flashing — see README.md "Verifying the image".
EOF
