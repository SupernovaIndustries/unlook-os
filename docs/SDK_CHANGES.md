# unlook-sdk ↔ Unlook OS interface — status

> The OS side lives here; SDK work happens in the SDK repository under its own
> `CLAUDE.md`. This file tracks what the OS needs from the SDK and what is
> done. Pinned SDK: `unlook-sdk/` submodule, `main` @ `d56c840`
> (PR #3 "Unlook OS integration").

## Done in the SDK (PR #3)

| Item | SDK contract | OS side |
| --- | --- | --- |
| OTA commands `ota_check`, `ota_apply:sdk\|os`, `ota_status` + events `ota_*` | COMMAND_PROTOCOL.md §3/§4; `OtaClient` execs `unlook-ota check --machine` / `apply <ch>` (fixed argv), reads `/run/unlook/ota/status` + `UNLOOK_OTA_LAST` | `unlook-ota` output formats match; states limited to `checking downloading installing verifying rebooting installed done committed failed rolled_back` (the GitHub build reports as `installing`); `UNLOOK_OTA_LAST=/var/lib/unlook-ota/last` set by the drop-in |
| Control plane without cameras | BLE / hotspot / stream / UCP first, cameras retried (`camera_retry_ms`); `status` has `camera=ok\|init\|off\|error:…`; `ERR camera_unavailable` | `unlook-health` requires `ping` → `OK pong` **and** `status` → `camera=ok` |
| `--check-profile`, `--pairing-code --machine` | COMMAND_PROTOCOL.md §7 | used by `unlook-firstboot` |
| Package split | `libunlook-sdk` (runtime, units, gadget helper in `/usr/lib/unlook`, BlueZ conffile) + `libunlook-sdk-dev` | image installs the runtime; `-dev` only with `SDK_OTA_SOURCE=github`; rollback restores both |
| Units generated for the real prefix; postinst never starts anything in a chroot, `try-restart` only | §7 | image build checks the unit is enabled |

## Open — SDK side

1. **Camera start order default** (owner requirement, **P0**): the order must be
   **MASTER first, then SLAVE** (stop in reverse). PR #3 made `camera_start_order`
   default to `slave_first` (from an earlier, wrong note in this file). Set the
   SDK default back to `master_first`. Until then the OS forces it:
   `Environment=UNLOOK_CAMERA_START_ORDER=master_first` in the unlook-stream
   drop-in (config `CAMERA_START_ORDER`), which overrides any profile.
2. **Non-root daemon** (P2): the OS now ships everything the daemon needs as
   the service user — polkit rules (`/etc/polkit-1/rules.d/49-unlook.rules`:
   the NetworkManager actions for the hotspot, and starting exactly
   `unlook-ota-check.service`, `unlook-ota-apply@sdk.service`,
   `unlook-ota-apply@os.service`), D-Bus policy (`/etc/dbus-1/system.d/unlook.conf`:
   `org.bluez`, NetworkManager), groups (`video i2c gpio bluetooth netdev dialout`),
   read access to `audit.key` and `/var/lib/unlook-ota`, and a non-root path in
   `unlook-ota` for the three protocol operations. Switch with
   `SDK_DAEMON_USER=unlook` in `config/unlook-os.conf` after the SDK is
   verified on the Pi as that user (BLE GATT registration, nmcli hotspot,
   `/dev/i2c-*`, `/dev/gpiochip*`, libcamera `/dev/dma_heap`, `/dev/ttyGS0`,
   `/dev/ttyAMA0`). Then `ProtectSystem=strict` + `ReadWritePaths=` can follow.
3. **Pi verification** (docs/TODO.md §A in the SDK): OTA end to end on a unit
   (`ota_apply:sdk` from GitHub, `ota_apply:os` with a dev bundle → reboot →
   `ota_done:os`), camera-less boot (phone pairs with the cameras unplugged,
   `camera_ready` after plugging), start order master → slave with the sync
   cable.

## Camera stack the SDK runs on (reference)

The OS provides (docs/OS.md §10): `mira220-sync.ko` (CAM0 master, CAM1 slave
via `ams,trigger-mode`), the CAM_GPIO regulators always on
(`unlook-cam-enable` overlay), all camera I2C buses + `i2c-dev`, and
`unlook-libcamera` (ams fork 0.7.1 in `/usr/local`, `mira220-sync.json` →
`mira220.json`). The SDK `.deb` must be built against that same
`unlook-libcamera` build (C++ ABI). AS1170 / BMI270 stay user-space over
i2c-dev (`dtparam=i2c_arm=on`).
