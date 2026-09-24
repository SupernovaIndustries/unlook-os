#!/bin/sh
# Host-side unit tests: RAUC tryboot backend state machine, bundle hook,
# build-config loader, first-boot network onboarding (Wi-Fi modes and fallback,
# credentials, per-unit SSH password). No hardware, no root (Linux host: GNU
# stat/flock). Run: tests/unit/run.sh
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
if [ -f "$T/run/unlook/ota/committed" ]; then ok "commit marker written"; else ko "commit marker written"; fi
if [ ! -f "$T/var/lib/unlook-ota/boot/pending" ]; then ok "pending cleared"; else ko "pending cleared"; fi

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
# shellcheck disable=SC2016 # the hostile values must stay literal
for bad in 'X=$(id)' 'X=`id`' 'X=a;id' 'X="$HOME"' 'id' 'X=a b'; do
    printf '%s\n' "$bad" > "$T/bad.conf"
    if (. "$TOP/scripts/lib.sh" && conf_load "$T/bad.conf") 2>/dev/null; then
        ko "rejects: $bad"; else ok "rejects: $bad"; fi
done
# shellcheck disable=SC2016 # a literal command substitution
if (GOOD='$(id)' && export GOOD && . "$TOP/scripts/lib.sh" && conf_load "$T/ok.conf") 2>/dev/null; then
    ko "rejects unsafe env override"; else ok "rejects unsafe env override"; fi
rm -rf "$T"

# ---- first-boot network onboarding (unlook-wifi, unlook-credentials, firstboot SSH) ----
SBIN="$TOP/stages/stage-unlook/overlay/usr/sbin"
# Stubs for the system commands; every call is logged in $S/calls.
# shellcheck disable=SC2016 # the stubs expand $STUB when they run
new_net_root() {
    T="$(mktemp -d)"
    S="$T/stub"
    mkdir -p "$S" "$T/etc/unlook/network" "$T/etc/NetworkManager/system-connections" "$T/etc/unlook-os"
    printf 'NET_AP_IFACE=wlan0\nNET_AP_ADDRESS=10.42.0.1/24\nNET_LAN_FALLBACK_S=30\nNET_SETUP_PORT=80\n' > "$T/etc/unlook-os/os.conf"
    : > "$S/calls"
    echo 1 > "$S/up.rc"
    echo -- > "$S/conn"
    cat > "$S/nmcli" << 'EOF'
#!/bin/sh
echo "nmcli $*" >> "$STUB/calls"
case "$*" in
    *"device wifi list"*) cat "$STUB/scan.out" 2>/dev/null ;;
    "-t -f DEVICE device") echo wlan0 ;;
    *"connection up unlook-wifi"*) exit "$(cat "$STUB/up.rc")" ;;
    *GENERAL.CONNECTION*) echo "GENERAL.CONNECTION:$(cat "$STUB/conn")" ;;
    *IP4.ADDRESS*) echo "IP4.ADDRESS[1]:192.168.1.50/24" ;;
esac
exit 0
EOF
    printf '#!/bin/sh\necho "systemctl $*" >> "$STUB/calls"\ncase "$1" in is-active) exit 1 ;; esac\nexit 0\n' > "$S/systemctl"
    printf '#!/bin/sh\necho "systemd-run $*" >> "$STUB/calls"\n' > "$S/systemd-run"
    printf '#!/bin/sh\nexit 0\n' > "$S/rfkill"
    chmod 0755 "$S"/*
}
wifi() {
    STUB="$S" PATH="$S:$PATH" UNLOOK_OS_TESTROOT="$T" UNLOOK_OS_LIBDIR="$LIBDIR" \
        UNLOOK_WIFI_SCAN_WAIT=0 UNLOOK_WIFI_APPLY_DELAY=0 UNLOOK_WIFI_POLL_S=0 sh "$SBIN/unlook-wifi" "$@" 2>/dev/null
}
netmode() { sed -n 's/^UNLOOK_NET_MODE=//p' "$T/run/unlook/net.env"; }
wstate() { sed -n 's/^state=//p' "$T/run/unlook/wifi/status"; }

echo "wifi: boot without a saved network"
new_net_root
printf '%s\n' '70:WPA2:Office' '40:WPA2:Office' '55:WPA3:Lab\:2' '30::Guest' '20:WPA2:' '90:WPA2 WPA3:Home Net' > "$S/scan.out"
wifi boot
eq "no Wi-Fi -> hotspot (ap)" "$(netmode)" ap
echo unlook-ap > "$S/conn"
: > "$S/calls"
wifi watch
if grep -q restart "$S/calls"; then ko "hotspot up: no restart"; else ok "hotspot up: no restart"; fi
echo -- > "$S/conn"
wifi watch
if grep -q '^systemctl restart unlook-stream' "$S/calls"; then ok "hotspot not up: daemon restarted once"; else ko "hotspot not up: daemon restarted once"; fi
eq "hotspot address passed to the daemon" "$(sed -n 's/^UNLOOK_AP_ADDRESS=//p' "$T/run/unlook/net.env")" 10.42.0.1/24
eq "scan: strongest first, deduplicated, hidden dropped" "$(cut -f3 "$T/run/unlook/wifi/scan.tsv" | tr '\n' '|')" "Home Net|Office|Lab:2|Guest|"
eq "scan: open network labelled" "$(awk -F '\t' '$3 == "Guest" { print $2 }' "$T/run/unlook/wifi/scan.tsv")" open

echo "wifi: set"
printf 'Office\npa ss\\word\n' | wifi set
K="$T/etc/unlook/network/unlook-wifi.nmconnection"
eq "keyfile saved on the data partition, 0600" "$(stat -c %a "$K" 2>/dev/null)" 600
eq "keyfile installed for NetworkManager" "$(cmp -s "$K" "$T/etc/NetworkManager/system-connections/unlook-wifi.nmconnection" && echo same)" same
eq "SSID as a byte list" "$(sed -n 's/^ssid=//p' "$K")" "79;102;102;105;99;101;"
eq "password escaped for GKeyFile" "$(sed -n 's/^psk=//p' "$K")" 'pa\sss\\word'
eq "WPA2 network -> wpa-psk" "$(sed -n 's/^key-mgmt=//p' "$K")" wpa-psk
if grep -q '^systemd-run .*unlook-wifi apply' "$S/calls"; then ok "switch handed to a transient unit"; else ko "switch handed to a transient unit"; fi
eq "state pending" "$(wstate)" pending
printf 'Lab:2\nsecret123\n' | wifi set
eq "WPA3-only network -> sae" "$(sed -n 's/^key-mgmt=//p' "$K")" sae
printf 'Guest\n\n' | wifi set
if grep -q '^\[wifi-security\]' "$K"; then ko "open network: no security section"; else ok "open network: no security section"; fi
before="$(cat "$K")"
for bad in "$(printf 'x%.0s' $(seq 33))|longpassword" "Office|short" "Office|$(printf 'z%.0s' $(seq 64))" "$(printf 'a\tb')|longpassword" "|longpassword"; do
    if printf '%s\n%s\n' "${bad%%|*}" "${bad#*|}" | wifi set; then ko "rejects: ${bad%%|*} / ${bad#*|}"; else ok "rejects invalid input (${#bad} chars)"; fi
done
eq "rejected input leaves the saved network" "$(cat "$K")" "$before"
rm -rf "$T"

echo "wifi: apply"
new_net_root
printf 'Office\nlongpassword\n' | wifi set
echo 0 > "$S/up.rc"
wifi apply
eq "connected -> ble (app can still raise the hotspot)" "$(netmode)" ble
eq "state connected" "$(wstate)" connected
if grep -q '^systemctl restart unlook-stream' "$S/calls"; then ok "daemon restarted in the new mode"; else ko "daemon restarted in the new mode"; fi
cp "$T/etc/unlook/network/unlook-wifi.nmconnection" "$T/good"
printf 'Other\nwrongpassword\n' | wifi set
echo 1 > "$S/up.rc"
if wifi apply; then ko "failed switch reports failure"; else ok "failed switch reports failure"; fi
eq "failed switch restores the previous network" "$(cmp -s "$T/good" "$T/etc/unlook/network/unlook-wifi.nmconnection" && echo same)" same
eq "state failed" "$(wstate)" failed
rm -rf "$T"
new_net_root
printf 'Office\nwrongpassword\n' | wifi set
if wifi apply; then ko "first switch failure"; else ok "first switch failure reported"; fi
if [ -e "$T/etc/unlook/network/unlook-wifi.nmconnection" ]; then ko "bad first network removed"; else ok "bad first network removed"; fi
eq "first switch failure -> hotspot back" "$(netmode)" ap
rm -rf "$T"

echo "wifi: boot with a saved network, fallback"
new_net_root
printf '[connection]\nid=preconfigured\ntype=wifi\n[wifi]\nmode=infrastructure\n' > "$T/etc/unlook/network/preconfigured.nmconnection"
wifi boot
eq "saved Wi-Fi -> ble" "$(netmode)" ble
echo unlook-ap > "$S/conn"
wifi watch
eq "phone on the hotspot: no fallback" "$(netmode)" ble
echo preconfigured > "$S/conn"
wifi watch
eq "Wi-Fi up: state connected" "$(wstate)" connected
echo -- > "$S/conn"
wifi watch
eq "Wi-Fi down past NET_LAN_FALLBACK_S -> hotspot" "$(netmode)" ap
eq "state fallback" "$(wstate)" fallback
if [ -f "$T/etc/unlook/network/preconfigured.nmconnection" ]; then ok "fallback keeps the saved network"; else ko "fallback keeps the saved network"; fi
printf '[connection]\nid=hotspot\ntype=wifi\n[wifi]\nmode=ap\n' > "$T/etc/unlook/network/ap.nmconnection"
wifi forget
if [ -e "$T/etc/unlook/network/preconfigured.nmconnection" ]; then ko "forget removes client networks"; else ok "forget removes client networks"; fi
if [ -e "$T/etc/unlook/network/ap.nmconnection" ]; then ok "forget leaves access-point profiles"; else ko "forget leaves access-point profiles"; fi
eq "forget -> hotspot" "$(netmode)" ap
rm -rf "$T"

echo "credentials"
new_net_root
mkdir -p "$T/etc/unlook/credentials" "$T/var/lib/unlook" "$T/etc/unlook/ssh"
echo UNLK-1A2B3C > "$T/etc/unlook/unit-id"
echo UNLK-1A2B3C > "$T/etc/hostname"
echo abcd-EFGH-2345-jkmn > "$T/etc/unlook/credentials/admin-password"
: > "$T/etc/unlook/ssh/enabled"
cred() { STUB="$S" PATH="$S:$PATH" UNLOOK_OS_TESTROOT="$T" UNLOOK_OS_LIBDIR="$LIBDIR" sh "$SBIN/unlook-credentials" "$@" 2>/dev/null; }
kvget() { cred --kv | sed -n "s/^$1=//p"; }
eq "hotspot SSID from the unit id" "$(kvget ssid)" Unlook-1A2B3C
eq "per-unit SSH password shown" "$(kvget password)" abcd-EFGH-2345-jkmn
eq "LAN name via mDNS" "$(kvget lan_name)" UNLK-1A2B3C.local
eq "setup page URL" "$(kvget setup_url)" http://10.42.0.1/
rm "$T/etc/unlook/credentials/admin-password"
# shellcheck disable=SC2016 # a literal crypt hash
echo '$6$x$y' > "$T/etc/unlook/credentials/admin-password-hash"
eq "changed password is not shown" "$(kvget password)" ""
eq "changed password: note" "$(kvget password_note)" "cambiata con unlook-ssh passwd"
echo 'hot spot pw' > "$T/var/lib/unlook/hotspot.psk"
mkdir -p "$T/cfg"
STUB="$S" PATH="$S:$PATH" UNLOOK_OS_TESTROOT="$T" UNLOOK_OS_LIBDIR="$LIBDIR" UNLOOK_CRED_WAIT_S=0 sh "$SBIN/unlook-credentials" write-cfg 2>/dev/null
if grep -q 'Password:  hot spot pw' "$T/cfg/unlook-credenziali.txt" 2>/dev/null; then ok "credentials file on the cfg partition"; else ko "credentials file on the cfg partition"; fi
rm -rf "$T"

echo "first boot: SSH on with a per-unit password"
fb_root() {
    T="$(mktemp -d)"
    mkdir -p "$T/etc/unlook-os" "$T/proc/device-tree"
    printf 'SSH_DEFAULT=on\n' > "$T/etc/unlook-os/os.conf"
    printf '10000000abcdef12\0' > "$T/proc/device-tree/serial-number"
}
fb() { PATH="/nonexistent-sdk:$PATH" UNLOOK_OS_TESTROOT="$T" UNLOOK_OS_LIBDIR="$LIBDIR" sh "$LIBDIR/unlook-firstboot" 2>/dev/null; }
if command -v openssl >/dev/null 2>&1 && ! command -v unlook_stream >/dev/null 2>&1; then
    fb_root
    fb
    pw="$(cat "$T/etc/unlook/credentials/admin-password" 2>/dev/null)"
    if printf '%s' "$pw" | grep -Eq '^[A-HJ-NP-Za-km-np-z2-9]{4}(-[A-HJ-NP-Za-km-np-z2-9]{4}){3}$'; then
        ok "password: 16 unambiguous characters"; else ko "password format ($pw)"; fi
    h="$(cat "$T/etc/unlook/credentials/admin-password-hash")"
    salt="$(printf '%s' "$h" | cut -d'$' -f3)"
    eq "hash matches the password" "$(printf '%s' "$pw" | openssl passwd -6 -salt "$salt" -stdin)" "$h"
    eq "secrets 0600" "$(stat -c %a "$T/etc/unlook/credentials/admin-password")$(stat -c %a "$T/etc/unlook/credentials/admin-password-hash")" 600600
    if [ -f "$T/etc/unlook/ssh/enabled" ] && [ -f "$T/etc/unlook/ssh/sshd.d/10-password.conf" ]; then
        ok "SSH enabled with password login"; else ko "SSH enabled with password login"; fi
    rm -rf "$T"
    fb_root
    fb
    pw2="$(cat "$T/etc/unlook/credentials/admin-password")"
    if [ "$pw" != "$pw2" ]; then ok "every unit gets a different password"; else ko "every unit gets a different password"; fi
    rm -rf "$T"
    fb_root
    mkdir -p "$T/etc/unlook/imager"
    # shellcheck disable=SC2016 # a literal crypt hash
    echo '$6$saltsalt$hashhashhashhashhash' > "$T/etc/unlook/imager/password-hash"
    fb
    if [ -e "$T/etc/unlook/credentials/admin-password" ]; then ko "Imager password wins"; else ok "Imager password wins (none generated)"; fi
    if [ -f "$T/etc/unlook/ssh/sshd.d/10-password.conf" ]; then ok "Imager password also valid for SSH"; else ko "Imager password also valid for SSH"; fi
    rm -rf "$T"
    fb_root
    printf 'SSH_DEFAULT=off\n' > "$T/etc/unlook-os/os.conf"
    fb
    if [ -e "$T/etc/unlook/ssh/enabled" ]; then ko "SSH_DEFAULT=off keeps SSH off"; else ok "SSH_DEFAULT=off keeps SSH off"; fi
    rm -rf "$T"
else
    echo "  skip first boot (needs openssl and no unlook_stream on this host)"
fi

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
