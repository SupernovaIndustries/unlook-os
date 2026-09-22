# shellcheck shell=sh
# Unlook OS runtime helpers, sourced by every unlook-os tool on the unit.
# POSIX sh. All system paths are prefixed with $UNLOOK_OS_TESTROOT so the
# logic can be unit-tested on a build host (tests/unit/).

UOS_ROOT="${UNLOOK_OS_TESTROOT:-}"
UOS_CONF="$UOS_ROOT/etc/unlook-os/os.conf"
UOS_CONF_LOCAL="$UOS_ROOT/etc/unlook/os.conf"
UOS_RELEASE="$UOS_ROOT/etc/unlook-os-release"
UOS_STATE="$UOS_ROOT/var/lib/unlook/ota"
UOS_RUN="$UOS_ROOT/run/unlook/ota"
UOS_PROC="$UOS_ROOT/proc"
UOS_CFG_MNT="$UOS_ROOT/run/unlook/cfg"

uos_log() {
    _lvl="$1"
    shift
    logger -t "${UOS_TAG:-unlook-os}" -p "user.$_lvl" -- "$*" 2>/dev/null || true
    printf '%s: %s\n' "${UOS_TAG:-unlook-os}" "$*" >&2
}

uos_die() {
    uos_log err "$*"
    exit 1
}

# uos_conf KEY DEFAULT REGEX
# Whitelisted read of a key from os.conf (image defaults) and /etc/unlook/os.conf
# (per-unit override on the data partition). The files are never sourced; a
# value that does not match REGEX is rejected and the default is used.
uos_conf() {
    _key="$1"
    _val="$2"
    for _f in "$UOS_CONF" "$UOS_CONF_LOCAL"; do
        [ -f "$_f" ] || continue
        _v="$(sed -n "s/^$_key=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$_f" | tail -n 1)"
        if [ -n "$_v" ]; then
            if printf '%s' "$_v" | grep -Eq "^($3)\$"; then
                _val="$_v"
            else
                uos_log warning "ignoring invalid $_key in $_f"
            fi
        fi
    done
    printf '%s\n' "$_val"
}

uos_release_get() {
    sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$UOS_RELEASE" 2>/dev/null | tail -n 1
}

# ---- boot slots ---------------------------------------------------------------

# Slot we booted from (A|B), from the kernel command line written per slot.
uos_booted_slot() {
    sed -n 's/.*rauc\.slot=\([AB]\).*/\1/p' "$UOS_PROC/cmdline"
}

# True when the firmware booted the [tryboot] section of autoboot.txt.
uos_tryboot_active() {
    _t="$UOS_PROC/device-tree/chosen/bootloader/tryboot"
    [ -f "$_t" ] || return 1
    [ "$(od -An -tu4 --endian=big "$_t" | tr -d ' \n')" = 1 ]
}

uos_other_slot() {
    case "$1" in A) echo B ;; B) echo A ;; *) return 1 ;; esac
}

uos_part_of_slot() {
    case "$1" in
        A) uos_conf BOOT_A_PARTNUM 2 '[0-9]{1,2}' ;;
        B) uos_conf BOOT_B_PARTNUM 3 '[0-9]{1,2}' ;;
        *) return 1 ;;
    esac
}

uos_slot_of_part() {
    if [ "$1" = "$(uos_part_of_slot A)" ]; then
        echo A
    elif [ "$1" = "$(uos_part_of_slot B)" ]; then
        echo B
    else
        return 1
    fi
}

# ---- autoboot.txt (partition 1) -------------------------------------------------

uos_cfg_mount() {
    if [ -n "$UOS_ROOT" ]; then
        mkdir -p "$UOS_ROOT/cfg"
        UOS_CFG_DIR="$UOS_ROOT/cfg"
        return 0
    fi
    mkdir -p "$UOS_CFG_MNT"
    if ! mountpoint -q "$UOS_CFG_MNT"; then
        mount -t vfat -o rw,nodev,nosuid,noexec,sync,umask=0077 \
            /dev/disk/by-partlabel/unlook-cfg "$UOS_CFG_MNT" || return 1
    fi
    UOS_CFG_DIR="$UOS_CFG_MNT"
}

uos_cfg_umount() {
    [ -n "$UOS_ROOT" ] && return 0
    sync
    umount "$UOS_CFG_MNT" 2>/dev/null || true
}

# uos_autoboot_get all|tryboot -> boot_partition of that section
uos_autoboot_get() {
    uos_cfg_mount || return 1
    awk -v want="[$1]" '
        /^\[/ { sec = $0; next }
        sec == want && /^boot_partition=/ { sub(/^boot_partition=/, ""); gsub(/\r/, ""); print; exit }
    ' "$UOS_CFG_DIR/autoboot.txt"
}

# uos_autoboot_set <default partition> <tryboot partition>
# Written to a temporary file, flushed, then renamed over the original.
uos_autoboot_set() {
    case "$1$2" in *[!0-9]*) return 1 ;; esac
    uos_cfg_mount || return 1
    _t="$UOS_CFG_DIR/autoboot.new"
    printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=%s\n' "$1" "$2" > "$_t"
    sync
    mv -f "$_t" "$UOS_CFG_DIR/autoboot.txt"
    sync
    uos_log notice "autoboot: default=p$1 tryboot=p$2"
}

# ---- OTA status (read by the SDK: ota_status / ota_* events) ----------------------

# uos_status <state> <channel> <progress 0-100> <version> <error|->
uos_status() {
    mkdir -p "$UOS_RUN"
    _t="$UOS_RUN/status.new"
    {
        echo "state=$1"
        echo "channel=$2"
        echo "progress=$3"
        echo "version=$4"
        echo "error=$5"
        echo "updated=$(date +%s)"
    } > "$_t"
    mv -f "$_t" "$UOS_RUN/status"
    case "$1" in
        done | failed | rolled_back | committed)
            mkdir -p "$UOS_STATE"
            printf '%s %s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$1" "$4" "$5" >> "$UOS_STATE/history"
            cp -f "$UOS_RUN/status" "$UOS_STATE/last" ;;
    esac
}
