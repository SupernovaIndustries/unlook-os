# Unlook OS builder: Debian bookworm arm64 with everything the build needs
# (pi-gen, image assembly, RAUC, and the OpenCV / libcamera / SDK .debs).
# Used by scripts/docker-build.sh; the only host requirement is Docker.
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN echo 'deb http://deb.debian.org/debian bookworm-backports main' > /etc/apt/sources.list.d/backports.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
    # pi-gen (its `depends` file)
    quilt parted coreutils qemu-user-static debootstrap zerofree zip dosfstools e2fsprogs \
    libcap2-bin libarchive-tools grep rsync xz-utils curl xxd file git kmod bc gpg pigz arch-test \
    ca-certificates \
    # image assembly + RAUC bundle + dev keys
    mtools fdisk rauc squashfs-tools openssl \
    # common build toolchain / packaging
    build-essential cmake ninja-build pkg-config dpkg-dev fakeroot \
    # OpenCV >= 4.7
    libtbb-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev libopenjp2-7-dev zlib1g-dev \
    # libcamera (ams fork) + libpisp
    python3-yaml python3-ply python3-jinja2 libyaml-dev libgnutls28-dev libssl-dev libdw-dev \
    libunwind-dev libudev-dev libdrm-dev libevent-dev nlohmann-json3-dev \
    libboost-dev libboost-log-dev libboost-thread-dev libboost-program-options-dev \
    # unlook-sdk
    libyaml-cpp-dev libi2c-dev libsdbus-c++-dev libsystemd-dev \
    libocct-data-exchange-dev libocct-modeling-algorithms-dev qrencode \
 && apt-get install -y --no-install-recommends -t bookworm-backports meson \
 && rm -rf /var/lib/apt/lists/* \
 && git config --system --add safe.directory '*'

WORKDIR /work
