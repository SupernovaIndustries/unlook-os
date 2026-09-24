#!/bin/sh
# QEMU boot test of the OS layer (not of the scanner hardware).
#
#   tests/qemu/boot-test.sh <deploy dir>
#
# QEMU cannot emulate a Pi 5 / CM5, so the image's rootfs is booted on
# `-M virt` with a Debian arm64 kernel (+ its modules added to a TEST copy of
# the rootfs), from the real A/B GPT layout. What it proves: first boot
# provisioning, data-partition mounts, persistent journal, firewall, listening
# ports, SSH off, RAUC + tryboot backend reachable, health check fails
# (no cameras) WITHOUT a reboot loop on a committed slot.
# Needs: docker (arm64 capable: native on the Pi runner, binfmt elsewhere),
# qemu-system-aarch64, xz. KVM is used when /dev/kvm exists (Pi runner).
set -eu
TOP="$(cd "$(dirname "$0")/../.." && pwd)"
. "$TOP/scripts/lib.sh"
conf_load "$TOP/config/unlook-os.conf"
D="${1:?deploy dir}"
V="$(sed -n 's/^UNLOOK_OS_VERSION=//p' "$D/build-info.env")"
Q="$D/qemu"
rm -rf "$Q"
mkdir -p "$Q/kernel" "$Q/extra/usr/lib/unlook-os" "$Q/extra/etc/systemd/system/multi-user.target.wants"

log "fetching a Debian arm64 kernel + initramfs"
docker run --rm --platform linux/arm64 -v "$Q/kernel:/out" debian:bookworm sh -c '
    apt-get -qq update >/dev/null && apt-get -qq install -y --no-install-recommends linux-image-arm64 >/dev/null &&
    cp /boot/vmlinuz-* /out/vmlinuz && cp /boot/initrd.img-* /out/initrd.img &&
    tar -C / -cf /out/modules.tar usr/lib/modules'

cat > "$Q/extra/usr/lib/unlook-os/qemu-check" << 'EOF'
#!/bin/sh
# Runs inside the guest once; prints one verdict line on the serial console.
fails=""
f() { fails="$fails|$1"; }
systemctl is-system-running --wait >/dev/null 2>&1
sleep 20
[ -f /etc/unlook/.firstboot-done ] || f firstboot
[ "$(stat -c '%s %a' /etc/unlook/audit.key 2>/dev/null)" = "32 400" ] || f audit_key
u="$(cat /etc/unlook/unit-id 2>/dev/null)"; [ -n "$u" ] && [ "$(hostname)" = "$u" ] || f hostname
for m in /data /etc/unlook /var/lib/unlook /var/log/journal /var/lib/bluetooth; do findmnt "$m" >/dev/null || f "mount:$m"; done
[ -d "/var/log/journal/$(cat /etc/machine-id)" ] || f journal_persistent
nft list chain inet unlook input 2>/dev/null | grep -q 'policy drop' || f firewall
# SSH (SSH_DEFAULT=on) and the setup page on the hotspot address are expected;
# mDNS (5353) when NET_MDNS=on. Nothing else listens.
for p in $(ss -Htln | awk '{print $4}' | sed 's/.*://' | sort -u); do
    case " @PORTS@ 53 22 @SETUP_PORT@ " in *" $p "*) ;; *) f "tcp_listen:$p" ;; esac
done
for p in $(ss -Hutln | awk '$1=="udp"{print $5}' | sed 's/.*://' | sort -u); do
    case " 53 67 68 546 5353 " in *" $p "*) ;; *) f "udp_listen:$p" ;; esac
done
for a in $(ss -Htln '( sport = :@SETUP_PORT@ )' | awk '{print $4}'); do
    case "$a" in "@AP_IP@:"* | "@AP_IP@%"*) ;; *) f "setup_listen:$a" ;; esac
done
systemctl is-active --quiet ssh.service || f ssh_not_running
[ "$(stat -c %a /etc/unlook/credentials/admin-password 2>/dev/null)" = 600 ] || f admin_password
grep -qx 'UNLOOK_NET_MODE=ap' /run/unlook/net.env || f net_mode_ap
systemctl is-active --quiet unlook-setup.socket || f setup_socket
unlook-ota status --machine | grep -q '^ota_status:' || f ota_status
rauc status --output-format=shell >/dev/null 2>&1 || f rauc_status
[ "$(/usr/lib/unlook-os/rauc-tryboot-backend get-primary)" = A ] || f backend_primary
if [ -z "$fails" ]; then echo "UNLOOK-QEMU-RESULT: PASS"; else echo "UNLOOK-QEMU-RESULT: FAIL $fails"; fi > /dev/ttyAMA0
systemctl poweroff
EOF
sed -i -e "s/@PORTS@/$FW_TCP_PORTS/" -e "s/@SETUP_PORT@/$NET_SETUP_PORT/g" -e "s|@AP_IP@|${NET_AP_ADDRESS%/*}|g" \
    "$Q/extra/usr/lib/unlook-os/qemu-check"
chmod 0755 "$Q/extra/usr/lib/unlook-os/qemu-check"
cat > "$Q/extra/etc/systemd/system/unlook-qemu-check.service" << 'EOF'
[Unit]
Description=Unlook QEMU boot test
After=multi-user.target unlook-health.service
[Service]
Type=oneshot
ExecStart=/usr/lib/unlook-os/qemu-check
[Install]
WantedBy=multi-user.target
EOF
ln -sf ../unlook-qemu-check.service "$Q/extra/etc/systemd/system/multi-user.target.wants/unlook-qemu-check.service"

log "building the test image"
cp "$D/${IMG_NAME}-rootfs.tar" "$Q/rootfs.tar"
tar -Af "$Q/rootfs.tar" "$Q/kernel/modules.tar"
tar -C "$Q/extra" --owner=0 --group=0 -rf "$Q/rootfs.tar" usr etc
docker run --rm -e UNLOOK_OS_VERSION="$V" -e IMG_NAME=unlook-os-qemu -e SOURCE_DATE_EPOCH=0 \
    -v "$TOP:/work" -w /work debian:bookworm sh -c '
    apt-get -qq update >/dev/null && apt-get -qq install -y --no-install-recommends e2fsprogs dosfstools mtools fdisk xz-utils >/dev/null &&
    image/mkimage.sh "'"${Q#"$TOP"/}"'/rootfs.tar" "'"${Q#"$TOP"/}"'"'
xz -d -f "$Q/unlook-os-qemu-$V.img.xz"
IMG="$Q/unlook-os-qemu-$V.img"
truncate -s +2G "$IMG" # room for the first-boot growpart

ACCEL="-accel tcg -cpu cortex-a72"
[ -w /dev/kvm ] && ACCEL="-accel kvm -cpu host"
log "booting ($ACCEL)"
# shellcheck disable=SC2086
timeout 1500 qemu-system-aarch64 -M virt $ACCEL -smp 2 -m 2048 -nographic -no-reboot \
    -kernel "$Q/kernel/vmlinuz" -initrd "$Q/kernel/initrd.img" \
    -append "console=ttyAMA0 root=PARTLABEL=unlook-root-a rootfstype=ext4 rootwait rauc.slot=A panic=10" \
    -drive "file=$IMG,format=raw,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 > "$Q/serial.log" 2>&1 || true

grep -a 'UNLOOK-QEMU-RESULT' "$Q/serial.log" || { tail -n 80 "$Q/serial.log"; die "no verdict (boot hung or crashed)"; }
grep -aq 'UNLOOK-QEMU-RESULT: PASS' "$Q/serial.log"
