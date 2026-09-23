#!/bin/sh
# Build and sign the RAUC bundle for the slot images made by image/mkimage.sh.
#
#   RAUC_SIGNING_CERT=<pem> RAUC_SIGNING_KEY=<pem|pkcs11 URI> rauc/build-bundle.sh <deploydir>
#
# Output: <img>-<ver>.raucb and the OTA pointer `latest` (version, bundle, sha256)
# to publish at $UNLOOK_OTA_URL/$RAUC_COMPATIBLE/. The private key never enters
# the repository: CI passes a masked file variable, production may use a PKCS#11 HSM.
set -eu
TOP="$(cd "$(dirname "$0")/.." && pwd)"
. "$TOP/scripts/lib.sh"
conf_load "$TOP/config/unlook-os.conf"

OUT="${1:?deploy dir}"
[ -f "$OUT/build-info.env" ] || die "no $OUT/build-info.env (run build.sh rootfs)"
V="$(sed -n 's/^UNLOOK_OS_VERSION=//p' "$OUT/build-info.env")"
BUILD="$(sed -n 's/^UNLOOK_OS_GIT=//p' "$OUT/build-info.env")"
UNLOOK_OS_VERSION="$V"
export UNLOOK_OS_VERSION
conf_validate

KEYS="$TOP/$KEYS_DIR"
case "$KEYS_DIR" in /*) KEYS="$KEYS_DIR" ;; esac
CERT="${RAUC_SIGNING_CERT:?RAUC_SIGNING_CERT not set}"
KEY="${RAUC_SIGNING_KEY:?RAUC_SIGNING_KEY not set}"
KEYRING="$KEYS/rauc-keyring.pem"
[ -s "$KEYRING" ] || die "missing $KEYRING"
command -v rauc >/dev/null || die "rauc not installed (apt install rauc)"

BASE="$OUT/${IMG_NAME}-${V}"
for f in "$BASE.rootfs.ext4" "$BASE.bootfs.vfat"; do [ -s "$f" ] || die "missing $f (build.sh image)"; done

W="$(mktemp -d)"
V_CONF="$(mktemp)"
trap 'rm -rf "$W" "$V_CONF"' EXIT
cp "$BASE.rootfs.ext4" "$W/rootfs.ext4"
cp "$BASE.bootfs.vfat" "$W/bootfs.vfat"
install -m 0755 "$TOP/rauc/hook.sh" "$W/hook.sh"
sed -e "s|@RAUC_COMPATIBLE@|$RAUC_COMPATIBLE|" -e "s|@VERSION@|$V|g" -e "s|@BUILD@|$BUILD|" \
    "$TOP/rauc/manifest.raucm.in" > "$W/manifest.raucm"

# Verify with the unit's own keyring policy: without a config rauc checks the
# default purpose (smimesign) and rejects our codeSigning certificate. The
# purpose is read from the system.conf the image ships, so the two cannot drift.
UNIT_CONF="$TOP/stages/stage-unlook/overlay/etc/rauc/system.conf"
PURPOSE="$(sed -n 's/^check-purpose=//p' "$UNIT_CONF" | head -n 1)"
require_match check-purpose "$PURPOSE" 'codesign|smimesign|any'
printf '[system]\ncompatible=%s\nbootloader=noop\n\n[keyring]\npath=%s\ncheck-purpose=%s\n' \
    "$RAUC_COMPATIBLE" "$KEYRING" "$PURPOSE" > "$V_CONF"

B="$BASE.raucb"
rm -f "$B"
# --keyring: rauc verifies the fresh signature against the unit's trust anchor,
# so a bundle signed with the wrong key never leaves the build.
rauc --conf="$V_CONF" bundle --cert="$CERT" --key="$KEY" --keyring="$KEYRING" "$W" "$B"
rauc --conf="$V_CONF" info --keyring="$KEYRING" "$B" >/dev/null
SUM="$(sha256sum "$B" | cut -d' ' -f1)"
printf 'version=%s\nbundle=%s\nsha256=%s\n' "$V" "$(basename "$B")" "$SUM" > "$OUT/latest"
log "bundle: $B"
