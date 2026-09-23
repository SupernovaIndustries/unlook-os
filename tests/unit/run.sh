#!/bin/sh
# Host-side unit tests: RAUC tryboot backend state machine, bundle hook,
# build-config loader. No hardware, no root. Run: tests/unit/run.sh
set -eu
TOP="$(cd "$(dirname "$0")/../.." && pwd)"
LIBDIR="$TOP/stages/stage-unlook/overlay/usr/lib/unlook-os"
BACKEND="$LIBDIR/rauc-tryboot-backend"
HOOK="$TOP/rauc/hook.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (expected '$3', got '$2')"; fi; }

new_root() {
    T="$(mktemp -d)"
    mkdir -p "$T/proc/device-tree/chosen/bootloader" "$T/cfg" "$T/etc/unlook-os" "$T/var/lib/unlook-ota" "$T/run/unlook/ota"
    printf '[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=3\n' > "$T/cfg/autoboot.txt"
    printf 'BOOT_A_PARTNUM=2\nBOOT_B_PARTNUM=3\n' > "$T/etc/unlook-os/os.conf"
    boot A 0
}
# boot <slot> <tryboot 0|1>
boot() {
    echo "console=serial0,115200 root=PARTLABEL=unlook-root-x rauc.slot=$1 panic=10" > "$T/proc/cmdline"
    if [ "$2" = 1 ]; then printf '\000\000\000\001' > "$T/proc/device-tree/chosen/bootloader/tryboot"
    else printf '\000\000\000\000' > "$T/proc/device-tree/chosen/bootloader/tryboot"; fi
}
be() { UNLOOK_OS_TESTROOT="$T" UNLOOK_OS_LIBDIR="$LIBDIR" sh "$BACKEND" "$@" 2>/dev/null; }
default_part() { awk '/^\[all\]/{s=1;next} /^\[/{s=0} s && /^boot_partition=/{sub(/.*=/,"");print}' "$T/cfg/autoboot.txt"; }
tryboot_part() { awk '/^\[tryboot\]/{s=1;next} /^\[/{s=0} s && /^boot_partition=/{sub(/.*=/,"");print}' "$T/cfg/autoboot.txt"; }

echo "tryboot backend"
new_root
eq "factory: primary A" "$(be get-primary)" A
eq "factory: current A" "$(be get-current)" A
eq "factory: B good" "$(be get-state B)" good

be set-state B bad
be set-primary B
eq "install B: primary B (pending)" "$(be get-primary)" B
eq "install B: default stays p2" "$(default_part)" 2
eq "install B: tryboot is p3" "$(tryboot_part)" 3
eq "install B: B no longer bad" "$(be get-state B)" good

boot B 1
be set-state B good
eq "tryboot B healthy: default p3" "$(default_part)" 3
eq "tryboot B healthy: tryboot p2" "$(tryboot_part)" 2
eq "tryboot B healthy: primary B" "$(be get-primary)" B
[ -f "$T/run/unlook/ota/committed" ] && ok "commit marker written" || ko "commit marker written"
[ ! -f "$T/var/lib/unlook-ota/boot/pending" ] && ok "pending cleared" || ko "pending cleared"

boot B 0
be set-state B good
eq "normal boot B: default unchanged" "$(default_part)" 3
rm -rf "$T"

echo "rollback"
new_root
be set-primary B
boot A 0 # the tryboot died (panic / watchdog / guard): firmware booted A normally
be set-state B bad
eq "rollback: primary A" "$(be get-primary)" A
eq "rollback: B bad" "$(be get-state B)" bad
eq "rollback: default still p2" "$(default_part)" 2
boot B 1 # stale tryboot flag must not commit a slot that is not the one tried
be set-state A good
eq "no commit of a non-booted slot" "$(default_part)" 2
if be set-primary C; then ko "invalid slot rejected"; else ok "invalid slot rejected"; fi
if be set-state A maybe; then ko "invalid state rejected"; else ok "invalid state rejected"; fi
rm -rf "$T"

echo "bundle hook"
T="$(mktemp -d)"
mkdir -p "$T/mp/etc" "$T/etc"
printf 'console=serial0,115200 root=PARTLABEL=unlook-root-a rootfstype=ext4 rauc.slot=A panic=10\n' > "$T/mp/cmdline.txt"
UNLOOK_OS_TESTROOT="$T" RAUC_SLOT_MOUNT_POINT="$T/mp" RAUC_SLOT_NAME=bootfs.1 RAUC_SLOT_CLASS=bootfs \
    sh "$HOOK" slot-post-install 2>/dev/null
eq "bootfs.1 cmdline" "$(cat "$T/mp/cmdline.txt")" \
    "console=serial0,115200 root=PARTLABEL=unlook-root-b rootfstype=ext4 rauc.slot=B panic=10"
printf 'PARTLABEL=unlook-root-a  /  ext4 x 0 1\nPARTLABEL=unlook-boot-a  /boot/firmware  vfat x 0 2\nPARTLABEL=unlook-data  /data  ext4 x 0 2\n' > "$T/mp/etc/fstab"
echo 0123456789abcdef0123456789abcdef > "$T/etc/machine-id"
UNLOOK_OS_TESTROOT="$T" RAUC_SLOT_MOUNT_POINT="$T/mp" RAUC_SLOT_NAME=rootfs.1 RAUC_SLOT_CLASS=rootfs \
    sh "$HOOK" slot-post-install 2>/dev/null
eq "rootfs.1 fstab root" "$(grep -c '^PARTLABEL=unlook-root-b ' "$T/mp/etc/fstab")" 1
eq "rootfs.1 fstab boot" "$(grep -c '^PARTLABEL=unlook-boot-b ' "$T/mp/etc/fstab")" 1
eq "rootfs.1 data untouched" "$(grep -c '^PARTLABEL=unlook-data ' "$T/mp/etc/fstab")" 1
eq "machine-id carried" "$(cat "$T/mp/etc/machine-id")" 0123456789abcdef0123456789abcdef
if command -v dpkg >/dev/null 2>&1; then
    echo 'VERSION=2026.10.0' > "$T/etc/unlook-os-release"
    if UNLOOK_OS_TESTROOT="$T" RAUC_MF_VERSION=2026.09.0 sh "$HOOK" install-check 2>/dev/null; then
        ko "downgrade refused"; else ok "downgrade refused"; fi
    if UNLOOK_OS_TESTROOT="$T" RAUC_MF_VERSION=2026.10.0~dev.1 sh "$HOOK" install-check 2>/dev/null; then
        ko "dev build below release refused"; else ok "dev build below release refused"; fi
    if UNLOOK_OS_TESTROOT="$T" RAUC_MF_VERSION=2026.11.0 sh "$HOOK" install-check 2>/dev/null; then
        ok "upgrade accepted"; else ko "upgrade accepted"; fi
    mkdir -p "$T/run/unlook/ota" && : > "$T/run/unlook/ota/allow-downgrade"
    if UNLOOK_OS_TESTROOT="$T" RAUC_MF_VERSION=2026.09.0 sh "$HOOK" install-check 2>/dev/null; then
        ok "explicit downgrade accepted"; else ko "explicit downgrade accepted"; fi
else
    echo "  skip install-check (no dpkg on this host)"
fi
rm -rf "$T"

echo "build config loader"
T="$(mktemp -d)"
printf 'GOOD=1\nQUOTED="a b"\n' > "$T/ok.conf"
if (. "$TOP/scripts/lib.sh" && conf_load "$T/ok.conf" && [ "$QUOTED" = "a b" ]) 2>/dev/null; then
    ok "plain config accepted"; else ko "plain config accepted"; fi
for bad in 'X=$(id)' 'X=`id`' 'X=a;id' 'X="$HOME"' 'id' 'X=a b'; do
    printf '%s\n' "$bad" > "$T/bad.conf"
    if (. "$TOP/scripts/lib.sh" && conf_load "$T/bad.conf") 2>/dev/null; then
        ko "rejects: $bad"; else ok "rejects: $bad"; fi
done
if (GOOD='$(id)' && export GOOD && . "$TOP/scripts/lib.sh" && conf_load "$T/ok.conf") 2>/dev/null; then
    ko "rejects unsafe env override"; else ok "rejects unsafe env override"; fi
rm -rf "$T"

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
