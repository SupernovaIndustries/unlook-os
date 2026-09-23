#!/bin/bash -e
# Replaces pi-gen's export-image: finalise the rootfs and hand it to
# image/mkimage.sh as a tarball (A/B GPT layout is built outside pi-gen).
# shellcheck source=../lib.sh
. "${STAGE_DIR}/lib.sh"
conf_load "${STAGE_DIR}/unlook-os.conf"
R="${ROOTFS_DIR}"

on_chroot << 'EOF'
set -e
if [ -x /etc/init.d/fake-hwclock ]; then /etc/init.d/fake-hwclock stop; fi
if command -v hardlink >/dev/null; then hardlink -t /usr/share/doc >/dev/null; fi
apt-get clean
EOF

# on_chroot leaves proc, dev, dev/pts, sys, run and tmp mounted in the rootfs
# until the stage ends (pi-gen's own export copies with rsync -x). Unmount them
# before cleaning and packing, or the tarball would carry the build host's.
unmount "${R}"
if awk -v r="$(realpath "${R}")/" 'index($2, r) == 1' /proc/mounts | grep -q .; then
    die "file systems still mounted under ${R}"
fi

# pi-gen creates DEPLOY_DIR only in export-image, which this stage replaces.
mkdir -p "${DEPLOY_DIR}"

# Package manifest (SBOM input, CRA technical file) before the lists go.
dpkg-query --admindir="${R}/var/lib/dpkg" -W -f='${Package}\t${Version}\t${Architecture}\n' |
    sort > "${DEPLOY_DIR}/${IMG_NAME}-packages.tsv"

rm -rf "${R}/var/lib/apt/lists/"*
rm -f "${R}/etc/apt/apt.conf.d/51cache"
rm -f "${R}/var/lib/dbus/machine-id"
: > "${R}/etc/machine-id"                  # generated on first boot; the RAUC hook carries it to slot B
rm -f "${R}/etc/ssh/ssh_host_"*            # host keys live on the data partition
: > "${R}/etc/resolv.conf"                 # NetworkManager owns it at runtime
ln -nsf /proc/mounts "${R}/etc/mtab"
rm -rf "${R}/tmp/"* "${R}/var/tmp/"*
find "${R}/var/log" -type f -delete
rm -f "${R}/root/.bash_history" "${R}/home/${ADMIN_USER}/.bash_history"

# Guards: nothing may ship that would open the box.
# wants/ entries are symlinks to absolute /lib/... paths, dangling outside the
# chroot: -e alone would never see them. Test the link (-L) or a file (-e).
for u in multi-user.target.wants/ssh.service sockets.target.wants/ssh.socket; do
    if [ -L "${R}/etc/systemd/system/$u" ] || [ -e "${R}/etc/systemd/system/$u" ]; then
        die "${u##*/} is enabled"
    fi
done
[ ! -e "${R}/usr/sbin/avahi-daemon" ] || die "avahi-daemon is installed"
grep -q "^${ADMIN_USER}:!" "${R}/etc/shadow" || die "${ADMIN_USER} password is not locked"
grep -q '^root:[!*]' "${R}/etc/shadow" || die "root password is not locked"
[ -s "${R}/etc/rauc/keyring.pem" ] || die "no RAUC keyring"
[ -s "${R}/usr/share/keyrings/unlook-archive-keyring.gpg" ] || die "no apt keyring"

tar -C "${R}" --numeric-owner --xattrs --xattrs-include='*' --acls -cf "${DEPLOY_DIR}/${IMG_NAME}-rootfs.tar" .
log "rootfs exported to ${DEPLOY_DIR}/${IMG_NAME}-rootfs.tar"
