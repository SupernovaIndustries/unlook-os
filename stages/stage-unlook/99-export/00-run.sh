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
[ ! -e "${R}/etc/systemd/system/multi-user.target.wants/ssh.service" ] || die "ssh.service is enabled"
[ ! -e "${R}/etc/systemd/system/sockets.target.wants/ssh.socket" ] || die "ssh.socket is enabled"
[ ! -e "${R}/usr/sbin/avahi-daemon" ] || die "avahi-daemon is installed"
grep -q "^${ADMIN_USER}:!" "${R}/etc/shadow" || die "${ADMIN_USER} password is not locked"
grep -q '^root:[!*]' "${R}/etc/shadow" || die "root password is not locked"
[ -s "${R}/etc/rauc/keyring.pem" ] || die "no RAUC keyring"
[ -s "${R}/usr/share/keyrings/unlook-archive-keyring.gpg" ] || die "no apt keyring"

tar -C "${R}" --numeric-owner --xattrs --xattrs-include='*' --acls -cf "${DEPLOY_DIR}/${IMG_NAME}-rootfs.tar" .
log "rootfs exported to ${DEPLOY_DIR}/${IMG_NAME}-rootfs.tar"
