#!/bin/bash -e
# Mira220 stereo camera stack:
#   * mira220-sync.ko (drivers/mira220-sync, Supernova) built against EVERY
#     kernel installed in the image (CM5 = rpi-2712, CM4 = rpi-v8), into
#     /lib/modules/<kver>/updates -- compatible "ams,mira220-sync", so the
#     stock mira220 driver is never bound;
#   * mira220-sync.dtbo in /boot/firmware/overlays (master/slave trigger-mode,
#     cam0 override keeps the shared CAM_GPIO enable always on);
#   * libcamera with the Mira220 helper + tuning (unlook-libcamera .deb) when
#     provided, else the stock one (V4L2 only);
#   * kernel packages held: the out-of-tree module must match the kernel, so
#     the kernel only ever changes through an OS bundle.
# Build tools needed here are removed again before the stage ends.
# shellcheck source=../lib.sh
. "${STAGE_DIR}/lib.sh"
conf_load "${STAGE_DIR}/unlook-os.conf"
conf_validate

R="${ROOTFS_DIR}"

# ---- Unlook overlays (overlays/*-overlay.dts -> /boot/firmware/overlays/*.dtbo) ----
# unlook-cam-enable: CAM_GPIO regulators always-on, i.e. camera enable forced HIGH.
rm -rf "${R}/tmp/unlook-overlays"
cp -R files/unlook-overlays "${R}/tmp/unlook-overlays"
on_chroot << 'EOF'
set -e
dpkg -s device-tree-compiler >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends device-tree-compiler
n=0
for src in /tmp/unlook-overlays/*-overlay.dts; do
    name=$(basename "$src" -overlay.dts)
    dtc -@ -q -I dts -O dtb -o "/boot/firmware/overlays/$name.dtbo" "$src"
    chmod 0644 "/boot/firmware/overlays/$name.dtbo"
    n=$((n + 1))
done
# The camera-enable overlay must reference both CAM_GPIO regulators.
fdtget -p /boot/firmware/overlays/unlook-cam-enable.dtbo /__fixups__ | grep -qx cam0_reg
fdtget -p /boot/firmware/overlays/unlook-cam-enable.dtbo /__fixups__ | grep -qx cam1_reg
echo "unlook overlays compiled: $n"
rm -rf /tmp/unlook-overlays
EOF

if [ -z "${MIRA220_DRIVER_DIR}" ]; then
    log "WARNING: MIRA220_DRIVER_DIR empty: no camera driver in this image"
else
    rm -rf "${R}/tmp/mira220-sync"
    install -d "${R}/tmp/mira220-sync"
    cp -R files/driver files/overlay "${R}/tmp/mira220-sync/"
    DRIVER_COMMIT="$(cat files/driver.commit)"
    on_chroot << EOF
set -e
dpkg-query -W -f='\${Package}\n' | sort > /tmp/pkgs.before
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    linux-headers-rpi-2712 linux-headers-rpi-v8 make gcc device-tree-compiler kmod
built=0
for kdir in /lib/modules/*/; do
    k=\$(basename "\$kdir")
    [ -d "\$kdir/build" ] || { echo "no headers for \$k: skipped"; continue; }
    rm -rf "/tmp/mira220-sync/build-\$k"
    cp -R /tmp/mira220-sync/driver "/tmp/mira220-sync/build-\$k"
    make -C "\$kdir/build" M="/tmp/mira220-sync/build-\$k" modules
    install -D -m 0644 "/tmp/mira220-sync/build-\$k/mira220-sync.ko" "\$kdir/updates/mira220-sync.ko"
    depmod -a "\$k"
    modinfo -k "\$k" -F alias mira220-sync | grep -q 'ams,mira220-sync' || { echo "mira220-sync.ko for \$k has no ams,mira220-sync alias"; exit 1; }
    echo "mira220-sync ${DRIVER_COMMIT} built for \$k"
    built=\$((built + 1))
done
[ "\$built" -gt 0 ] || { echo "mira220-sync: no kernel to build against"; exit 1; }
dtc -@ -q -Wno-unit_address_vs_reg -I dts -O dtb \
    -o /boot/firmware/overlays/mira220-sync.dtbo /tmp/mira220-sync/overlay/mira220-sync.dts
chmod 0644 /boot/firmware/overlays/mira220-sync.dtbo
fdtget /boot/firmware/overlays/mira220-sync.dtbo /__overrides__ trigger-mode >/dev/null
# Kernel and module move together, only through OS bundles.
apt-mark hold linux-image-rpi-2712 linux-image-rpi-v8 >/dev/null
# Drop the build-only packages again (keep dtc/fdtget for field diagnostics).
dpkg-query -W -f='\${Package}\n' | sort > /tmp/pkgs.after
comm -13 /tmp/pkgs.before /tmp/pkgs.after | grep -vx -e device-tree-compiler -e libfdt1 -e kmod > /tmp/pkgs.build || true
if [ -s /tmp/pkgs.build ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y \$(cat /tmp/pkgs.build)
fi
rm -rf /tmp/mira220-sync /tmp/pkgs.*
EOF
    install -d "${R}/usr/share/doc/unlook-os"
    printf '%s\n' "${DRIVER_COMMIT}" > "${R}/usr/share/doc/unlook-os/mira220-sync.commit"
fi

# ---- libcamera ---------------------------------------------------------------------
if ls files/debs/unlook-libcamera_*_arm64.deb >/dev/null 2>&1; then
    rm -rf "${R}/tmp/unlook-cam-debs"
    install -d "${R}/tmp/unlook-cam-debs"
    cp files/debs/unlook-libcamera_*_arm64.deb "${R}/tmp/unlook-cam-debs/"
    on_chroot << 'EOF'
set -e
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/unlook-cam-debs/*.deb
rm -rf /tmp/unlook-cam-debs
ldconfig
EOF
else
    log "WARNING: no unlook-libcamera .deb: installing the stock libcamera (no Mira220 helper)"
    on_chroot << 'EOF'
set -e
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libcamera-dev libcamera-ipa
EOF
fi

# As in drivers/mira220-sync/README.md: the driver registers as "mira220-sync".
# libcamera picks the CamHelper by substring (-> the mira220 helper) but the
# tuning file by exact name, so mira220-sync.json must exist: link it to
# mira220.json (the driver exposes Bayer formats) for pisp (CM5) and vc4 (CM4).
on_chroot << 'EOF'
set -e
n=0
for base in /usr/local/share/libcamera/ipa/rpi /usr/share/libcamera/ipa/rpi; do
    for pipe in pisp vc4; do
        d="$base/$pipe"
        if [ -f "$d/mira220.json" ]; then
            ln -sfn mira220.json "$d/mira220-sync.json"
            n=$((n + 1))
        fi
    done
done
echo "mira220-sync -> mira220.json tuning links: $n"
EOF
if [ -n "${LIBCAMERA_REPO}" ]; then
    for pipe in pisp vc4; do
        [ -e "${R}/usr/local/share/libcamera/ipa/rpi/$pipe/mira220-sync.json" ] ||
            die "no mira220-sync.json tuning link for $pipe"
    done
fi
