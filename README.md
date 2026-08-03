# OpenWrt 25.12 + Qualcomm NSS offload for Cisco Meraki MR52

Hardware-accelerated wifi↔ethernet bridging on the Meraki MR52 (IPQ8068, ipq806x) using the
SoC's two idle NSS cores, on **current OpenWrt 25.12 / kernel 6.12** — the first ipq806x NSS
stack beyond the community builds' kernel 6.6.

**Measured result** (2ss VHT160 client, iperf3 `-P10`, AP acting as a plain bridge):

| | official 25.12 (ath10k-ct) | this build |
|---|---|---|
| bridged wire→wifi | ~420 Mb/s (real-world max) | **588 Mb/s** |
| softirq at full radio blast | cpu0 **100 %** (saturated = the ceiling) | 30–42 %, ~60 % idle |
| accelerated path proof | — | NSS `ipv4_hash_hits` +700k/12 s |

On stock firmware the single-core softirq ceiling caps real-world downloads around
400–450 Mb/s. With the NSS bypass, forwarding itself costs the host ~1–2 % softirq; the
residual load visible during a full-rate iperf run is ath10k interrupt servicing (on
ipq806x only L2/L3 forwarding is offloaded — the wifi driver stays on the host), and the
radio/airtime becomes the limit. Tagged-VLAN bridging accelerates too (646 Mb/s measured
through an `eth0.100` bridge).

## What's in here

```
apply.sh                     copies everything below onto an openwrt-25.12 checkout
patches/kernel/              76 NSS kernel patches (990-*), rebased 6.6 -> 6.12
patches/mac80211/            mac80211 nss-redirect, rebased onto backports 6.18.39
patches/tree-modifications.diff   MR52 DTS (both gmacs -> qcom,nss-gmac), mac80211
                             Makefile NSS plumbing, CONFIG_REGULATOR_NSS_VOLT
package-qca-nss/             vendored qca-nss packages (drv/gmac/ecm/...) with
                             kernel-6.12 compat patches and the MR52-specific fixes
config/diffconfig            build config seed (mainline ath10k, full wpad — required!)
config/files/                rootfs overlay: bridge/DHCP-client network config,
                             dnsmasq off (dumb AP), early at24 load (see below)
docs/DEPLOYMENT.md           deployment gotchas — READ BEFORE FLASHING
```

## Building

```sh
git clone -b openwrt-25.12 https://git.openwrt.org/openwrt/openwrt.git
git clone <this repo> mr52-nss
cd mr52-nss && ./apply.sh ../openwrt
cd ../openwrt
./scripts/feeds update -a && ./scripts/feeds install -a
make defconfig
make -j$(nproc)        # as a regular user; first build compiles the toolchain
```

Image: `bin/targets/ipq806x/generic/openwrt-ipq806x-generic-meraki_mr52-squashfs-sysupgrade.bin`.

### Verifying the image (do this — a successful build proves nothing)

```sh
IMG=bin/targets/ipq806x/generic/openwrt-ipq806x-generic-meraki_mr52-squashfs-sysupgrade.bin
OFF=$(grep -abo hsqs "$IMG" | head -1 | cut -d: -f1)
dd if="$IMG" of=/tmp/r.sqfs bs=1M iflag=skip_bytes skip=$OFF && unsquashfs -d /tmp/rx /tmp/r.sqfs
ls /tmp/rx/lib/modules/6.12.94/ | grep -E 'ath10k|qca-nss|^ecm'   # ath10k*, qca-nss-gmac, qca-nss-drv, ecm
grep -a wpad-openssl /tmp/rx/lib/apk/db/installed                  # full wpad, NOT wpad-basic
cat /tmp/rx/etc/modules-boot.d/10-at24                             # must exist (MAC-vs-probe race)
```

Also decompile the DTB and confirm both `ethernet@37400000/37600000` are `qcom,nss-gmac`
with `qcom,pcs-chanid = <2>/<3>`.

## How it works

* `qca-nss-gmac` drives both ethernet ports (QSDK 12.1 snapshot — the codelinaro tree where
  the classic MR52 blockers are already fixed upstream: MDIO-by-phandle, `of_get_phy_mode`
  out-param, per-lane QSGMII SERDES init, PCS chanid from DT).
* `qca-nss-drv` boots the two NSS cores; `qca-nss-ecm` pushes flow rules so bridged (and
  NATed) flows are forwarded entirely inside the NSS firmware.
* A small mac80211 patch (`nss_redirect`) gives every AP VAP an NSS virtual interface, so
  wifi RX enters the NSS datapath and ECM can shortcut wifi↔ethernet flows.
* Factory MACs come from the i2c EEPROM via the DTS nvmem cells — no scripts needed.

### MR52-specific fixes carried on top (package-qca-nss/qca-nss-gmac/patches/)

| patch | what it fixes |
|---|---|
| `07-kernel-6.12-strscpy` | `strlcpy` removed in 6.8 |
| `08-kernel-6.12-sysctl-compat` | const `ctl_table` handlers, sysctl sentinels, void platform `remove()` |
| `09-mac-nvmem-eprobe-defer` | at24 EEPROM probes after the gmac → driver ignored `-EPROBE_DEFER` and used uninitialised stack as the MAC address; now defers like dwmac |
| `10-set-netdev-dev-pdev` | netdev parent must be the GMAC platform device, not the MDIO bus parent — on MR52 that parent (bitbanged mdio-gpio) has no `dma_mask`, slowpath DMA maps fail and the SoC **hard-resets on first traffic** |

`qca-nss-drv` and `qca-nss-ecm` carry analogous kernel-6.12 compat patches (sysctl API,
`skbuff_ref.h`, `asm/unaligned.h` shim, `ip_route_output` signature, `vmalloc.h`).

## Deployment — read [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)

The short version of the things that will bite you:

1. **Recovery is painful** — MR52's U-Boot has no network and no prompt; a bad image means
   the UART `ubootwrite.py` procedure from the [OpenWrt wiki](https://openwrt.org/toh/meraki/mr52).
   Verify images before flashing.
2. **Bridges with `vlan_filtering` disable ECM completely** — use classic per-VLAN bridges
   (`br-lan` untagged + `br100` on `eth0.100`).
3. **Every bridge must be in a firewall zone** — this build runs with
   `bridge-nf-call-iptables=1` (ECM needs conntrack), so bridged traffic traverses the fw4
   FORWARD chain; a zoneless bridge silently drops forwarded/flooded frames.
4. **Full wpad is required** if you use 802.11k/v (`wpad-basic` rejects `bss_transition`
   and takes the whole interface down with it).
5. **You cannot hot-swap the NSS kernel modules** — they load from `/etc/modules-boot.d/*`
   before the overlay mounts. Changing them = new image.
6. Wifi **STA/client mode does not work** through the NSS path (AP mode only).

## Credits

Built on the shoulders of:
* [ACwifidude's openwrt-23.05 NSS tree](https://github.com/ACwifidude/openwrt) — the original ipq806x NSS project
* [4meters/openwrt-r7800-nss](https://github.com/4meters/openwrt-r7800-nss) — the 24.10 / kernel 6.6 stack this port is based on
* [qosmio/nss-packages](https://github.com/qosmio/nss-packages) — kernel 6.12 compat reference for the qca-nss packages
* QSDK sources: [codelinaro nss-gmac](https://git.codelinaro.org/clo/qsdk/oss/lklm/nss-gmac)

## License

The patches and build glue follow the licenses of the code they modify (GPL-2.0 for kernel
and OpenWrt parts; QSDK components carry their own permissive QCA license headers).
