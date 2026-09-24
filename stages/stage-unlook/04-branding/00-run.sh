#!/bin/bash -e
# Supernova / Unlook boot splash (Plymouth). Installed only when branding/assets/
# holds the artwork (branding/README.md); otherwise the image boots with a plain
# console and nothing here runs.
# shellcheck source=../../../scripts/lib.sh
. "${STAGE_DIR}/lib.sh"
conf_load "${STAGE_DIR}/unlook-os.conf"

A="files/assets"
if [ "${BRANDING}" != auto ] || [ ! -f "$A/background.png" ]; then
    log "branding: no branding/assets/background.png -- splash not installed"
    exit 0
fi
f="$A/background.png"
[ "$(head -c 8 "$f" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] || die "branding: $f is not a PNG"
[ "$(stat -c %s "$f")" -le 8388608 ] || die "branding: $f larger than 8 MiB"

T="${ROOTFS_DIR}/usr/share/plymouth/themes/unlook"
on_chroot << 'EOF'
set -e
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends plymouth
EOF
install -d "$T"
install -m 0644 "$A/background.png" "$T/background.png"
install -m 0644 files/unlook.plymouth "$T/unlook.plymouth"
install -m 0644 files/unlook.script "$T/unlook.script"
on_chroot << 'EOF'
set -e
plymouth-set-default-theme unlook
update-initramfs -u -k all
EOF

# Quiet, splash-only boot on HDMI/DSI; the serial rescue console stays verbose.
sed -i 's/$/ quiet splash plymouth.ignore-serial-consoles logo.nologo vt.global_cursor_default=0/' \
    "${ROOTFS_DIR}/usr/lib/unlook-os/cmdline.txt.in"
log "branding: Plymouth theme 'unlook' installed"
