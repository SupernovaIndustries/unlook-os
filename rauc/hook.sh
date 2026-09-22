#!/bin/sh
# RAUC bundle hook (runs on the unit, from inside the signed bundle).
#
# install-check     : anti-rollback -- refuse a bundle that is not newer than
#                     the running OS unless `unlook-ota apply os --allow-downgrade`
#                     left /run/unlook/ota/allow-downgrade.
# slot-post-install : the images are built for slot A; retarget them to B:
#   rootfs -> /etc/fstab root/boot lines, carry /etc/machine-id over
#   bootfs -> cmdline.txt root=PARTLABEL= and rauc.slot=
set -eu

say() { echo "unlook-hook: $*" >&2; }
ROOT="${UNLOOK_OS_TESTROOT:-}" # unit tests only; empty under RAUC

case "${1:-}" in
    install-check)
        cur="$(sed -n 's/^VERSION=//p' "$ROOT/etc/unlook-os-release" 2>/dev/null | head -n 1)"
        [ -n "$cur" ] || { say "running system has no /etc/unlook-os-release"; exit 10; }
        printf '%s' "${RAUC_MF_VERSION:-}" | grep -Eq '^[0-9A-Za-z.+~-]{1,64}$' || {
            say "bundle has no valid version"
            exit 10
        }
        if [ -f "$ROOT/run/unlook/ota/allow-downgrade" ]; then
            say "downgrade explicitly allowed ($cur -> $RAUC_MF_VERSION)"
            exit 0
        fi
        if ! dpkg --compare-versions "$RAUC_MF_VERSION" gt "$cur"; then
            say "refusing bundle $RAUC_MF_VERSION: not newer than the installed $cur"
            exit 10
        fi
        ;;
    slot-post-install)
        mp="${RAUC_SLOT_MOUNT_POINT:?}"
        case "${RAUC_SLOT_NAME:-}" in
            rootfs.0 | bootfs.0) to=a; TO=A; from=b ;;
            rootfs.1 | bootfs.1) to=b; TO=B; from=a ;;
            *) say "unexpected slot ${RAUC_SLOT_NAME:-}"; exit 1 ;;
        esac
        case "${RAUC_SLOT_CLASS:-}" in
            rootfs)
                f="$mp/etc/fstab"
                sed -i -e "s/^PARTLABEL=unlook-root-$from /PARTLABEL=unlook-root-$to /" \
                       -e "s/^PARTLABEL=unlook-boot-$from /PARTLABEL=unlook-boot-$to /" "$f"
                grep -q "^PARTLABEL=unlook-root-$to " "$f" && grep -q "^PARTLABEL=unlook-boot-$to " "$f" || {
                    say "fstab retarget failed"
                    exit 1
                }
                # Same machine identity on both slots (journal continuity).
                if [ -s "$ROOT/etc/machine-id" ]; then cp "$ROOT/etc/machine-id" "$mp/etc/machine-id"; fi
                ;;
            bootfs)
                f="$mp/cmdline.txt"
                sed -i -e "s/root=PARTLABEL=unlook-root-[ab]/root=PARTLABEL=unlook-root-$to/" \
                       -e "s/rauc\.slot=[AB]/rauc.slot=$TO/" "$f"
                grep -q "root=PARTLABEL=unlook-root-$to" "$f" && grep -q "rauc.slot=$TO" "$f" || {
                    say "cmdline.txt retarget failed"
                    exit 1
                }
                ;;
            *) say "unexpected slot class ${RAUC_SLOT_CLASS:-}"; exit 1 ;;
        esac
        sync
        say "${RAUC_SLOT_NAME} retargeted to slot $TO"
        ;;
    *) ;;
esac
exit 0
