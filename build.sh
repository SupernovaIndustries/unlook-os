#!/bin/sh
# Unlook OS build driver.
#
#   ./build.sh rootfs      pi-gen (in Docker) -> deploy/<img>-rootfs.tar
#   ./build.sh image       rootfs tar -> A/B GPT image + slot images (image/mkimage.sh)
#   ./build.sh bundle      slot images -> signed RAUC bundle (rauc/build-bundle.sh)
#   ./build.sh all         the three above, in order
#
# Options: --native  run pi-gen / mkimage on this host (Debian, root) instead of Docker.
# Inputs : config/unlook-os.conf (+ env overrides), debs/*.deb (SDK_DEB_SOURCE=local),
#          $KEYS_DIR/{rauc-keyring.pem,apt-archive-keyring.gpg}, branding/ (optional).
# Output : deploy/
set -eu

TOP="$(cd "$(dirname "$0")" && pwd)"
. "$TOP/scripts/lib.sh"

ACTION="${1:-all}"
NATIVE=0
for a in "$@"; do
    case "$a" in
        --native) NATIVE=1 ;;
        rootfs | image | bundle | all) ;;
        *) die "usage: $0 [rootfs|image|bundle|all] [--native]" ;;
    esac
done

conf_load "$TOP/config/unlook-os.conf"

# ---- version: releases come from the tag, everything else is a dev build ----
GIT_SHA="$(git -C "$TOP" rev-parse --short=10 HEAD 2>/dev/null || echo nogit)"
if { [ "$ACTION" = image ] || [ "$ACTION" = bundle ]; } && [ -f "$TOP/deploy/build-info.env" ]; then
    # Later steps reuse the version the rootfs was built with.
    UNLOOK_OS_VERSION="$(sed -n 's/^UNLOOK_OS_VERSION=//p' "$TOP/deploy/build-info.env")"
elif [ -n "${CI_COMMIT_TAG:-}" ]; then
    UNLOOK_OS_VERSION="${CI_COMMIT_TAG#v}"
elif [ "${UNLOOK_OS_RELEASE:-0}" != 1 ]; then
    UNLOOK_OS_VERSION="${UNLOOK_OS_VERSION}~dev.$(date -u +%Y%m%d%H%M).${GIT_SHA}"
fi
export UNLOOK_OS_VERSION
conf_validate

# Reproducibility anchor: the commit time, not the wall clock.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$TOP" log -1 --format=%ct 2>/dev/null || date +%s)}"
export SOURCE_DATE_EPOCH

DEPLOY="$TOP/deploy"
WORK="$TOP/build"
mkdir -p "$DEPLOY" "$WORK"

KEYS="$TOP/$KEYS_DIR"
case "$KEYS_DIR" in /*) KEYS="$KEYS_DIR" ;; esac

check_inputs() {
    [ -s "$KEYS/rauc-keyring.pem" ] || die "missing $KEYS/rauc-keyring.pem (scripts/dev-keys.sh for a dev build)"
    [ -s "$KEYS/apt-archive-keyring.gpg" ] || die "missing $KEYS/apt-archive-keyring.gpg"
    if [ -n "$MIRA220_DRIVER_DIR" ]; then
        for f in driver/mira220-sync.c driver/Makefile overlay/mira220-sync.dts; do
            [ -f "$TOP/$MIRA220_DRIVER_DIR/$f" ] ||
                die "missing $MIRA220_DRIVER_DIR/$f (git submodule update --init)"
        done
    fi
    if [ -n "$LIBCAMERA_REPO" ]; then
        ls "$TOP"/debs/unlook-libcamera_*_arm64.deb >/dev/null 2>&1 ||
            die "LIBCAMERA_REPO is set but no debs/unlook-libcamera_*_arm64.deb (libcamera/build-deb.sh)"
    else
        log "WARNING: LIBCAMERA_REPO empty: stock libcamera, the Mira220 cameras will not open in libcamera"
    fi
    if [ "$SDK_DEB_SOURCE" = none ]; then
        log "WARNING: SDK_DEB_SOURCE=none: bring-up image without unlook-stream (not releasable)"
    fi
    if [ "$SDK_DEB_SOURCE" = local ]; then
        ls "$TOP"/debs/"${SDK_PACKAGE}"_*_arm64.deb >/dev/null 2>&1 ||
            die "SDK_DEB_SOURCE=local but no debs/${SDK_PACKAGE}_*_arm64.deb (scripts/build-sdk-deb.sh)"
        if [ "$UNLOOK_OS_SUITE" = bookworm ] && ! ls "$TOP"/debs/libopencv*dev*.deb >/dev/null 2>&1; then
            die "bookworm ships OpenCV 4.6; the SDK needs >= 4.7 (aruco). Build debs/ with opencv/build-deb.sh, or set SDK_DEB_SOURCE=apt with OpenCV in the Unlook repo"
        fi
    fi
    case "$PIGEN_REF" in
        *[!0-9a-f]* | ?????????????????????????????????????????*)
            log "WARNING: PIGEN_REF=$PIGEN_REF is not a commit SHA: the build is not reproducible" ;;
    esac
}

build_rootfs() {
    check_inputs
    PIGEN="$WORK/pi-gen"
    if [ ! -d "$PIGEN/.git" ]; then
        git clone --quiet "$PIGEN_REPO" "$PIGEN"
    fi
    git -C "$PIGEN" fetch --quiet origin
    git -C "$PIGEN" checkout --quiet --force "$PIGEN_REF"
    git -C "$PIGEN" clean -fdxq -e work -e deploy
    PIGEN_SHA="$(git -C "$PIGEN" rev-parse HEAD)"
    log "pi-gen $PIGEN_SHA"

    # Our stage replaces pi-gen's export: stage2 must not produce its own image.
    touch "$PIGEN/stage2/SKIP_IMAGES"
    STAGE="$PIGEN/stage-unlook"
    rm -rf "$STAGE"
    cp -R "$TOP/stages/stage-unlook" "$STAGE"
    cp "$TOP/config/unlook-os.conf" "$STAGE/unlook-os.conf"
    cp "$TOP/scripts/lib.sh" "$STAGE/lib.sh"
    SDK_SHA="$(git -C "$TOP/unlook-sdk" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ -z "${KEYRING_KIND:-}" ]; then
        KEYRING_KIND=production
        case "$KEYS_DIR" in *dev*) KEYRING_KIND=dev ;; esac
    fi
    require_match KEYRING_KIND "$KEYRING_KIND" 'dev|ci|production'
    cat > "$STAGE/build-info.env" <<EOF
UNLOOK_OS_VERSION=$UNLOOK_OS_VERSION
UNLOOK_OS_GIT=$GIT_SHA
UNLOOK_SDK_GIT=$SDK_SHA
PIGEN_SHA=$PIGEN_SHA
KEYRING_KIND=$KEYRING_KIND
SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
EOF
    # Every override has to reach the stage scripts: re-emit the effective config.
    env | grep -E '^(IMG_NAME|UNLOOK_|RAUC_|PIGEN_|CAMERA_|MIRA220_|LIBCAMERA_|I2C_|UART_|USB_|EXTRA_|FW_|PART_|HEALTH_|TRYBOOT_|SDK_|ADMIN_|SERVICE_|BRANDING|WPA_|TIMEZONE_|LOCALE_|KEYBOARD_)' |
        sed 's/^\([A-Z0-9_]*\)=\(.*\)$/\1="\2"/' > "$STAGE/unlook-os.conf"
    mkdir -p "$STAGE/01-camera/files/debs" "$STAGE/02-sdk/files/debs" "$STAGE/02-sdk/files/keys" "$STAGE/03-system/files"
    cp -R "$TOP/overlays" "$STAGE/01-camera/files/unlook-overlays"
    if [ -n "$MIRA220_DRIVER_DIR" ]; then
        cp -R "$TOP/$MIRA220_DRIVER_DIR/driver" "$TOP/$MIRA220_DRIVER_DIR/overlay" "$STAGE/01-camera/files/"
        git -C "$TOP/$MIRA220_DRIVER_DIR" rev-parse HEAD > "$STAGE/01-camera/files/driver.commit" 2>/dev/null || echo unknown > "$STAGE/01-camera/files/driver.commit"
    fi
    if [ -n "$LIBCAMERA_REPO" ]; then
        cp "$TOP"/debs/unlook-libcamera_*_arm64.deb "$STAGE/01-camera/files/debs/"
    fi
    if [ "$SDK_DEB_SOURCE" = none ]; then
        P="$STAGE/02-sdk/files/sdk-packaging"
        mkdir -p "$P"
        cp -R "$TOP/unlook-sdk/packaging/systemd" "$TOP/unlook-sdk/packaging/usb-gadget" \
            "$TOP/unlook-sdk/packaging/bluetooth" "$P/"
        cp "$TOP/unlook-sdk/config/scanner_profile.sample.yaml" "$P/"
    fi
    if [ "$SDK_DEB_SOURCE" = local ]; then
        find "$TOP/debs" -maxdepth 1 -name '*.deb' ! -name 'unlook-libcamera_*' -exec cp {} "$STAGE/02-sdk/files/debs/" \;
    fi
    cp "$KEYS/rauc-keyring.pem" "$KEYS/apt-archive-keyring.gpg" "$STAGE/02-sdk/files/keys/"
    cp "$TOP/docs/OS.md" "$STAGE/03-system/files/OS.md"
    rm -rf "$STAGE/04-branding/files/assets"
    mkdir -p "$STAGE/04-branding/files/assets"
    if [ "$BRANDING" = auto ] && [ -d "$TOP/branding/assets" ]; then
        cp -R "$TOP/branding/assets/." "$STAGE/04-branding/files/assets/"
    fi

    # The first user's password is random and immediately locked (key-only SSH).
    FIRST_PASS="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
    cat > "$PIGEN/config" <<EOF
IMG_NAME=$IMG_NAME
RELEASE=$UNLOOK_OS_SUITE
DEPLOY_COMPRESSION=none
TARGET_HOSTNAME=unlook
FIRST_USER_NAME=$ADMIN_USER
FIRST_USER_PASS=$FIRST_PASS
DISABLE_FIRST_BOOT_USER_RENAME=1
ENABLE_SSH=0
LOCALE_DEFAULT=$LOCALE_DEFAULT
KEYBOARD_KEYMAP=$KEYBOARD_KEYMAP
KEYBOARD_LAYOUT="$KEYBOARD_LAYOUT"
TIMEZONE_DEFAULT=$TIMEZONE_DEFAULT
WPA_COUNTRY=$WPA_COUNTRY
STAGE_LIST="stage0 stage1 stage2 stage-unlook"
EOF
    if [ "$NATIVE" -eq 1 ]; then
        (cd "$PIGEN" && ./build.sh)
    else
        (cd "$PIGEN" && CONTINUE="${PIGEN_CONTINUE:-0}" PRESERVE_CONTAINER=0 ./build-docker.sh)
    fi
    ROOTFS_TAR="$PIGEN/deploy/${IMG_NAME}-rootfs.tar"
    [ -s "$ROOTFS_TAR" ] || die "pi-gen did not produce $ROOTFS_TAR"
    mv "$ROOTFS_TAR" "$DEPLOY/"
    mv "$PIGEN/deploy/${IMG_NAME}-packages.tsv" "$DEPLOY/${IMG_NAME}-${UNLOOK_OS_VERSION}.packages.tsv"
    cp "$STAGE/build-info.env" "$DEPLOY/build-info.env"
    log "rootfs: $DEPLOY/${IMG_NAME}-rootfs.tar"
}

build_image() {
    [ -s "$DEPLOY/${IMG_NAME}-rootfs.tar" ] || die "run '$0 rootfs' first"
    if [ "$NATIVE" -eq 1 ]; then
        "$TOP/image/mkimage.sh" "$DEPLOY/${IMG_NAME}-rootfs.tar" "$DEPLOY"
    else
        docker run --rm \
            -e SOURCE_DATE_EPOCH -e UNLOOK_OS_VERSION \
            -v "$TOP:/work" -w /work debian:bookworm \
            sh -c 'apt-get -qq update >/dev/null &&
                   apt-get -qq install -y --no-install-recommends e2fsprogs dosfstools mtools fdisk xz-utils git ca-certificates >/dev/null &&
                   git config --global --add safe.directory /work &&
                   image/mkimage.sh "deploy/'"$IMG_NAME"'-rootfs.tar" deploy'
    fi
}

build_bundle() {
    "$TOP/rauc/build-bundle.sh" "$DEPLOY"
}

case "$ACTION" in
    rootfs) build_rootfs ;;
    image) build_image ;;
    bundle) build_bundle ;;
    all) build_rootfs; build_image; build_bundle ;;
esac
