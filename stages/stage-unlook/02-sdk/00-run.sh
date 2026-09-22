#!/bin/bash -e
# Trust anchors + the unlook-sdk .deb (its postinst creates /etc/unlook and
# /var/lib/unlook and enables unlook-stream.service).
# SDK_DEB_SOURCE=none (hardware bring-up): no daemon; only the SDK's USB-C
# gadget, BlueZ settings and sample profile are installed from the submodule.
# shellcheck source=../lib.sh
. "${STAGE_DIR}/lib.sh"
conf_load "${STAGE_DIR}/unlook-os.conf"
conf_validate
R="${ROOTFS_DIR}"

install -D -m 0644 files/keys/apt-archive-keyring.gpg "${R}/usr/share/keyrings/unlook-archive-keyring.gpg"
install -D -m 0644 files/keys/rauc-keyring.pem "${R}/etc/rauc/keyring.pem"

case "${SDK_DEB_SOURCE}" in
    local)
        rm -rf "${R}/tmp/unlook-debs"
        install -d "${R}/tmp/unlook-debs"
        cp files/debs/*.deb "${R}/tmp/unlook-debs/"
        on_chroot << EOF
set -e
apt-get update
# Local .debs (SDK, OpenCV >= 4.7 on bookworm); every other dependency comes
# from the Debian / Raspberry Pi archives.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/unlook-debs/*.deb
# Seed the apt cache: unlook-ota rolls a failed SDK update back to this file.
cp /tmp/unlook-debs/${SDK_PACKAGE}_*_arm64.deb /var/cache/apt/archives/
rm -rf /tmp/unlook-debs
EOF
        ;;
    apt)
        [ -n "${UNLOOK_APT_URL}" ] || die "SDK_DEB_SOURCE=apt needs UNLOOK_APT_URL"
        install -D -m 0644 /dev/stdin "${R}/etc/apt/sources.list.d/unlook.sources" << EOF
Types: deb
URIs: ${UNLOOK_APT_URL}
Suites: ${UNLOOK_APT_SUITE}
Components: ${UNLOOK_APT_COMPONENT}
Architectures: arm64
Signed-By: /usr/share/keyrings/unlook-archive-keyring.gpg
EOF
        on_chroot << EOF
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    -o Binary::apt::APT::Keep-Downloaded-Packages=true ${SDK_PACKAGE}
EOF
        ;;
    none)
        P=files/sdk-packaging
        install -D -m 0644 "$P/systemd/unlook-usb-gadget.service" "${R}/usr/lib/systemd/system/unlook-usb-gadget.service"
        install -D -m 0755 "$P/usb-gadget/unlook-usb-gadget.sh" "${R}/usr/local/sbin/unlook-usb-gadget.sh"
        install -D -m 0644 "$P/bluetooth/unlook.conf" "${R}/etc/bluetooth/main.conf.d/unlook.conf"
        install -D -m 0644 "$P/scanner_profile.sample.yaml" "${R}/etc/unlook/scanner_profile.yaml"
        install -d -m 0700 "${R}/var/lib/unlook"
        printf 'SDK_DEB_SOURCE=none\n' > "${R}/etc/unlook-os-bringup"
        log "bring-up image: no unlook-stream"
        exit 0
        ;;
esac

# SDK updates from GitHub are built on the unit (docs/OS.md §6.1): the SDK's
# -dev dependencies come with the package, add the toolchain + git/ssh/gpg.
if [ "${SDK_OTA_SOURCE}" = github ]; then
    on_chroot << 'EOF'
set -e
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cmake g++ make pkg-config dpkg-dev file git openssh-client gnupg
EOF
    install -d -m 0755 "${R}/usr/share/unlook-os/sdk-git-trust"
fi

# Fail the build, not the unit: the pieces the OS integrates with must exist.
for f in /usr/bin/unlook_stream /usr/lib/systemd/system/unlook-stream.service \
         /usr/lib/systemd/system/unlook-usb-gadget.service; do
    [ -e "${R}${f}" ] || die "SDK package did not install ${f} (see docs/SDK_CHANGES.md §4)"
done
