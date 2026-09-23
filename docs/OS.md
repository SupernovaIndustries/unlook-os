# Unlook OS — build, flash, first boot, updates, rollback, production

Unlook OS is the appliance image for the Unlook 3D scanner on the Raspberry Pi
CM5: Raspberry Pi OS Lite 64-bit (bookworm) built with pi-gen, the
`unlook-sdk` daemon as the only application, A/B root filesystems updated
with signed RAUC bundles, a persistent data partition, and a second, fast
update channel for the SDK alone through a signed apt repository.

```
            phone (BLE pairing → hotspot)   robot / PLC / PC (USB-C, Ethernet, UART)
                          │                                  │
                 stream :5555  ◄──── unlook-stream ────►  UCP :5556 / serial
                                        │  ota_check / ota_apply:<sdk|os> / ota_status
                                        ▼
                                   unlook-ota ──► apt (Unlook repo)      → SDK .deb
                                        │    └──► RAUC bundle (HTTPS)    → inactive slot
                                        ▼
            reboot "0 tryboot" ─► new slot ─► unlook-health (≤120 s) ─► commit | rollback
```

---

## 1. Repository

| Path | What |
| --- | --- |
| `config/unlook-os.conf` | every build knob (overlays, ports, partition sizes, URLs, users) |
| `build.sh` | `rootfs` (pi-gen in Docker) → `image` (A/B GPT) → `bundle` (RAUC) |
| `stages/stage-unlook/` | the custom pi-gen stage (runs after pi-gen `stage2` = Lite) |
| `stages/stage-unlook/overlay/` + `overlay.manifest` | every file the OS adds, with its mode |
| `image/mkimage.sh` | GPT image from the rootfs tarball, no loop devices |
| `rauc/` | bundle manifest, install hook, bundle build/sign |
| `apt/build-repo.sh` | signed apt repository (reprepro) + publication |
| `scripts/` | build helpers, dev keys, SDK `.deb` build |
| `opencv/` | OpenCV ≥ 4.7 + contrib `.deb` for bookworm |
| `drivers/mira220-sync/` | Mira220 master/slave driver + overlay (git submodule, pinned) |
| `libcamera/` | libcamera fork with Mira220 support → `unlook-libcamera` `.deb` |
| `tests/unit/` | A/B state machine, bundle hook, config loader (host, no root) |
| `tests/qemu/` | boot test of the OS layer on `qemu-system-aarch64 -M virt` |
| `unlook-sdk/` | the SDK, git submodule pinned to a commit of `main` |
| `branding/` | Supernova / Unlook boot splash artwork (optional) |

## 2. Build

Requirements: an arm64 Linux host (the Pi 5 CI runner is the reference) with
Docker, git, and for the bundle `rauc`; or x86-64 with `binfmt`/qemu-user for
pi-gen (slower).

```bash
git clone --recurse-submodules <gitlab>/unlook/unlook-os.git && cd unlook-os
scripts/dev-keys.sh                     # development keys in keys/dev (never ship)
scripts/build-sdk-deb.sh                # debs/libunlook-sdk-dev_<ver>_arm64.deb
opencv/build-deb.sh                     # bookworm only: debs/libopencv*.deb (≥ 4.7, aruco)
./build.sh rootfs                       # pi-gen → deploy/unlook-os-rootfs.tar
./build.sh image                        # deploy/unlook-os-<ver>.img.xz (+ slot images)
RAUC_SIGNING_CERT=keys/dev/rauc-signing.crt RAUC_SIGNING_KEY=keys/dev/rauc-signing.key \
  ./build.sh bundle                     # deploy/unlook-os-<ver>.raucb + deploy/latest
```

Versions: a tag `vYYYY.MM.N` builds release `YYYY.MM.N`; anything else is
`<UNLOOK_OS_VERSION>~dev.<time>.<sha>`, which sorts **below** the release, so a
dev bundle never "upgrades" past a release and the anti-rollback check holds.

Every build knob lives in `config/unlook-os.conf`; CI overrides any key with an
environment variable of the same name. Values are validated before use (the
file is proven assignment-only before it is sourced).

## 3. Disk layout

GPT, identical on SD cards and CM5 eMMC. Partition **numbers** are part of the
boot contract (`autoboot.txt`), labels are what everything else uses.

| # | PARTLABEL | FS | Size | Role |
| - | --- | --- | --- | --- |
| 1 | `unlook-cfg` | FAT32 | 64 MiB | `autoboot.txt`: tryboot A/B selector read by the firmware |
| 2 | `unlook-boot-a` | FAT32 | 256 MiB | `/boot/firmware` of slot A (kernel, DTBs, `config.txt`, `cmdline.txt`) |
| 3 | `unlook-boot-b` | FAT32 | 256 MiB | `/boot/firmware` of slot B |
| 4 | `unlook-root-a` | ext4 | 3.5 GiB | `/` slot A |
| 5 | `unlook-root-b` | ext4 | 3.5 GiB | `/` slot B (empty until the first OS update) |
| 6 | `unlook-data` | ext4 | rest | persistent data, grown to the end of the medium on first boot |

The data partition is mounted on `/data` and bind-mounted:

| Mount | Contents |
| --- | --- |
| `/etc/unlook` | `scanner_profile.yaml`, `audit.key`, `unit-id`, `os.conf` (per-unit OS overrides), `stream.env`, `ssh/` |
| `/var/lib/unlook` | `pairing.secret`, `hotspot.psk`, `cad/`, `reports/`, `scans/`, `unlook_calib/` (calibration: the daemon runs with `HOME=/var/lib/unlook`), `audit/`, `ota/` |
| `/var/log/journal` | persistent journal |
| `/var/lib/bluetooth` | BLE bonds (phones stay paired across OS updates) |

An OS update replaces a slot (boot + root partition) and never touches the
data partition. A factory reset = re-creating the data partition (§7.4).

## 4. Flash

**SD card / USB**: Raspberry Pi Imager → "Use custom" → `unlook-os-<ver>.img.xz`,
or `xzcat unlook-os-<ver>.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync`.
Do **not** use Imager's OS customisation (user, Wi-Fi, SSH): Unlook OS ignores
and disables it.

**CM5 eMMC**: put the carrier in USB boot mode (nRPIBOOT low), run `rpiboot`
(`usbboot`, mass-storage gadget) on the PC, then write the image to the
exposed disk as above. The EEPROM must support GPT and `tryboot_a_b` (every
CM5/Pi 5 bootloader release does); update it with `rpi-eeprom` before
production if in doubt.

## 5. First boot

`unlook-firstboot.service` runs once per data partition (marker
`/etc/unlook/.firstboot-done`):

1. grows `unlook-data` to the end of the medium (`growpart` + `resize2fs`);
2. if `/boot/firmware/unlook/scanner_profile.yaml` exists (≤ 64 KiB, regular
   file, no NUL), validates it **with the SDK's own loader** and installs it as
   `/etc/unlook/scanner_profile.yaml`; a rejected seed leaves the factory
   profile and is logged;
3. generates the per-unit audit key (`/etc/unlook/audit.key`, 32 random bytes,
   0400); `unlook-stream` gets `UNLOOK_AUDIT_LOG=/var/lib/unlook/audit/audit.log`
   and `UNLOOK_AUDIT_KEY_FILE` from its drop-in;
4. derives the unit id (`UNLK-` + last 6 hex digits of the board serial) and
   the pairing secret via `unlook_stream --pairing-code`, stores the unit id
   in `/etc/unlook/unit-id` and writes the pairing code **once** to the journal.

`unlook-identity.service` then sets the hostname to the unit id on every boot,
before the network comes up. Read the code for the label:

```bash
journalctl -t unlook-firstboot -g "pairing code"        # UNLOOK1:UNLK-1A2B3C:…
```

What runs afterwards: NetworkManager (hotspot on demand, driven by the SDK),
BlueZ in LE-only mode, `unlook-usb-gadget` (CDC-ACM `/dev/ttyGS0` + ECM `usb0`
at `10.43.0.1`, DHCP for the host), `unlook-stream` (5555 stream, 5556 UCP),
`nftables`, persistent `journald`, `unlook-health`.

**Every boot, phone-ready without any login**: `unlook-stream.service` is
enabled in the image (SDK postinst + stage `03-system`) and started after
BlueZ, NetworkManager and the USB gadget. Factory profile `net_mode: ble`:
the unit advertises `Unlook-<id>` over BLE, the phone authenticates with the
pairing code (label/QR), asks for the hotspot, receives the Wi-Fi credentials
and connects to the stream protocol (docs/PROVISIONING.md in the SDK). The
OS drop-in never lets a first-boot failure keep the daemon down (`Wants=`),
and `StartLimitIntervalSec=0` keeps restarting it for as long as it exits.

## 6. Updates

### 6.1 Two channels

| | `sdk` (fast, e.g. at a fair) | `os` (full) |
| --- | --- | --- |
| What | the SDK package only | the whole root filesystem + boot partition |
| Source | `SDK_OTA_SOURCE`: **`github` (current)** = latest commit of `SDK_GIT_BRANCH` (`main`) of the private SDK repo, fetched over SSH with the unit's read-only deploy key, **built on the unit** (same flags as CI) into a `.deb`; `apt` = signed repo `UNLOOK_APT_URL` (future Forgejo) | signed RAUC bundle, `UNLOOK_OTA_URL/<compatible>/latest` → bundle |
| Verification | github: SSH to GitHub with the host key pinned in the image + deploy key; commit GPG signature when `SDK_GIT_REQUIRE_SIGNED=1` (§9). apt: `Signed-By` keyring; pinning | CMS signature against `/etc/rauc/keyring.pem`, `compatible`, verity, anti-rollback hook |
| Downtime | daemon restart (seconds) | one reboot |
| Current state (no server yet — self-hosted Forgejo planned; `UNLOOK_APT_URL` / `UNLOOK_OTA_URL` empty) | `github` source active once the unit has its deploy key; without it `apply sdk` fails `not_configured` | `ota_check` reports `unconfigured`; only `apply os --bundle <file>` (USB stick, scp) |
| Safety net | health check; previous `.deb` from the local apt cache is reinstalled | A/B + firmware tryboot + health check + watchdog + guard |
| Limits | must not need new Debian dependencies (none are fetched); github: a build takes minutes on the CM5 and needs ~2 GB free on the root filesystem | none |

An SDK update installed by apt lives in the current slot; the next OS bundle
(which carries the SDK version it was built with) supersedes it. Release OS
bundles always embed the newest released SDK.

### 6.2 Starting an update

From the phone app or a robot/PLC (Unlook Command Protocol, once the SDK
implements docs/SDK_CHANGES.md §1):

```
#1 ota_check
#1 OK ota_check_queued
EV ota_check:0.1.0:0.1.1+git202610011200.ab12cd34ef:2026.10.0:2026.11.0:online
#2 ota_apply:sdk
#2 OK ota_apply_queued:sdk
EV ota_state:sdk:installing
EV ota_done:sdk:0.1.1+git202610011200.ab12cd34ef
#3 ota_status
#3 OK ota_status:done:sdk:100:0.1.1+git202610011200.ab12cd34ef:-
```

From a shell on the unit:

```bash
sudo unlook-ota check
sudo unlook-ota apply sdk
sudo unlook-ota apply os                         # from UNLOOK_OTA_URL
sudo unlook-ota apply os --bundle /data/unlook-os-2026.11.0.raucb   # offline (USB stick, scp)
sudo unlook-ota status ; sudo unlook-ota history
```

`apply` returns immediately and runs in `unlook-ota-apply@<channel>.service`
(it must survive the daemon restart); `journalctl -u 'unlook-ota-apply@*'`.

**Connectivity**: in `net_mode: ble` the unit's Wi-Fi is the hotspot for the
phone and has no upstream. The unit reaches the repositories over Ethernet,
a Wi-Fi client connection, or the USB-C link of a PC that shares its
connection; otherwise use `--bundle` with a file copied to the unit. (A phone
push of the bundle over the stream protocol is a possible SDK extension.)

### 6.3 A/B state machine (OS channel)

```
 default slot A ──apply os──► RAUC writes boot-b + root-b, hook retargets fstab/cmdline
                              backend set-primary B = arm [tryboot] only (default stays A)
                ──reboot "0 tryboot"──► firmware boots B once
                                         unlook-health --boot, deadline HEALTH_TIMEOUT_S (120 s):
                                           unlook-stream active AND `ping` → `OK pong` on :5556
                                  healthy ─► rauc mark-good → autoboot default = B  (COMMIT)
                                unhealthy ─► rauc mark-bad, reboot → firmware boots A (ROLLBACK)
          kernel panic / hang / watchdog ─► next boot is a normal boot → A          (ROLLBACK)
       user space wedged (no health run) ─► tryboot-guard reboots after TRYBOOT_GUARD_S (300 s)
              power lost before commit  ─► normal boot → A; health records `tryboot_failed`
```

The firmware's tryboot flag is one-shot, so an untested slot can never become
the default by accident: only `unlook-health` committing it does. Outcomes are
written to `/var/lib/unlook/ota/{last,history}` (data partition, visible from
both slots) and reported by `unlook-ota status` / `ota_status`.

On a **normal** boot of the committed slot an unhealthy daemon is logged and
`unlook-health.service` fails, but nothing is switched: there is no
known-better slot to go to, and a reboot loop would hide the fault.
Consequence: a unit with a hardware fault (e.g. a camera not answering)
cannot commit OS updates — they roll back. Bench units without cameras set
`HEALTH_TIMEOUT_S` high only for diagnosis; do not ship that.

### 6.4 SDK channel health

After `apt install`, `unlook-ota` restarts `unlook-stream` and runs
`unlook-health --wait`. Unhealthy within `HEALTH_TIMEOUT_S` → the previous
`.deb` (kept by `Keep-Downloaded-Packages`, seeded at image build) is
reinstalled with `dpkg -i`, status `rolled_back:health_timeout`.

## 7. Rollback and recovery by hand

1. **Go back to the other slot** (it must be good):
   ```bash
   sudo rauc status                         # which slot is booted / good
   sudo rauc status mark-active other       # arms a tryboot of the other slot
   sudo systemctl reboot "0 tryboot"        # health check commits it
   ```
2. **Downgrade** deliberately: `sudo unlook-ota apply os --bundle <older.raucb> --allow-downgrade`.
3. **Unit does not boot at all**: power-cycle — an uncommitted slot is never
   the default. If the committed slot itself is broken: flash the image again
   (§4); the data partition is recreated by the flash, so export
   `/etc/unlook` and `/var/lib/unlook` first if the unit is still reachable.
4. **Factory reset** (keep the OS): `sudo mkfs.ext4 -L unlook-data /dev/disk/by-partlabel/unlook-data`
   from a rescue shell, then restore the skeleton by re-flashing — or simply re-flash.

## 8. Production SD cards / eMMC

1. Build or download the release image (`unlook-os-<ver>.img.xz`, checksum in `.SHA256SUMS`).
2. Per batch/customer, prepare the seed on partition 2 (FAT volume
   `UNLOOKBOOT`, visible on Windows/macOS after flashing):
   ```
   unlook/scanner_profile.yaml     # validated at first boot; e.g. net_mode, gpio, baseline
   unlook/authorized_keys          # optional: service keys for unlook-admin (SSH stays off)
   unlook/ssh                      # optional, empty: enable SSH at first boot
   unlook/sdk-deploy-key           # GitHub read-only deploy key of unlook-sdk (SDK updates)
   ```
   `authorized_keys` and `ssh` are consumed (deleted) at boot; the profile
   seed stays so a factory reset re-applies it.
3. First power-on in the factory: wait for `unlook-health` (≈ 1 min), read the
   pairing code (`journalctl -t unlook-firstboot`, or `unlook_stream --pairing-code`
   over the UART console) and print the QR label (`qrencode -o label.png "<code>"`).
4. Calibrate (`calibrate` as root with `HOME=/var/lib/unlook`, or from the app);
   calibration files land on the data partition.
5. Record unit id ↔ serial ↔ OS version (`/etc/unlook-os-release`) in the
   production log.

## 9. Security

- **Signing**: RAUC bundles are CMS-signed (codeSigning EKU) with a key chained
  to the CA in `/etc/rauc/keyring.pem`; `bundle-formats=-plain` (verity only).
  The apt repository is signed with the key in
  `/usr/share/keyrings/unlook-archive-keyring.gpg`, referenced by `Signed-By`
  (no global trust). The OTA pointer (`latest`) is not trusted: it only picks
  a bundle, whose signature, `compatible` and version are checked before and
  during install; the install-check hook refuses anything not newer than the
  running OS unless `--allow-downgrade` is given on the unit.
- **Keys**: production CA + signing key and the apt key live offline / in the
  CI's protected file variables (or a PKCS#11 HSM: `RAUC_SIGNING_KEY` accepts a
  PKCS#11 URI). `keys/dev` is for development; images built with it say
  `KEYRING_KIND=dev` in `/etc/unlook-os-release` and in `unlook-ota status`.
  Key rotation = ship a bundle whose keyring contains old + new CA, then drop
  the old one in the following release.
- **SDK from GitHub (interim, `SDK_OTA_SOURCE=github`)**: the SDK repository is
  private; each unit (or batch) gets a **read-only deploy key** — create it on
  GitHub (repo → Settings → Deploy keys, "Allow write access" OFF), then either
  put the private key on the boot partition as `unlook/sdk-deploy-key`
  (consumed and deleted at boot by `unlook-ota-provision.service`) or run
  `sudo unlook-ota set-sdk-key <file>`. It lives in `/etc/unlook/sdk-git/`
  (data partition, 0600 root), never in the image. GitHub's SSH host keys are
  pinned (`/usr/share/unlook-os/github_known_hosts`). **Deviation**: until the
  signed apt channel exists, an SDK update is authenticated by the SSH
  transport and repository access, not by a signature on the code; set
  `SDK_GIT_REQUIRE_SIGNED=1` and put the trusted signers' public keys in
  `/usr/share/unlook-os/sdk-git-trust/*.asc` to require signed commits on the
  branch head. The build toolchain (gcc, cmake, git) is present in the image
  only for this channel.
- **Pinning**: the Unlook repo may only provide `libunlook-*`, `libopencv*`,
  `unlook-*` with priority; everything else from it is priority 100.
- **Network exposure**: nftables `inet unlook`, input policy drop. Open: TCP
  `FW_TCP_PORTS` (5555 stream, 5556 UCP), DHCP/DNS served by NetworkManager's
  shared mode to hotspot / USB-C clients (UDP 67, 53 / TCP 53 — dnsmasq binds
  only the shared interfaces), ICMP, and TCP 22 only while SSH is enabled.
  Forwarding: dropped. BLE is not IP. Removed: avahi, rpi-connect, userconf,
  modemmanager, swap; apt timers disabled; NetworkManager connectivity probes off.
- **SSH**: off by default. `sudo unlook-ssh add-key <file>` then
  `sudo unlook-ssh enable` (or the boot-partition seed, §8). Key-only, only
  `unlook-admin`, host key on the data partition. `unlook-ssh disable` closes it.
- **Accounts**: `root` and `unlook-admin` passwords are locked; console login
  is therefore impossible — the debug UART is a boot log, not a shell.
  `unlook-admin` has passwordless sudo (key-only access). `unlook` is the
  service user prepared for the daemon's least-privilege migration.
- **Logs**: persistent journal on `/data` (256 MiB cap, 6 months, compressed);
  SDK audit trail (HMAC-chained) with a per-unit key.
- **Known trade-offs** (owner decisions): the pairing code is written once to
  the journal (root/adm-readable only) as requested; `ota_apply` over UCP has
  no authentication of its own — it can only install content signed by the
  company, and UCP is reachable only on the WPA2 hotspot handed out after BLE
  pairing, on USB-C or on a LAN the customer controls; the audit key sits on
  the same medium as the log (tamper-evident against edits, not against an
  attacker with root).
- **Time**: TLS and certificate validity need a sane clock. The CM5 RTC keeps
  time with a backup battery; without it the clock starts at the last
  shutdown (`fake-hwclock`) until NTP (`systemd-timesyncd`) syncs.

## 10. Camera stack (Mira220 stereo, hardware sync)

| Layer | What the image carries |
| --- | --- |
| Kernel | stock Raspberry Pi kernel (`linux-image-rpi-2712` / `-v8`), **held** — it changes only with an OS bundle |
| Driver | `mira220-sync.ko` from [`drivers/mira220-sync`](../drivers/mira220-sync) (Supernova), built in stage `01-camera` against every kernel in the image, installed in `/lib/modules/<kver>/updates`. Compatible `ams,mira220-sync`, so the stock `mira220` never binds. `ams,trigger-mode`: 0 master (0x1003=0x10), 1 slave (0x1003=0x08, 0x1001=0xD1 = exposure from EXP_TIME, two-pin REQ_FRAME) |
| Device tree | `unlook-cam-enable.dtbo` + `mira220-sync.dtbo` (built with `dtc -@`). `config.txt`: `dtoverlay=unlook-cam-enable`, then `dtoverlay=mira220-sync,cam0` (CAM0 master) then `dtoverlay=mira220-sync,trigger-mode=1` (CAM1 slave), from `CAMERA_OVERLAYS` |
| Camera enable | [`overlays/unlook-cam-enable-overlay.dts`](../overlays/unlook-cam-enable-overlay.dts): `cam0_reg` and `cam1_reg` (the CAM_GPIO regulators: RP1 GPIO 34 on CM5, where `cam1_reg` is an alias of `cam0_reg`; expander GPIO 5 on CM4) are `regulator-always-on` + `regulator-boot-on`. The enable line is driven HIGH when the regulator registers at boot and never released — independent of probe order, runtime PM or the camera overlays. |
| I2C | camera buses enabled by the overlay (`i2c0if`, `i2c0mux`, `i2c_csi_dsi*`; on CM5 i2c-10 = CAM0, i2c-0 = CAM1 per the bench notes), `dtparam=i2c_arm=on` for AS1170/BMI270, `i2c-dev` loaded at boot so all buses are reachable from user space (`i2ctransfer`) |
| libcamera | the Raspberry Pi archive build has **no** Mira220 CamHelper → `unlook-libcamera` built from `ams-OSRAM/libcamera` (0.7.1, `/usr/local`, `LIBCAMERA_REPO`/`LIBCAMERA_REF`); as in `drivers/mira220-sync/README.md`: libcamera picks the CamHelper by substring (`mira220-sync` → `mira220` helper) but the tuning by exact name, so the stage links `mira220-sync.json` → `mira220.json` in `/usr/local/share/libcamera/ipa/rpi/{pisp,vc4}` (the driver exposes Bayer formats; the build fails if either link is missing) |
| Wiring | JST sync cable J6 (master) ↔ J4 (slave) carrying ILLUM_TRIGGER + FRAME_TRIGG; sync switches in position 2 |

Operational rule from the bench: the slave must be streaming **before** the
master starts, and the master must stop **after** the slave (otherwise the
slave waits for a trigger that never comes). The SDK's capture start order must
honour this (SDK_CHANGES §6).

Checks on a unit:
```bash
dmesg | grep -iE 'mira220|trigger mode|MASTER mode|SLAVE mode'
v4l2-ctl --list-devices
cat /sys/kernel/debug/regulator/regulator_summary | grep -i cam     # cam0_reg always on
i2ctransfer -f -y 10 w2@0x54 0x10 0x03 r1     # CAM0 0x1003 = 0x10 (master)
i2ctransfer -f -y 0  w2@0x54 0x10 0x03 r1     # CAM1 0x1003 = 0x08 (slave, while streaming)
```

## 11. Open items / decisions for the owner

1. **libcamera**: `ams-OSRAM/libcamera` `main` (0.7.1, pinned `d7d5e17`) is the
   one with `cam_helper_mira220` — the Raspberry Pi build cannot drive the
   sensor with any Mira220 driver. The SDK `.deb` must be built against the same
   `unlook-libcamera` build (C++ ABI).
   **ams `mira220_v4l2_driver`** (2026-08: startup-timing fix, optional reset
   GPIO, OTP calibration, slew-rate defect-line fix, mono): still master-only and
   uses `devm_v4l2_sensor_clk_get`, present in `rpi-6.18.y` but not in the
   bookworm kernel `rpi-6.12.y`. Port the `ams,trigger-mode` patch onto it when
   the base moves to a 6.18 kernel (trixie).
2. **bookworm vs trixie**: bookworm ships OpenCV 4.6, the SDK needs ≥ 4.7 →
   this repo builds OpenCV 4.10 as `.deb` (`opencv/`). Raspberry Pi OS trixie
   ships 4.10 natively but moves to sdbus-c++ 2 (SDK path written, not yet
   compiled). `UNLOOK_OS_SUITE` switches the base once the SDK is ready.
3. **Runtime-only SDK package** (SDK_CHANGES §4.5) to drop ~1 GB of `-dev`
   packages from the image.
4. Confirm camera overlay parameters (sync master/slave) on the production board.

## 12. CI

`.gitlab-ci.yml`: `lint` (shellcheck, nft syntax) → `test` (unit) → `build`
(SDK `.deb`; OpenCV on demand) → `image` (pi-gen + A/B image) → `bundle`
(RAUC, signed) → `verify` (QEMU boot test) → `publish` (tags only: apt
repository, bundle then `latest` pointer, via rsync to the NAS).

**CI runner** (Pi 5, arm64, shell executor): Raspberry Pi OS 64-bit with
`docker.io`, `qemu-system-arm`, `rauc`, `reprepro`, `rsync`, `git`,
build-essential + the SDK build dependencies, and OpenCV from this repo:
`opencv/build-deb.sh && sudo apt install ./debs/libopencv*.deb`, with the same
`.deb`s kept in `/var/cache/unlook-ci/opencv` (the image build ships them).
Register with tags `rpi, arm64`; pi-gen needs `docker run --privileged`.

## 13. Troubleshooting

| Symptom | Look at |
| --- | --- |
| update rolled back | `unlook-ota status`, `journalctl -b -1 -u unlook-health -u unlook-stream` (previous boot = the tried slot) |
| `ota_check … offline` | route to `UNLOOK_APT_URL` / `UNLOOK_OTA_URL`, clock (TLS), `/etc/unlook/os.conf` |
| no hostname / no pairing code | `journalctl -u unlook-firstboot` |
| USB-C link | `systemctl status unlook-usb-gadget`, `nmcli c show unlook-usb0`, host sees `/dev/ttyACM0` + a DHCP lease in `10.43.0.0/24` |
| firewall drops | `journalctl -k -g unlook-fw` |
