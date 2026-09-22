# Changes required in unlook-sdk for Unlook OS

> Scope: what the SDK (`unlook-sdk`, branch `main`, pinned here as the
> `unlook-sdk/` submodule) must change so the OS features work end to end.
> Each item names the files, the behaviour and the acceptance test. All of it
> falls under the SDK's own `CLAUDE.md` contract (Result<T>, Logger/AuditLogger,
> no hardcoded parameters, validated input, clang-tidy clean, Pi build).
> Nothing here touches the frozen modules (SgmCensus, CalibrationEngine).

Priority: **P0** = the OS image does not work without it; **P1** = a documented
OS feature is missing without it; **P2** = hardening / follow-up.

---

## 1. OTA commands in the unified dispatcher (P1)

The phone (stream protocol `ULKC`/`ULKE`) and robots/PLCs (UCP text on 5556 /
serial) start updates with the same commands, through
`ScannerBackend::executeCommand()` → `handleControl()`
(`src/sdk/scanner/ScannerBackend.cpp`). The SDK does **not** implement
updating: it drives the OS tool `unlook-ota` (this repository) and reports.

### 1.1 Commands

| Command | Behaviour | First reply |
| --- | --- | --- |
| `ota_check` | async job: runs `unlook-ota check --machine` (apt metadata refresh + OTA pointer, ≤ 60 s) | `OK ota_check_queued`, then `EV ota_check:…` |
| `ota_apply:sdk` | runs `unlook-ota apply sdk` (returns at once; the work runs in `unlook-ota-apply@sdk.service`) | `OK ota_apply_queued:sdk` / `ERR ota_busy` / `ERR scan_busy` |
| `ota_apply:os` | runs `unlook-ota apply os` (same, `unlook-ota-apply@os.service`; the unit reboots into the new slot when installed) | `OK ota_apply_queued:os` / `ERR ota_busy` / `ERR scan_busy` |
| `ota_status` | synchronous: reads `/run/unlook/ota/status` (falls back to `/var/lib/unlook/ota/last`) — **no exec** | `OK ota_status:<state>:<channel>:<progress>:<version>:<error>` |

Rules:
- `ota_apply:*` is refused with `ERR scan_busy` while any job (scan, inspect,
  multi-view, calibration) is queued or running, and while an apply is active
  new jobs are refused with `ERR ota_busy` (a scan during a reboot is lost).
- Arguments other than `sdk` / `os` → `ERR error:bad_argument`. No bundle
  path or URL is accepted from the protocol (the OS takes the source from its
  own configuration) — keeps the untrusted input surface at one enum.
- Profile key `ota_enabled` (default `true`, ENV `UNLOOK_OTA_ENABLED`): when
  `false` every `ota_*` returns `ERR error:not_supported:ota_disabled`.
- Profile key `ota_tool` (default `/usr/sbin/unlook-ota`, ENV
  `UNLOOK_OTA_TOOL`): validated as an absolute path, no `..`, regular file,
  owned by root, not group/world-writable (rule 8) — otherwise OTA is disabled
  and the reason logged.
- `help` lists the new commands; `version` unchanged (`ucp=1`: additive change).

### 1.2 Events (`EV` on UCP, `ULKE` on the stream)

| Event | When |
| --- | --- |
| `ota_check:<sdk_inst>:<sdk_avail\|->:<os_inst>:<os_avail\|->:<online\|offline\|unconfigured>` | end of `ota_check` (payload = the tool's `--machine` line) |
| `ota_started:<channel>` | the apply unit started |
| `ota_progress:<channel>:<0-100>` | progress changed (≥ 5 points or state change) |
| `ota_state:<channel>:<state>` | state changed: `checking downloading installing verifying rebooting installed` |
| `ota_done:<channel>:<version>` | `done` (SDK) / `committed` (OS, reported after the reboot) |
| `ota_error:<channel>:<reason>` | `failed` / `rolled_back` (reason: `not_configured repo_unreachable signature_invalid incompatible not_newer install_failed health_timeout tryboot_failed no_space checksum_mismatch download_failed`) |
| `ota_rebooting:os` | just before the reboot — clients should expect the link to drop |

Version strings are `[0-9A-Za-z.+~-]{1,64}` (no `:`; the OS never uses Debian
epochs). The SDK validates every field it forwards.

### 1.3 Implementation

- New component `transport::SystemUpdater` (or `sdk/scanner/OtaClient.{hpp,cpp}`):
  - `Result<std::string> run(const std::vector<std::string>& argv, std::chrono::seconds timeout)`
    — `fork` + `execv` with a **fixed argv** (never a shell), stdout captured
    (limit 4 KiB), stderr to the Logger, SIGKILL on timeout. Same pattern as
    `printQr()` / the nmcli calls.
  - `Result<OtaStatus> readStatus()` — parses the `key=value` status file
    (size limit 1 KiB, whitelisted keys, validated values).
  - A watcher thread (inotify on `/run/unlook/ota/`, 1 s poll fallback) that
    turns status changes into the events of §1.2 via `emitEvent()`.
- On startup the SDK reads `/var/lib/unlook/ota/last` once and, when it
  describes an OS result it has not reported yet (keyed by `updated=`), emits
  `ota_done`/`ota_error` so a phone that reconnects after the reboot learns
  the outcome.
- `AuditLogger` events: `OTA_CHECK`, `OTA_APPLY_REQUESTED{channel,client}`,
  `OTA_RESULT{channel,state,version,error}` (the last one also for the
  post-reboot result above, so commits and rollbacks are in the tamper-evident
  trail). `unlook-ota` itself only writes to the journal.
- `docs/COMMAND_PROTOCOL.md`: §3 table + §4 events; `README.md` command list.

### 1.4 Acceptance

- x86 unit tests with a fake `ota_tool` script (check output, busy refusal,
  bad argument, disabled, tool path validation, status parsing incl. garbage).
- Pi: `echo ota_check | nc 10.43.0.1 5556` over the USB gadget; `ota_apply:sdk`
  against a test repository; `ota_apply:os` with a dev bundle → reboot → the
  phone receives `ota_done:os:<version>` after reconnecting; a deliberately
  broken bundle (unlook-stream exits) → `ota_error:os:health_timeout`.

---

## 2. `unlook_stream --check-profile <file>` (P2)

`unlook-firstboot` currently validates the production profile seed by running
`unlook_stream <seed> --pairing-code` (the loader rejects invalid profiles and
the command needs no hardware). A dedicated `--check-profile` that only loads
and validates (`ScannerConfig::load`), prints the first error and exits 0/1 is
cleaner and avoids creating a pairing secret from a candidate profile.

## 3. Machine-readable `--pairing-code` (P2)

`unlook-firstboot` parses the `unit: …` / `pairing code: …` lines of
`unlook_stream --pairing-code`. Freeze that format (document it) or add
`--pairing-code --machine` printing exactly `UNLOOK1:<unit>:<secret>`.
Also: suppress the QR rendering when stdout is not a TTY (it ends up in the
first-boot journal otherwise).

## 4. Packaging (`CMakeLists.txt`, `packaging/`) (P0 / P1)

| # | Change | Why |
| --- | --- | --- |
| 4.1 **P0** | Install `unlook-stream.service` and `unlook-usb-gadget.service` into `/usr/lib/systemd/system` **whenever CPack builds the .deb**, independent of `CMAKE_INSTALL_PREFIX` (today only when the prefix is `/usr` or `UNLOOK_SDK_INSTALL_SYSTEMD=ON`). | The postinst runs `systemctl enable unlook-stream.service`; without the unit in the package it silently does nothing. `scripts/build-sdk-deb.sh` passes both flags as a workaround; the image build fails if the units are missing. |
| 4.2 **P0** | Package version: honour `CPACK_DEBIAN_PACKAGE_VERSION` (already works) and document the scheme `<project version>[+git<YYYYmmddHHMM>.<sha>]`; set `CPACK_DEBIAN_FILE_NAME DEB-DEFAULT`. | The apt channel only upgrades to a strictly greater version; every CI build must produce one. |
| 4.3 **P1** | Gadget script to `/usr/lib/unlook/unlook-usb-gadget.sh` (not `/usr/local/sbin`, which a package must not own) and update `ExecStart=`. Honour `UNLOOK_USB_ADDRESS` (already does). | Debian policy; the OS drop-in sets the address. |
| 4.4 **P1** | `Depends: libopencv-dev (>= 4.7)` (the calibration engine needs the 4.7 aruco API; bookworm's 4.6 must not satisfy it). | Prevents a silently broken install on stock bookworm. |
| 4.5 **P1** | Split runtime and development packages: `libunlook-sdk` (daemon, tools, shared libs, units; `Depends:` on runtime libs `libopencv-*410`, `libcamera0.*`, `libyaml-cpp0.7`, `libsdbus-c++1`, `libssl3`, …) and `libunlook-sdk-dev` (headers, CMake/pkg-config files, `Depends: libunlook-sdk (= ${binary:Version})` + the `-dev` packages). | The image carries ~1 GB of `-dev` packages (compilers' headers, OCCT dev) only because the single package depends on them. The OS then installs only `libunlook-sdk` (`SDK_PACKAGE` in `config/unlook-os.conf`). |
| 4.6 **P1** | postinst: `systemctl restart` only when the unit was already running (`deb-systemd-invoke try-restart`), never during image builds (`[ -d /run/systemd/system ]`). | Clean chroot installs; the OS OTA tool restarts and health-checks explicitly. |
| 4.7 **P2** | Ship `/usr/share/unlook/packaging/unlook.conf` → keep, but also install it directly as `/etc/bluetooth/main.conf.d/unlook.conf` as a `conffile`. | dpkg then tracks it instead of the postinst copying it once. |

## 5. Least privilege for the daemon (P2)

Today `unlook-stream` runs as root (nmcli hotspot, BlueZ GATT registration,
`/dev/i2c-*`, GPIO). The OS already creates the `unlook` service user (groups
`video i2c gpio bluetooth netdev dialout`). To switch `User=unlook`:
- NetworkManager: a polkit rule for `org.freedesktop.NetworkManager.*` scoped
  to the `unlook` user (shipped by the OS).
- BlueZ: D-Bus policy allowing `unlook` to register the GATT application and
  the agent (`/etc/dbus-1/system.d/unlook.conf`).
- `/dev/i2c-*`, `/dev/gpiochip*`, `/dev/video*`, `/dev/media*`, `/dev/ttyGS0`,
  `/dev/ttyAMA0` via the groups above.
- `ota_apply` through `systemctl start unlook-ota-apply@…` then needs a polkit
  rule for exactly those two units.
- Then `ProtectSystem=strict`, `ReadWritePaths=/var/lib/unlook /etc/unlook`,
  `CapabilityBoundingSet=` empty, `SystemCallFilter=@system-service`.

## 6. Camera stack the SDK runs on (P0, verify in the SDK)

The OS provides (docs/OS.md §10): `mira220-sync.ko` (CAM0 master,
CAM1 slave via `ams,trigger-mode`), the CAM_GPIO rail always on, all camera
I2C buses + `i2c-dev`, and `unlook-libcamera` (ams fork 0.7.1, `/usr/local`).
What the SDK must guarantee:

- **Build against `unlook-libcamera`** (same commit as the image): the SDK
  `.deb` links libcamera's C++ API; `scripts/build-sdk-deb.sh` runs on a host
  with that package installed. Its `Depends:` must accept `libcamera-dev`
  (provided by `unlook-libcamera`).
- **Start/stop order**: the slave (CAM1) must be streaming before the master
  (CAM0) starts, and must stop before the master stops — otherwise the slave
  waits for a trigger that never comes (bench rule from `mira220-sync`).
  `HardwareSyncCapture` must enforce it and time out with a clear error
  (`camera_sync_timeout`) instead of hanging.
- **Camera identity by port, not by enumeration order**: CAM0 = master; map to
  left/right with the profile's `master_is_right`, never by libcamera index.
- **Sensor name**: libcamera reports the sensor as `mira220-sync`; the
  profile's `sensor_model: auto` detection (`src/core/ScannerProfile.cpp`,
  looks for `mira220` in the device tree `compatible`) matches
  `ams,mira220-sync` — keep it that way (substring match).
- **Exposure in slave mode** comes from EXP_TIME (0x1001 = 0xD1), so AEC works;
  for metrology both cameras should run fixed, identical shutter/gain.
- AS1170 / BMI270 stay user-space over i2c-dev (`dtparam=i2c_arm=on`); no
  kernel driver may bind address 0x32 / 0x68 on that bus.

## 7. Documentation / tracking in the SDK

- `docs/COMMAND_PROTOCOL.md` §3/§4 (OTA), §7 (boot worker under Unlook OS:
  paths `/etc/unlook`, `/var/lib/unlook`, `HOME=/var/lib/unlook` for
  calibration, audit log enabled).
- `docs/REFACTOR_PLAN.md`: a phase "OS integration" with the items above as
  checkboxes (Definition of Done of the SDK contract).
