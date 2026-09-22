#!/bin/bash -e
# Unlook OS system layer: overlay files, boot configuration, partition mounts,
# users, services. Everything derives from unlook-os.conf.
# shellcheck source=../lib.sh
. "${STAGE_DIR}/lib.sh"
conf_load "${STAGE_DIR}/unlook-os.conf"
conf_validate
# shellcheck source=/dev/null
. "${STAGE_DIR}/build-info.env"

R="${ROOTFS_DIR}"
OVL="${STAGE_DIR}/overlay"

# ---- template values ------------------------------------------------------------
UNLOOK_APT_HOST="${UNLOOK_APT_URL#https://}"
UNLOOK_APT_HOST="${UNLOOK_APT_HOST%%/*}"
UNLOOK_APT_HOST="${UNLOOK_APT_HOST%%:*}"
FW_TCP_PORTS_NFT="$(printf '%s' "${FW_TCP_PORTS}" | tr -s ' ' | sed 's/ /, /g')"
TEMPLATE_KEYS="ADMIN_USER USB_GADGET_ADDRESS FW_TCP_PORTS_NFT RAUC_COMPATIBLE UNLOOK_APT_HOST
    UNLOOK_APT_URL UNLOOK_APT_SUITE UNLOOK_APT_COMPONENT UNLOOK_OTA_URL SDK_PACKAGE
    HEALTH_TIMEOUT_S TRYBOOT_GUARD_S SDK_OTA_SOURCE SDK_GIT_URL SDK_GIT_BRANCH SDK_GIT_REQUIRE_SIGNED"

render() {
    for k in ${TEMPLATE_KEYS}; do
        v="${!k}"
        case "$v" in *'|'* | *'\'* | *'&'*) die "template value $k has forbidden characters" ;; esac
        sed -i "s|@${k}@|${v}|g" "$1"
    done
    if grep -nE '@[A-Z][A-Z0-9_]*@' "$1"; then
        die "unrendered placeholder in $1"
    fi
}

# ---- overlay (explicit manifest: mode + template flag per file) -----------------------
while read -r mode flags path; do
    case "$mode" in '' | '#'*) continue ;; esac
    require_match "manifest mode" "$mode" '0[0-7]{3}'
    [ -f "${OVL}${path}" ] || die "overlay.manifest lists a missing file: ${path}"
    install -D -m "$mode" -o root -g root "${OVL}${path}" "${R}${path}"
    [ "$flags" = t ] && render "${R}${path}"
done < "${STAGE_DIR}/overlay.manifest"
# No stray overlay file may bypass the manifest.
( cd "$OVL" && find . -type f | sed 's|^\.||' ) | while read -r f; do
    grep -q " ${f}\$" "${STAGE_DIR}/overlay.manifest" || die "overlay file not in manifest: $f"
done

# Final apt source (the build may have used local .debs only). No URL = the SDK
# network channel is off: no source, no pinning, unlook-ota reports it.
if [ -n "${UNLOOK_APT_URL}" ]; then
    install -D -m 0644 "${R}/usr/share/unlook-os/apt-sources.d/unlook.sources" "${R}/etc/apt/sources.list.d/unlook.sources"
else
    rm -f "${R}/usr/share/unlook-os/apt-sources.d/unlook.sources" "${R}/etc/apt/preferences.d/unlook" \
        "${R}/etc/apt/sources.list.d/unlook.sources"
    log "UNLOOK_APT_URL empty: SDK apt channel disabled in this image"
fi

if [ -f "${STAGE_DIR}/03-system/files/OS.md" ]; then
    install -D -m 0644 "${STAGE_DIR}/03-system/files/OS.md" "${R}/usr/share/doc/unlook-os/OS.md"
fi

# ---- release identity ---------------------------------------------------------------
SDK_VERSION="$(dpkg-query --admindir="${R}/var/lib/dpkg" -W -f='${Version}' "${SDK_PACKAGE}" 2>/dev/null || echo none)"
cat > "${R}/etc/unlook-os-release" << EOF
NAME="Unlook OS"
VERSION=${UNLOOK_OS_VERSION}
RAUC_COMPATIBLE=${RAUC_COMPATIBLE}
BASE="Raspberry Pi OS Lite ${UNLOOK_OS_SUITE} arm64"
SDK_PACKAGE=${SDK_PACKAGE}
SDK_VERSION=${SDK_VERSION}
UNLOOK_OS_GIT=${UNLOOK_OS_GIT}
UNLOOK_SDK_GIT=${UNLOOK_SDK_GIT}
PIGEN_SHA=${PIGEN_SHA}
KEYRING_KIND=${KEYRING_KIND}
BUILD_DATE=$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0644 "${R}/etc/unlook-os-release"

# ---- boot configuration (per slot; the bundle's bootfs carries it) -----------------------
{
    echo "# Unlook OS ${UNLOOK_OS_VERSION} -- generated from config/unlook-os.conf at build time."
    echo "# Slot-local: every OS update replaces this file. Do not edit on the unit."
    echo "[all]"
    echo "arm_64bit=1"
    echo "auto_initramfs=1"
    echo "arm_boost=1"
    echo "disable_overscan=1"
    echo "disable_splash=1"
    echo "dtoverlay=vc4-kms-v3d"
    echo "max_framebuffers=2"
    echo "disable_fw_kms_setup=1"
    echo "dtparam=audio=off"
    echo "dtparam=watchdog=on"
    echo "# Cameras: explicit overlays only, never auto-detected."
    echo "camera_auto_detect=0"
    echo "display_auto_detect=1"
    echo "# Camera enable (CAM_GPIO) forced ON for both sensors, before the camera overlays."
    echo "dtoverlay=unlook-cam-enable"
    for o in ${CAMERA_OVERLAYS}; do echo "dtoverlay=${o}"; done
    echo "# AS1170 illuminator + BMI270 IMU: user-space i2c-dev on the ARM I2C bus."
    echo "dtparam=i2c_arm=${I2C_ARM}"
    echo "# Rescue console on the debug UART (serial0)."
    echo "enable_uart=1"
    if [ "${UART_UCP}" = on ]; then
        echo "# UART0 on GPIO14/15 = /dev/ttyAMA0 for the Unlook Command Protocol."
        echo "dtparam=uart0=on"
    fi
    if [ "${USB_GADGET}" = 1 ]; then
        echo "# USB-C in device mode: CDC-ACM + ECM gadget (unlook-usb-gadget.service)."
        echo "dtoverlay=dwc2,dr_mode=peripheral"
    fi
    for o in ${EXTRA_DTOVERLAYS}; do echo "dtoverlay=${o}"; done
} > "${R}/boot/firmware/config.txt"

# Kernel command line template; image/mkimage.sh renders slot A and the RAUC
# hook rewrites root=/rauc.slot= for slot B. No first-boot resize init (the
# data partition is grown by unlook-firstboot), no Imager hooks.
install -d "${R}/usr/lib/unlook-os"
printf '%s\n' "console=serial0,115200 console=tty1 root=PARTLABEL=@ROOT_PARTLABEL@ rootfstype=ext4 fsck.repair=yes rootwait rauc.slot=@SLOT@ panic=10 cfg80211.ieee80211_regdom=${WPA_COUNTRY}" \
    > "${R}/usr/lib/unlook-os/cmdline.txt.in"

# ---- partitions ---------------------------------------------------------------------
cat > "${R}/etc/fstab" << 'EOF'
# Unlook OS -- A/B layout (docs/OS.md §3). The RAUC post-install hook rewrites
# the two slot-specific lines (-a -> -b) when this rootfs is installed into slot B.
PARTLABEL=unlook-root-a  /                 ext4  defaults,noatime,commit=30                      0 1
PARTLABEL=unlook-boot-a  /boot/firmware    vfat  defaults,noatime,nodev,nosuid,noexec,umask=0077  0 2
PARTLABEL=unlook-data    /data             ext4  defaults,noatime,nodev,nosuid,noexec,commit=5    0 2
/data/unlook/etc         /etc/unlook       none  bind,x-systemd.requires-mounts-for=/data         0 0
/data/unlook/var         /var/lib/unlook   none  bind,x-systemd.requires-mounts-for=/data         0 0
/data/journal            /var/log/journal  none  bind,x-systemd.requires-mounts-for=/data         0 0
/data/bluetooth          /var/lib/bluetooth none bind,x-systemd.requires-mounts-for=/data         0 0
EOF
install -d -m 0755 "${R}/data" "${R}/etc/unlook" "${R}/var/log/journal"
install -d -m 0700 "${R}/var/lib/unlook" "${R}/var/lib/bluetooth"

# USB gadget address comes from the build config, not from the script default.
install -D -m 0644 /dev/stdin "${R}/etc/systemd/system/unlook-usb-gadget.service.d/10-unlook-os.conf" << EOF
[Service]
Environment=UNLOOK_USB_ADDRESS=${USB_GADGET_ADDRESS}
EOF

# ---- users and services ---------------------------------------------------------------
on_chroot << EOF
set -e
# Service user for the least-privilege migration of the daemon (docs/SDK_CHANGES.md §5).
id -u ${SERVICE_USER} >/dev/null 2>&1 || useradd --system --home-dir /var/lib/unlook --no-create-home --shell /usr/sbin/nologin ${SERVICE_USER}
for g in video i2c gpio bluetooth netdev dialout; do
    if getent group \$g >/dev/null; then usermod -aG \$g ${SERVICE_USER}; fi
done
# Admin: key-only SSH (unlook-ssh), password locked. Root locked.
usermod -aG adm,systemd-journal ${ADMIN_USER}
passwd -l ${ADMIN_USER}
passwd -l root
systemctl enable unlook-firstboot.service unlook-identity.service unlook-health.service \
    unlook-tryboot-guard.service unlook-ssh.service unlook-ota-provision.service nftables.service \
    NetworkManager.service bluetooth.service
if [ -f /usr/lib/systemd/system/unlook-stream.service ]; then systemctl enable unlook-stream.service; fi
if [ "${USB_GADGET}" = 1 ]; then systemctl enable unlook-usb-gadget.service; else systemctl disable unlook-usb-gadget.service || true; fi
systemctl disable ssh.service ssh.socket >/dev/null 2>&1 || true
rm -f /etc/ssh/ssh_host_*
EOF
