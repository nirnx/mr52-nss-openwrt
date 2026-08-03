# Deployment notes — the things that will bite you

Everything below was learned the hard way on real MR52 units. Read before flashing.

## 1. Flashing and recovery

* MR52's stock U-Boot (2012.07) has **no network and no autoboot interrupt**. If the kernel
  panics before preinit, failsafe is unreachable — the only way back is the official UART
  recovery: `ubootwrite.py --write=mr52_u-boot.bin` at power-on, then TFTP an initramfs
  (host at 192.168.1.250; ~13 min upload; solid white LED when loaded). Keep an initramfs
  image built (`CONFIG_TARGET_ROOTFS_INITRAMFS=y` — this repo's diffconfig does).
* Always run `sysupgrade` in the **foreground** (never background it over ssh) and verify
  the image content first (README: "Verifying the image").
* A downgrade sysupgrade does not preserve config. Upgrading from official 25.12 with
  `sysupgrade` (no `-n`) preserves config and works — interface names survive, wifi configs
  bind radios by PCI path.
* While an AP crash-loops after a bad first boot, the overlay may still be **unformatted**:
  anything you copy in "persists" only to tmpfs and vanishes on reboot. Check
  `mount | grep overlayfs` shows ubifs-backed `/overlay` before trusting any fix you write.

## 2. Module load order subtleties

* The NSS kmods (`qca-nss-gmac`, `qca-nss-drv`, `ecm`) autoload from
  `/etc/modules-boot.d/*` at t≈3.5 s — **before the overlay mounts** (t≈9 s). Consequences:
  * You **cannot hot-swap** these modules by replacing the `.ko` in the overlay — the
    squashfs copy always wins. Driver changes require a new image.
  * `config/files/etc/modules-boot.d/10-at24` in this repo loads the EEPROM driver *before*
    the gmac (10 < 31), so the factory MAC is readable at first probe. It must be **baked
    into the image** (an overlay copy is invisible at that point in boot).
* Removing `AUTOLOAD` doesn't keep the modules out: `mac80211 → qca-nss-drv → qca-nss-gmac`
  is a hard dependency chain.

## 3. ECM / acceleration

* **A bridge with `vlan_filtering=1` (OpenWrt `bridge-vlan` sections) disables ECM
  entirely** — `ecm_db/connection_count` stays 0 forever, traffic silently takes the CPU
  path. Use the classic layout instead:

  ```
  config device                      # untagged bridge
      option name 'br-lan'
      option type 'bridge'
      list ports 'eth0'
      list ports 'eth1'

  config device                      # one bridge per VLAN
      option name 'br100'
      option type 'bridge'
      list ports 'eth0.100'
      list ports 'eth1.100'

  config interface 'v100'
      option device 'br100'
      option proto 'none'            # dumb AP: no IP needed
  ```

  Wifi ifaces join via `option network 'lan'` / `'v100'` as usual. VLAN tags for
  accelerated flows are applied per-flow by the NSS firmware (ECM builds the hierarchy over
  the 8021q subinterface — `ECM_INTERFACE_VLAN_ENABLE=y` is already set). Do **not** enable
  `NSS_DRV_VLAN_ENABLE`; that vlan node is an ipq807x/PPE feature, absent from ipq806x
  firmware.
* **Every bridge must be in a firewall zone.** ECM requires conntrack on bridged traffic,
  so the build runs with `bridge-nf-call-iptables=1` — bridged frames traverse fw4's
  FORWARD chain, and frames on a zoneless bridge are silently dropped. Symptom: clients
  associate but never get DHCP; tcpdump shows the DISCOVER on the bridge but never on the
  egress port. Fix: `uci add_list firewall.@zone[0].network='v100'`.
* Verifying acceleration:
  ```sh
  cat /sys/kernel/debug/ecm/ecm_db/connection_count          # >0 = ECM sees flows
  cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count   # >0 = rules pushed to NSS
  grep ipv4_hash_hits /sys/kernel/debug/qca-nss-drv/stats/ipv4   # grows = pkts forwarded in fw
  ```
  Note: iperf **against the AP itself** can never show the bypass (locally-terminated
  traffic must cross the host CPU). Measure through the AP as a bridge.

## 4. Wifi

* **Full wpad is required** for 802.11k/v (`bss_transition`, `ieee80211k`). `wpad-basic-*`
  rejects the option and hostapd then fails the **entire interface** ("1 errors found in
  configuration file" → no SSIDs at all). The diffconfig swaps in `wpad-openssl` at the
  device-package level — plain `CONFIG_PACKAGE_wpad-openssl=y` is NOT enough with
  per-device rootfs builds.
* If you apk-swap wpad on a live system, `wifi` reload is not enough — the old hostapd
  process keeps running; do `/etc/init.d/wpad restart`.
* **STA (client) mode does not pass data** through the NSS path (`NSS_TX_FAILURE_NOT_ENABLED`);
  AP mode only. No wireless rescue link on this build.
* Mainline ath10k (not -ct) is used; **phy enumeration order races** per boot and per
  device (the 4x4 QCA9984 can be phy0 on one unit and phy1 on another). uci binds radios by
  PCI path so configs are safe, but never hardcode `phyX` in scripts.
* This hardware occasionally reports **DFS radar false positives** (seen on ch100): hostapd
  jumps to a fallback channel and the affected range gets a 30-min NOP. The NOP lives in
  RAM — a reboot clears it. VHT160 from ch36 also spans DFS channels (52–64), so it does a
  60 s CAC on every radio restart.
* 802.11r on 2.4 GHz breaks some IoT/TV clients (they bail when the beacon RSN carries FT
  AKMs). Keep FT on 5 GHz only.

## 5. Known-benign warnings

* A one-off `WARNING ... br_nf_local_in` (br_netfilter conntrack confirm on an NSS-injected
  skb) may appear once under early traffic. Harmless so far; investigate only if it recurs.
* `grep -i oops` on dmesg matches `ramoops` — don't scare yourself.

## 6. Performance expectations

* The offload moves the ceiling from the CPU to airtime/PHY. With a 2-stream VHT160 client
  expect a solid real-world gain over stock (~420 -> ~590 Mb/s bridged here — the
  single-core softirq ceiling is gone). Normal forwarding costs ~1–2 % softirq; under a
  full-rate wifi load you will still see some softirq from ath10k interrupt servicing
  (the wifi driver itself is not offloaded on ipq806x), with plenty of idle headroom left.
* Wifi→wire direction is client-TX limited; wire→wifi is where the AP does the work.
