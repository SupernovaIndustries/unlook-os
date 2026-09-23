ls "$TOP"/debs/libopencv-dev_*_arm64.deb >/dev/null 2>&1 ||
    die "no libopencv-dev package produced (CPack package names: see the log above)"#!/bin/sh
# OpenCV >= 4.7 with contrib/aruco for Raspberry Pi OS bookworm (Debian ships
# 4.6.0, the SDK calibration engine needs the 4.7+ aruco API).
#
#   opencv/build-deb.sh              (arm64 only) -> debs/libopencv*.deb
#
# The packages are published in the Unlook apt repository; their version (4.10.x)
# outranks Debian's 4.6 so `libopencv-dev` resolves to this build. Not needed on
# trixie (4.10 in the archive): see docs/OS.md §10.
set -eu
TOP="$(cd "$(dirname "$0")/.." && pwd)"
. "$TOP/scripts/lib.sh"

OPENCV_VERSION="${OPENCV_VERSION:-4.10.0}"
require_match OPENCV_VERSION "$OPENCV_VERSION" '4\.(7|8|9|1[0-9])\.[0-9]+'
[ "$(uname -m)" = aarch64 ] || die "build on arm64 (Raspberry Pi runner)"

W="$TOP/build/opencv"
rm -rf "$W"
mkdir -p "$W"
for r in opencv opencv_contrib; do
    git clone --quiet --depth 1 --branch "$OPENCV_VERSION" "https://github.com/opencv/$r.git" "$W/$r"
    log "$r $OPENCV_VERSION = $(git -C "$W/$r" rev-parse HEAD)"
done
# Pin the resolved commits in opencv/PINNED once verified; a mismatch then fails the build.
if [ -f "$TOP/opencv/PINNED" ]; then
    for r in opencv opencv_contrib; do
        want="$(sed -n "s/^$r=//p" "$TOP/opencv/PINNED")"
        [ -z "$want" ] || [ "$want" = "$(git -C "$W/$r" rev-parse HEAD)" ] || die "$r commit differs from opencv/PINNED"
    done
fi

# No fast-math anywhere (metrology). Only the modules the SDK uses + their deps.
cmake -S "$W/opencv" -B "$W/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DOPENCV_EXTRA_MODULES_PATH="$W/opencv_contrib/modules" \
    -DBUILD_LIST=core,imgproc,imgcodecs,calib3d,features2d,flann,objdetect,aruco,highgui,videoio \
    -DENABLE_FAST_MATH=OFF -DCV_ENABLE_INTRINSICS=ON -DENABLE_NEON=ON \
    -DWITH_TBB=ON -DWITH_OPENMP=ON -DWITH_GTK=OFF -DWITH_QT=OFF -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF \
    -DBUILD_opencv_python3=OFF -DBUILD_JAVA=OFF -DOPENCV_GENERATE_PKGCONFIG=ON \
    -DCPACK_BINARY_DEB=ON -DCPACK_BINARY_TGZ=OFF -DCPACK_BINARY_STGZ=OFF -DCPACK_BINARY_TZ=OFF \
    -DCPACK_DEBIAN_PACKAGE_ARCHITECTURE=arm64 -DCPACK_PACKAGE_CONTACT="Supernova Industries"
cmake --build "$W/build" -j"$(nproc)"
(cd "$W/build" && cpack -G DEB)
mkdir -p "$TOP/debs"
for d in "$W"/build/*.deb; do
    # Canonical Debian file names (<package>_<version>_<arch>.deb) whatever CPack chose.
    pkg="$(dpkg-deb -f "$d" Package)"
    ver="$(dpkg-deb -f "$d" Version)"
    arch="$(dpkg-deb -f "$d" Architecture)"
    log "$pkg $ver $arch"
    cp "$d" "$TOP/debs/${pkg}_${ver}_${arch}.deb"
done
ls "$TOP"/debs/libopencv-dev_*_arm64.deb >/dev/null 2>&1 ||
    die "no libopencv-dev package produced (package names are in the log above)"
