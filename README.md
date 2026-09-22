<p align="center"><img src="branding/assets/logo.png" alt="Supernova Industries" width="220"></p>

# Unlook OS

Appliance image for the **Unlook 3D scanner** (Raspberry Pi CM5) by Supernova
Industries: Raspberry Pi OS Lite 64-bit (bookworm) built with pi-gen, the
[`unlook-sdk`](unlook-sdk/) daemon as its only application, A/B system
updates with signed RAUC bundles and automatic rollback, and a fast, signed
apt channel for SDK-only updates.

- Boot straight into `unlook-stream` (BLE pairing, hotspot on demand, stream
  protocol 5555, command protocol 5556, USB-C gadget serial + Ethernet, UART).
- GPT A/B layout with firmware `tryboot`: a new OS is committed only after the
  daemon answers `ping` within 120 s; otherwise the unit is back on the
  previous slot automatically.
- Persistent data partition for profile, pairing secret, calibration, CAD,
  reports, scans, BLE bonds and the journal.
- Updates start from the phone/robot (`ota_check`, `ota_apply:<sdk|os>`,
  `ota_status`) or from `unlook-ota` on the unit.
- Closed by default: nftables, SSH off (key-only when enabled), locked
  passwords, persistent journal, SDK audit log with a per-unit key.

```bash
git clone --recurse-submodules <gitlab>/unlook/unlook-os.git && cd unlook-os
scripts/dev-keys.sh && scripts/build-sdk-deb.sh && opencv/build-deb.sh
./build.sh all            # → deploy/unlook-os-<ver>.img.xz + .raucb
sh tests/unit/run.sh      # A/B state machine, bundle hook, config loader
```

Documentation: **[docs/OS.md](docs/OS.md)** (build, layout, flash, first boot,
updates, rollback, production, security, CI) ·
[docs/SDK_CHANGES.md](docs/SDK_CHANGES.md) (what the SDK must add: `ota_*`
commands, packaging) · [branding/README.md](branding/README.md) (boot splash).

Engineering contract: [CLAUDE.md](CLAUDE.md).

© Supernova Industries. All rights reserved.
