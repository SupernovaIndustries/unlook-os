#!/bin/sh
# Build the unlook-sdk .deb (CPack) from the pinned submodule, on arm64
# (the Raspberry Pi CI runner -- the SDK's only authoritative build host).
#
#   scripts/build-sdk-deb.sh            -> debs/libunlook-sdk-dev_<ver>_arm64.deb
#
# Package version: the SDK's project(VERSION) for a tagged SDK commit, else
# <version>+git<commit time>.<sha> so every SDK commit is a strictly newer .deb
# for the apt channel.
set -eu
TOP="$(cd "$(dirname "$0")/.." && pwd)"
. "$TOP/scripts/lib.sh"

SDK="$TOP/unlook-sdk"
[ -f "$SDK/CMakeLists.txt" ] || die "unlook-sdk submodule missing: git submodule update --init"
[ "$(uname -m)" = aarch64 ] || die "build on arm64 (Raspberry Pi runner)"

BASEV="$(sed -n 's/^[[:space:]]*VERSION \([0-9][0-9.]*\)$/\1/p' "$SDK/CMakeLists.txt" | head -n 1)"
[ -n "$BASEV" ] || die "cannot read the SDK project version"
if git -C "$SDK" describe --exact-match --tags >/dev/null 2>&1; then
    DEBV="$BASEV"
else
    DEBV="${BASEV}+git$(git -C "$SDK" log -1 --format=%cd --date=format:%Y%m%d%H%M).$(git -C "$SDK" rev-parse --short=10 HEAD)"
fi
log "SDK package version $DEBV"

B="$TOP/build/sdk"
rm -rf "$B"
# Prefix /usr: the systemd units are installed into /usr/lib/systemd/system,
# which the postinst's `systemctl enable unlook-stream.service` needs.
cmake -S "$SDK" -B "$B" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DUNLOOK_SDK_INSTALL_SYSTEMD=ON \
    -DCPACK_DEBIAN_PACKAGE_VERSION="$DEBV" -DCPACK_DEBIAN_FILE_NAME=DEB-DEFAULT
cmake --build "$B" -j"$(nproc)"
(cd "$B" && ctest --output-on-failure) || die "SDK tests failed: no package"
(cd "$B" && cpack -G DEB)
mkdir -p "$TOP/debs"
cp "$B"/*.deb "$TOP/debs/"
ls -l "$TOP"/debs/*.deb
