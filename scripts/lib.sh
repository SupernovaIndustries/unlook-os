# shellcheck shell=sh
# Build-side helpers shared by build.sh, image/, rauc/, apt/ and the pi-gen
# stage scripts. POSIX sh. Never executed on the unit.

log() { printf '[unlook-os] %s\n' "$*" >&2; }
die() { printf '[unlook-os] ERROR: %s\n' "$*" >&2; exit 1; }

# conf_load <file>
# Loads a KEY=value configuration file after proving it contains nothing but
# comments, blank lines and plain assignments (no command substitution, no
# expansions, no command separators), so sourcing it cannot run code. Each key
# may then be overridden by an environment variable of the same name, which is
# held to the same character rules.
conf_load() {
    _f="$1"
    [ -f "$_f" ] || die "config not found: $_f"
    _bad="$(grep -nvE '^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*=("[^"$`\\]*"|[^[:space:]"$`\\;|&<>()'"'"']*)$' "$_f" || true)"
    [ -z "$_bad" ] || die "unsafe line(s) in $_f: $_bad"
    _keys="$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$_f")"
    # Environment overrides win over the file; remember them before sourcing.
    _ov=""
    for _k in $_keys; do
        eval "_isset=\${$_k+x}"
        # shellcheck disable=SC2154
        if [ -n "$_isset" ]; then
            eval "_v=\${$_k}"
            # shellcheck disable=SC2154
            case "$_v" in
                *'$'* | *'`'* | *'\'* | *'"'* | *"'"* | *';'* | *'|'* | *'&'* | *'<'* | *'>'*)
                    die "unsafe characters in environment override $_k" ;;
            esac
            _ov="$_ov $_k"
            eval "_ovval_$_k=\${$_k}"
        fi
    done
    # shellcheck disable=SC1090
    . "$_f"
    for _k in $_ov; do
        eval "$_k=\${_ovval_$_k}"
    done
    for _k in $_keys; do
        # shellcheck disable=SC2163
        export "$_k"
    done
}

# require_uint <name> <value> <min> <max>
require_uint() {
    case "$2" in '' | *[!0-9]*) die "$1 must be an unsigned integer (got '$2')" ;; esac
    [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || die "$1=$2 outside [$3, $4]"
}

# require_match <name> <value> <extended regex>
require_match() {
    case "$2" in *'
'*) die "$1 contains a newline" ;; esac
    printf '%s\n' "$2" | grep -Eq "^($3)\$" || die "$1='$2' does not match /$3/"
}

# conf_validate: range/format checks on every build knob (CLAUDE.md rule 8).
conf_validate() {
    require_match IMG_NAME "$IMG_NAME" '[a-z0-9][a-z0-9-]{0,31}'
    require_match UNLOOK_OS_VERSION "$UNLOOK_OS_VERSION" '[0-9]+\.[0-9]+\.[0-9]+([~+][A-Za-z0-9.]+)?'
    require_match RAUC_COMPATIBLE "$RAUC_COMPATIBLE" '[a-z0-9][a-z0-9-]{0,63}'
    require_match UNLOOK_OS_SUITE "$UNLOOK_OS_SUITE" 'bookworm|trixie'
    require_match PIGEN_REF "$PIGEN_REF" '[A-Za-z0-9._/-]{1,80}'
    require_match WPA_COUNTRY "$WPA_COUNTRY" '[A-Z]{2}'
    require_match ADMIN_USER "$ADMIN_USER" '[a-z][a-z0-9-]{0,30}'
    require_match SERVICE_USER "$SERVICE_USER" '[a-z][a-z0-9-]{0,30}'
    [ "$ADMIN_USER" != "$SERVICE_USER" ] || die "ADMIN_USER and SERVICE_USER must differ"
    for _o in $CAMERA_OVERLAYS $EXTRA_DTOVERLAYS; do
        require_match "overlay" "$_o" '[A-Za-z0-9_-]+(,[A-Za-z0-9_=.-]+)*'
    done
    require_match MIRA220_DRIVER_DIR "$MIRA220_DRIVER_DIR" '([A-Za-z0-9_][A-Za-z0-9_./-]*)?'
    case "$MIRA220_DRIVER_DIR" in *..*) die "MIRA220_DRIVER_DIR must not contain '..'" ;; esac
    require_match LIBCAMERA_REPO "$LIBCAMERA_REPO" '(https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+)+)?'
    require_match LIBCAMERA_REF "$LIBCAMERA_REF" '([A-Za-z0-9._/-]{1,80})?'
    require_match I2C_ARM "$I2C_ARM" 'on|off'
    require_match UART_UCP "$UART_UCP" 'on|off'
    require_match USB_GADGET "$USB_GADGET" '0|1'
    require_match USB_GADGET_ADDRESS "$USB_GADGET_ADDRESS" '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}'
    for _p in $FW_TCP_PORTS; do require_uint FW_TCP_PORTS "$_p" 1 65535; done
    require_uint PART_CFG_MB "$PART_CFG_MB" 33 256
    require_uint PART_BOOT_MB "$PART_BOOT_MB" 128 1024
    require_uint PART_ROOT_MB "$PART_ROOT_MB" 1536 16384
    require_uint PART_DATA_MB "$PART_DATA_MB" 128 65536
    require_match UNLOOK_APT_URL "$UNLOOK_APT_URL" '(https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*)?'
    require_match UNLOOK_APT_SUITE "$UNLOOK_APT_SUITE" '[a-z]+'
    require_match UNLOOK_APT_COMPONENT "$UNLOOK_APT_COMPONENT" '[a-z]+'
    require_match UNLOOK_OTA_URL "$UNLOOK_OTA_URL" '(https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*)?'
    require_uint HEALTH_TIMEOUT_S "$HEALTH_TIMEOUT_S" 30 900
    require_uint TRYBOOT_GUARD_S "$TRYBOOT_GUARD_S" 120 3600
    [ "$TRYBOOT_GUARD_S" -gt "$HEALTH_TIMEOUT_S" ] || die "TRYBOOT_GUARD_S must exceed HEALTH_TIMEOUT_S"
    require_match SDK_DEB_SOURCE "$SDK_DEB_SOURCE" 'local|apt|none'
    require_match SDK_PACKAGE "$SDK_PACKAGE" '[a-z0-9][a-z0-9.+-]+'
    require_match SDK_OTA_SOURCE "$SDK_OTA_SOURCE" 'github|apt|off'
    require_match SDK_GIT_URL "$SDK_GIT_URL" 'git@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git'
    require_match SDK_GIT_BRANCH "$SDK_GIT_BRANCH" '[A-Za-z0-9._/-]{1,64}'
    require_match SDK_GIT_REQUIRE_SIGNED "$SDK_GIT_REQUIRE_SIGNED" '0|1'
    if [ "$SDK_OTA_SOURCE" = apt ] && [ -z "$UNLOOK_APT_URL" ]; then die "SDK_OTA_SOURCE=apt needs UNLOOK_APT_URL"; fi
    require_match BRANDING "$BRANDING" 'auto|off'
}
