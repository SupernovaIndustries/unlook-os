#!/bin/sh
# Raspberry Pi Imager catalogue for the built image, so Imager offers its
# "OS customisation" (user/password, SSH, Wi-Fi, hostname, locale) -- which it
# never does for a plain "Use custom" image.
#
#   scripts/imager-manifest.sh [deploy dir] [base URL]
#     -> deploy/unlook-os.json  (os_list with init_format "systemd")
#
# Without a base URL the entry points at the local file (file://…), so run it on
# the machine that will flash (scripts/docker-build.sh does it on the host).
# Open it in Imager: App Options -> Content repository -> Use custom file, or
#   rpi-imager --repo deploy/unlook-os.json
set -eu
TOP="$(cd "$(dirname "$0")/.." && pwd)"
D="${1:-$TOP/deploy}"
BASE_URL="${2:-}"
D="$(cd "$D" && pwd)"

# shellcheck disable=SC2012 # newest by mtime; names are our own <img>.imageinfo
info="$(ls -t "$D"/*.imageinfo 2>/dev/null | head -n 1)"
[ -n "$info" ] || { echo "no *.imageinfo in $D (build the image first)" >&2; exit 1; }
get() { sed -n "s/^$1=//p" "$info" | head -n 1; }
# RFC 3986 path encoding (spaces, non-ASCII, quotes...): the result is a valid
# URL and needs no JSON escaping.
url_path() {
    printf '%s' "$1" | od -An -v -tx1 | awk '
        BEGIN { for (i = 0; i < 256; i++) n[sprintf("%02x", i)] = i
                safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._~-" }
        { for (f = 1; f <= NF; f++) {
            c = n[$f]
            if (c > 32 && c < 127 && index(safe, sprintf("%c", c))) printf "%c", c
            else printf "%%%s", toupper($f) } }'
}
IMG="$(get image)"
VER="$(get version)"
for v in "$IMG" "$VER" "$(get extract_size)" "$(get extract_sha256)" "$(get image_download_size)" "$(get image_download_sha256)"; do
    printf '%s' "$v" | grep -Eq '^[A-Za-z0-9._~+-]+$' || { echo "bad value in $info" >&2; exit 1; }
done
[ -f "$D/$IMG" ] || { echo "missing $D/$IMG" >&2; exit 1; }
if [ -n "$BASE_URL" ]; then
    printf '%s' "$BASE_URL" | grep -Eq '^https://[A-Za-z0-9.:/_~-]+$' || { echo "base URL must be https://…" >&2; exit 1; }
    URL="${BASE_URL%/}/$IMG"
else
    URL="file://$(url_path "$D/$IMG")"
fi

OUT="$D/unlook-os.json"
cat > "$OUT" << EOF
{
  "imager": {
    "latest_version": "0.0.0"
  },
  "os_list": [
    {
      "name": "Unlook OS $VER",
      "description": "Supernova Industries Unlook 3D scanner (Raspberry Pi CM5 / Pi 5, 64-bit). A/B updates; OS customisation supported.",
      "url": "$URL",
      "extract_size": $(get extract_size),
      "extract_sha256": "$(get extract_sha256)",
      "image_download_size": $(get image_download_size),
      "image_download_sha256": "$(get image_download_sha256)",
      "release_date": "$(get release_date)",
      "init_format": "systemd"
    }
  ]
}
EOF
echo "Imager catalogue: $OUT"
echo "  Imager -> App Options -> Content repository -> Use custom file -> $OUT"
