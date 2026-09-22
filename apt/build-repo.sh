#!/bin/sh
# Maintain the signed Unlook apt repository (reprepro) and publish it.
#
#   APT_SIGNING_KEY=<armored secret key file> apt/build-repo.sh <repo dir> [debs...]
#   APT_PUBLISH_TARGET=user@nas:/srv/unlook/apt  (optional: rsync after the update)
#
# Layout served at UNLOOK_APT_URL:  dists/<suite>/...  pool/...  unlook-archive-keyring.gpg
# Release files are signed (InRelease + Release.gpg); units trust only the key in
# /usr/share/keyrings/unlook-archive-keyring.gpg (Signed-By).
set -eu
TOP="$(cd "$(dirname "$0")/.." && pwd)"
. "$TOP/scripts/lib.sh"
conf_load "$TOP/config/unlook-os.conf"

REPO="${1:?repo dir}"
shift
[ $# -gt 0 ] || set -- "$TOP"/debs/*.deb
KEYFILE="${APT_SIGNING_KEY:?APT_SIGNING_KEY not set}"
command -v reprepro >/dev/null || die "reprepro not installed"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --import "$KEYFILE"
FPR="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/ {print $10; exit}')"
[ -n "$FPR" ] || die "no secret key in APT_SIGNING_KEY"

mkdir -p "$REPO/conf"
cat > "$REPO/conf/distributions" << EOF
Origin: Supernova Industries
Label: Unlook
Codename: $UNLOOK_APT_SUITE
Architectures: arm64
Components: $UNLOOK_APT_COMPONENT
Description: Unlook SDK and support packages
SignWith: $FPR
EOF
for d in "$@"; do
    [ -f "$d" ] || die "no such package: $d"
    reprepro -b "$REPO" --component "$UNLOOK_APT_COMPONENT" includedeb "$UNLOOK_APT_SUITE" "$d"
done
reprepro -b "$REPO" export "$UNLOOK_APT_SUITE"
gpg --batch --export "$FPR" > "$REPO/unlook-archive-keyring.gpg"
reprepro -b "$REPO" list "$UNLOOK_APT_SUITE"

if [ -n "${APT_PUBLISH_TARGET:-}" ]; then
    rsync -a --delete-after "$REPO/dists" "$REPO/pool" "$REPO/unlook-archive-keyring.gpg" "$APT_PUBLISH_TARGET/"
    log "published to $APT_PUBLISH_TARGET"
fi
