#!/bin/bash -e
# Remove what an appliance must not run: remote-access agents,
# the first-boot user wizard, modem management, swap on eMMC, periodic apt.
on_chroot << 'EOF'
set -e
# userconf-pi stays: Raspberry Pi Imager customisation uses it (its wizard is masked).
# avahi-daemon stays (NET_MDNS: <hostname>.local only, configured in 03-system).
for p in rpi-connect rpi-connect-lite modemmanager triggerhappy dphys-swapfile; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p"
    fi
done
for u in apt-daily.timer apt-daily-upgrade.timer man-db.timer ssh.service ssh.socket regenerate_ssh_host_keys.service; do
    systemctl disable "$u" >/dev/null 2>&1 || true
done
# sshswitch enables sshd when /boot/firmware/ssh exists; SSH is switched by unlook-ssh only.
for u in sshswitch.service userconfig.service; do
    systemctl mask "$u" >/dev/null 2>&1 || true
done
EOF
