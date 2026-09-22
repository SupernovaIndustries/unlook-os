# CLAUDE.md — Unlook OS engineering contract

> Operating contract for any change to this repository, by Claude Code or a
> human. Read-only / protected: modified **only** when the repository owner
> explicitly asks. Same bar as the SDK: safety-critical supplier grade —
> fail-safe, auditable, deterministic, no undefined behaviour.

## What this is
`unlook-os` builds the appliance image of the Unlook scanner (Raspberry Pi CM5):
pi-gen stage, A/B disk image, RAUC bundles, signed apt repository, the unit's
update / health / provisioning tools. The SDK is a pinned git submodule
(`unlook-sdk/`) with its own contract; this repo never patches it — SDK needs
go to `docs/SDK_CHANGES.md` and are done in the SDK repository.

## Read before changing anything
- [docs/OS.md](docs/OS.md) — layout, boot and update state machine, security model.
- [docs/SDK_CHANGES.md](docs/SDK_CHANGES.md) — the OS ↔ SDK interface.

## Non-negotiable rules

1. **An update can never brick a unit.** Every OS change keeps the chain:
   one-shot firmware tryboot → `unlook-health` commit → otherwise previous slot.
   Changes to `rauc-tryboot-backend`, `unlook-health`, `tryboot-guard`,
   `rauc/hook.sh`, `image/mkimage.sh` or the partition layout need a unit test
   in `tests/unit/` and a Pi test of commit **and** rollback.
2. **Everything installed is signed and verified before use**: RAUC bundles
   (CMS, verity, keyring), apt (`Signed-By`), no `--allow-unauthenticated`, no
   unsigned fallback. Private keys never enter the repository.
3. **Closed by default**: no new listening service, open port, enabled
   remote-access agent or password login without an owner decision recorded
   in docs/OS.md §9.
4. **No hardcoded physical or deployment parameters** in scripts: overlays,
   buses, ports, addresses, sizes, URLs, users live in `config/unlook-os.conf`
   (build) or `/etc/unlook-os/os.conf` + `/etc/unlook/os.conf` (runtime).
5. **All input is untrusted** — build config and env overrides, boot-partition
   seeds, `/etc/unlook/*`, the OTA pointer, network responses: validated
   (whitelists, regexes, sizes, no path traversal) before use; config files
   are parsed, never blindly sourced.
6. **Shell discipline**: POSIX `sh` with `set -eu` (bash only where noted),
   shellcheck clean, quoted expansions, no `eval` of external data, atomic
   writes (temp + rename) for state, fixed argv for privileged calls.
7. **Every file shipped in the image is declared** in `overlay.manifest` with
   its mode; stage scripts fail the build rather than ship a degraded image.
8. **Data partition is sacred**: nothing in an OS update writes to it except
   through the documented tools; slot-specific state never goes there.
9. **Deterministic and traceable builds**: pinned pi-gen commit for releases,
   SDK pinned by submodule, versions from tags, package manifest per image,
   `/etc/unlook-os-release` records every input.

## Definition of Done (every change)
- `sh tests/unit/run.sh` green; shellcheck clean on touched scripts.
- Image built and booted on a CM5 for anything that touches boot, update or
  first-boot paths (QEMU alone is not sufficient); commit and rollback tested
  when the update chain is touched.
- docs/OS.md updated; SDK-side needs recorded in docs/SDK_CHANGES.md.

## Protected files
`CLAUDE.md` (this file). Enforced via `.claude/settings.json`.
