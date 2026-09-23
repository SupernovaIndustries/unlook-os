#!/bin/sh
# Build Unlook OS on any host that has Docker (macOS Apple Silicon: native arm64,
# recommended; Linux arm64; x86 hosts work through emulation but take hours).
#
#   scripts/docker-build.sh [all|debs|image|bundle|shell]
#
#   debs    OpenCV >= 4.7, unlook-libcamera (ams fork) and the unlook-sdk .debs -> debs/
#   image   pi-gen + A/B disk image                                          -> deploy/
#   bundle  signed RAUC bundle (dev keys unless RAUC_SIGNING_CERT/KEY are set) -> deploy/
#   all     the three above (default)
#   shell   interactive shell in the builder, for debugging
#
# Everything runs inside the `unlook-os-builder` container (docker/Dockerfile):
# the host needs only Docker and git. pi-gen's work tree lives in the Docker
# volume `unlook-pigen-work` (a Linux filesystem: device nodes, ownership).
set -eu
TOP="$(cd "$(dirname "$0")/.." && pwd)"
STEP="${1:-all}"
case "$STEP" in all | debs | image | bundle | shell) ;; *) echo "usage: $0 [all|debs|image|bundle|shell]" >&2; exit 64 ;; esac

command -v docker >/dev/null 2>&1 || { echo "Docker is required (Docker Desktop on macOS)." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is not running." >&2; exit 1; }
for f in unlook-sdk/CMakeLists.txt drivers/mira220-sync/driver/Makefile; do
    [ -f "$TOP/$f" ] || { echo "missing $f: run  git submodule update --init --recursive" >&2; exit 1; }
done
case "$TOP" in *' '*) echo "the checkout path must not contain spaces: $TOP" >&2; exit 1 ;; esac
case "$(uname -m)" in
    arm64 | aarch64) ;;
    *) echo "note: $(uname -m) host -- the arm64 builder runs emulated (much slower)" >&2 ;;
esac

docker build --platform linux/arm64 -t unlook-os-builder "$TOP/docker"
docker volume create unlook-pigen-work >/dev/null

TTY=""
[ -t 0 ] && [ -t 1 ] && TTY="-it"
# shellcheck disable=SC2086 # TTY is empty or one flag
exec docker run --rm $TTY --privileged --platform linux/arm64 \
    -v "$TOP:/work" -v unlook-pigen-work:/pigen-work -w /work \
    -e KEYS_DIR -e KEYRING_KIND -e SDK_DEB_SOURCE -e SDK_OTA_SOURCE -e UNLOOK_OS_RELEASE \
    -e RAUC_SIGNING_CERT -e RAUC_SIGNING_KEY -e BRANDING \
    unlook-os-builder sh scripts/in-container.sh "$STEP"
