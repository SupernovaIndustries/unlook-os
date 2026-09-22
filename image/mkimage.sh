#!/bin/sh
# Assemble the Unlook OS A/B disk image from the pi-gen rootfs tarball.
#
#   image/mkimage.sh <rootfs.tar> <outdir>
#
# GPT layout (docs/OS.md §3). Partition NUMBERS are part of the boot contract
# (autoboot.txt boot_partition=) and of the RAUC tryboot backend: do not reorder.
#
#   #  PARTLABEL          fs     size            mount / role
#   1  unlook-cfg         vfat   PART_CFG_MB     autoboot.txt (tryboot A/B selector)
#   2  unlook-boot-a      vfat   PART_BOOT_MB    /boot/firmware when slot A runs
#   3  unlook-boot-b      vfat   PART_BOOT_MB    /boot/firmware when slot B runs
#   4  unlook-root-a      ext4   PART_ROOT_MB    / (slot A)
#   5  unlook-root-b      ext4   PART_ROOT_MB    / (slot B, empty until the first OS update)
#   6  unlook-data        ext4   PART_DATA_MB+   /data -> /etc/unlook, /var/lib/unlook, journal, BT bonds
#
# Pure file operations: no loop devices, no mounts, no privileges beyond root
# ownership of the extracted tree (run as root in a container).
# Outputs: <img>-<ver>.img.xz, <img>-<ver>.rootfs.ext4, <img>-<ver>.bootfs.vfat, SHA256SUMS.
set -eu

TOP="$(cd "$(dirname "$0")/.." && pwd)"
. "$TOP/scripts/lib.sh"
conf_load "$TOP/config/unlook-os.conf"
[ -n "${UNLOOK_OS_VERSION:-}" ] || die "UNLOOK_OS_VERSION unset"
conf_validate

TAR="${1:?rootfs tar}"
OUT="${2:?outdir}"
[ "$(id -u)" -eq 0 ] || die "run as root (ownership of the rootfs must be preserved)"
: "${SOURCE_DATE_EPOCH:=$(date +%s)}"
export E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
R="$W/rootfs"
B="$W/bootfs"
D="$W/data"
mkdir -p "$R" "$B" "$D"

log "extracting rootfs"
tar -C "$R" --numeric-owner --xattrs --xattrs-include='*' -xpf "$TAR"
[ -d "$R/boot/firmware" ] || die "rootfs has no /boot/firmware"

# ---- boot partition contents (slot A) ---------------------------------------
cp -a "$R/boot/firmware/." "$B/"
find "$R/boot/firmware" -mindepth 1 -delete
TEMPLATE="$R/usr/lib/unlook-os/cmdline.txt.in"
[ -f "$TEMPLATE" ] || die "missing $TEMPLATE (stage 03-system)"
sed -e 's/@ROOT_PARTLABEL@/unlook-root-a/g' -e 's/@SLOT@/A/g' "$TEMPLATE" | tr -d '\n' > "$B/cmdline.txt"
printf '\n' >> "$B/cmdline.txt"
grep -q 'root=PARTLABEL=unlook-root-a' "$B/cmdline.txt" || die "cmdline.txt rendering failed"
grep -q 'rauc.slot=A' "$B/cmdline.txt" || die "cmdline.txt has no rauc.slot"

# ---- data partition skeleton ------------------------------------------------
# What the packages installed into /etc/unlook and /var/lib/unlook becomes the
# factory content of the data partition; the rootfs keeps empty mount points.
install -d -m 0755 "$D/unlook" "$D/unlook/etc"
install -d -m 0700 "$D/unlook/var"
install -d -m 2755 "$D/journal"
install -d -m 0700 "$D/bluetooth" "$D/rauc"
cp -a "$R/etc/unlook/." "$D/unlook/etc/" 2>/dev/null || true
cp -a "$R/var/lib/unlook/." "$D/unlook/var/" 2>/dev/null || true
chmod 0700 "$D/unlook/var"
find "$R/etc/unlook" "$R/var/lib/unlook" -mindepth 1 -delete 2>/dev/null || true
# Keep the rootfs' systemd-journal gid on the persistent journal directory.
if [ -d "$R/var/log/journal" ]; then
    chgrp --reference="$R/var/log/journal" "$D/journal" 2>/dev/null || true
fi
install -d "$R/data" "$R/boot/firmware" "$R/boot/cfg"

# ---- autoboot selector ------------------------------------------------------
cat > "$W/autoboot.txt" <<'EOF'
[all]
tryboot_a_b=1
boot_partition=2
[tryboot]
boot_partition=3
EOF

# ---- filesystem images ------------------------------------------------------
V="$UNLOOK_OS_VERSION"
BASE="$OUT/${IMG_NAME}-${V}"
uuid_from() { printf '%s' "$1$SOURCE_DATE_EPOCH" | sha256sum | sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12}).*/\1-\2-4\3-8\4-\5/'; }

log "rootfs.ext4 (${PART_ROOT_MB} MiB)"
rm -f "$BASE.rootfs.ext4"
mkfs.ext4 -q -F -L unlook-root -U "$(uuid_from root)" -E "hash_seed=$(uuid_from seed)" \
    -d "$R" "$BASE.rootfs.ext4" "${PART_ROOT_MB}M"

log "bootfs.vfat (${PART_BOOT_MB} MiB)"
rm -f "$BASE.bootfs.vfat"
mkfs.vfat -C -F 32 -n UNLOOKBOOT -i 554c4b42 "$BASE.bootfs.vfat" $((PART_BOOT_MB * 1024)) >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -s -p -m -i "$BASE.bootfs.vfat" "$B"/* ::/

mkfs.vfat -C -F 32 -n UNLOOKCFG -i 554c4b43 "$W/cfg.vfat" $((PART_CFG_MB * 1024)) >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -i "$W/cfg.vfat" "$W/autoboot.txt" ::/autoboot.txt

mkfs.ext4 -q -F -L unlook-data -U "$(uuid_from data)" -d "$D" "$W/data.ext4" "${PART_DATA_MB}M"

# ---- GPT image --------------------------------------------------------------
MIB=1048576
S1=1
S2=$((S1 + PART_CFG_MB))
S3=$((S2 + PART_BOOT_MB))
S4=$((S3 + PART_BOOT_MB))
S5=$((S4 + PART_ROOT_MB))
S6=$((S5 + PART_ROOT_MB))
END=$((S6 + PART_DATA_MB + 1))
IMG="$W/disk.img"
truncate -s $((END * MIB)) "$IMG"
FAT=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
LNX=0FC63DAF-8483-4772-8E79-3D69D8477DE4
sfdisk --quiet --no-reread --no-tell-kernel "$IMG" <<EOF
label: gpt
label-id: $(uuid_from disk)
unit: sectors
first-lba: 2048

start=$((S1 * 2048)), size=$((PART_CFG_MB * 2048)),  type=$FAT, name="unlook-cfg",    uuid=$(uuid_from p1)
start=$((S2 * 2048)), size=$((PART_BOOT_MB * 2048)), type=$FAT, name="unlook-boot-a", uuid=$(uuid_from p2)
start=$((S3 * 2048)), size=$((PART_BOOT_MB * 2048)), type=$FAT, name="unlook-boot-b", uuid=$(uuid_from p3)
start=$((S4 * 2048)), size=$((PART_ROOT_MB * 2048)), type=$LNX, name="unlook-root-a", uuid=$(uuid_from p4)
start=$((S5 * 2048)), size=$((PART_ROOT_MB * 2048)), type=$LNX, name="unlook-root-b", uuid=$(uuid_from p5)
start=$((S6 * 2048)), size=$((PART_DATA_MB * 2048)), type=$LNX, name="unlook-data",   uuid=$(uuid_from p6)
EOF
put() { dd if="$1" of="$IMG" bs=1M seek="$2" conv=notrunc,fsync status=none; }
put "$W/cfg.vfat" "$S1"
put "$BASE.bootfs.vfat" "$S2"
put "$BASE.rootfs.ext4" "$S4"
put "$W/data.ext4" "$S6"
# Slots B stay zeroed: `rauc status` reports them as never installed until the first update.

log "compressing image"
xz -T0 -6 -c "$IMG" > "$BASE.img.xz"
(cd "$OUT" && sha256sum "$(basename "$BASE").img.xz" "$(basename "$BASE").rootfs.ext4" \
    "$(basename "$BASE").bootfs.vfat" > "$(basename "$BASE").SHA256SUMS")
log "done: $BASE.img.xz"
