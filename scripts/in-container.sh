#!/bin/sh
# Runs INSIDE the unlook-os-builder container (started by scripts/docker-build.sh).
#   in-container.sh all|debs|image|bundle|shell
set -eu
cd /work
. scripts/lib.sh
[ -f /.dockerenv ] || die "run through scripts/docker-build.sh"
STEP="${1:-all}"

step_debs() {
    if [ "${KEYS_DIR:-keys/dev}" = keys/dev ] && [ ! -s keys/dev/rauc-keyring.pem ]; then
        log "creating development keys (keys/dev)"
        scripts/dev-keys.sh
    fi
    apt-get update -qq
    # OpenCV >= 4.7 (bookworm ships 4.6): built once, kept in debs/.
    if ! ls debs/libopencv-dev_*_arm64.deb >/dev/null 2>&1; then
        log "building OpenCV (first time only, ~30-60 min)"
        opencv/build-deb.sh
    fi
    apt-get install -y --no-install-recommends ./debs/libopencv*_arm64.deb >/dev/null
    # libcamera with Mira220 support: built once per LIBCAMERA_REF.
    if ! ls debs/unlook-libcamera_*_arm64.deb >/dev/null 2>&1; then
        log "building unlook-libcamera"
        libcamera/build-deb.sh
    fi
    apt-get install -y --no-install-recommends ./debs/unlook-libcamera_*_arm64.deb >/dev/null
    ldconfig
    # The SDK is rebuilt every time (it follows the submodule commit).
    rm -f debs/libunlook-sdk_*_arm64.deb debs/libunlook-sdk-dev_*_arm64.deb
    log "building unlook-sdk"
    scripts/build-sdk-deb.sh
}

step_image() {
    # pi-gen's work tree on the Docker volume (Linux filesystem), fresh stages.
    PIGEN_WORK_DIR=/pigen-work/unlook-os ./build.sh rootfs --native
    ./build.sh image --native
}

step_bundle() {
    RAUC_SIGNING_CERT="${RAUC_SIGNING_CERT:-keys/dev/rauc-signing.crt}" \
        RAUC_SIGNING_KEY="${RAUC_SIGNING_KEY:-keys/dev/rauc-signing.key}" \
        ./build.sh bundle
}

case "$STEP" in
    debs) step_debs ;;
    image) step_image ;;
    bundle) step_bundle ;;
    all) step_debs; step_image; step_bundle ;;
    shell) exec bash ;;
    *) die "unknown step $STEP" ;;
esac
log "done: $STEP -- outputs in debs/ and deploy/"
