#!/bin/sh
# libcamera with Mira220 support (camera helper + tuning) as a .deb for the image.
#
#   LIBCAMERA_REPO=<fork url> LIBCAMERA_REF=<commit> libcamera/build-deb.sh
#       -> debs/unlook-libcamera_<ver>_arm64.deb
#
# The Raspberry Pi archive libcamera has no Mira220 CamHelper, so the rpi/pisp
# (CM5) and rpi/vc4 (CM4) pipelines cannot run the sensor. This builds the
# fork into /usr/local -- the same layout as the hand-built bench units -- and
# packages it as `unlook-libcamera`, which Provides/Conflicts libcamera-dev and
# libcamera-ipa so the SDK's dependency is satisfied by this build only.
# Build on arm64 (Pi runner). Pin LIBCAMERA_REF to a commit SHA for releases.
set -eu
TOP="$(cd "$(dirname "$0")/.." && pwd)"
. "$TOP/scripts/lib.sh"
conf_load "$TOP/config/unlook-os.conf"
conf_validate
[ -n "$LIBCAMERA_REPO" ] && [ -n "$LIBCAMERA_REF" ] || die "set LIBCAMERA_REPO and LIBCAMERA_REF (config/unlook-os.conf)"
[ "$(uname -m)" = aarch64 ] || die "build on arm64 (Raspberry Pi runner)"
for t in meson ninja dpkg-deb dpkg-shlibdeps git; do command -v "$t" >/dev/null || die "missing $t"; done

W="$TOP/build/libcamera"
rm -rf "$W"
git clone --quiet "$LIBCAMERA_REPO" "$W/src"
git -C "$W/src" checkout --quiet "$LIBCAMERA_REF"
SHA="$(git -C "$W/src" rev-parse HEAD)"
UPV="$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" "$W/src/meson.build" | head -n 1)"
[ -n "$UPV" ] || die "cannot read the libcamera version"
DEBV="${UPV}+unlook$(git -C "$W/src" log -1 --format=%cd --date=format:%Y%m%d).$(printf '%s' "$SHA" | cut -c1-10)"
log "libcamera $UPV @ $SHA -> unlook-libcamera $DEBV"

# The Mira220 support must actually be in the tree we package.
grep -rqi mira220 "$W/src/src/ipa/rpi" || die "no Mira220 support in src/ipa/rpi of $LIBCAMERA_REF"

meson setup "$W/build" "$W/src" --prefix=/usr/local --buildtype=release \
    -Dpipelines=rpi/vc4,rpi/pisp -Dipas=rpi/vc4,rpi/pisp \
    -Dv4l2=true -Dcam=disabled -Dqcam=disabled -Dgstreamer=disabled -Dpycamera=disabled \
    -Dlc-compliance=disabled -Dtest=false -Ddocumentation=disabled -Dtracing=disabled
ninja -C "$W/build"
DESTDIR="$W/pkg" ninja -C "$W/build" install

# Every Mira220 tuning file the tree ships, for both pipelines.
n="$(find "$W/pkg/usr/local/share/libcamera/ipa/rpi" -name 'mira220_mono.json' | wc -l)"
[ "$n" -gt 0 ] || die "the build installed no mira220_mono.json tuning file (Unlook sensors are mono)"

mkdir -p "$W/pkg/DEBIAN" "$W/deb/debian"
printf 'Source: unlook-libcamera\n\nPackage: unlook-libcamera\nArchitecture: arm64\n' > "$W/deb/debian/control"
DEPS="$(cd "$W/deb" && find "$W/pkg" -type f -name '*.so*' -exec dpkg-shlibdeps -O -l"$W/pkg/usr/local/lib/aarch64-linux-gnu" {} + 2>/dev/null |
    sed -n 's/^shlibs:Depends=//p')"
cat > "$W/pkg/DEBIAN/control" << EOF
Package: unlook-libcamera
Version: $DEBV
Architecture: arm64
Maintainer: Supernova Industries <alessandro.cursoli@supernovaindustries.it>
Section: libs
Priority: optional
Depends: $DEPS
Provides: libcamera-dev, libcamera-ipa
Conflicts: libcamera-dev, libcamera-ipa
Description: libcamera with ams Mira220 support for Unlook OS
 Built from $LIBCAMERA_REPO at $SHA into /usr/local
 (rpi/pisp + rpi/vc4 pipelines, Mira220 camera helper and tuning).
EOF
printf '#!/bin/sh\nset -e\n[ "$1" = configure ] && ldconfig\nexit 0\n' > "$W/pkg/DEBIAN/postinst"
chmod 0755 "$W/pkg/DEBIAN/postinst"
mkdir -p "$TOP/debs"
dpkg-deb --root-owner-group --build "$W/pkg" "$TOP/debs/unlook-libcamera_${DEBV}_arm64.deb"
log "debs/unlook-libcamera_${DEBV}_arm64.deb"
