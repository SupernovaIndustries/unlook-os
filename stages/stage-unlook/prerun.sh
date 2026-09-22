#!/bin/bash -e
# pi-gen stage: Unlook OS on top of stage2 (Raspberry Pi OS Lite).
if [ ! -d "${ROOTFS_DIR}" ]; then
    copy_previous
fi
