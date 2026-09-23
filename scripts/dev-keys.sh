#!/bin/sh
# Throw-away DEVELOPMENT signing material in keys/dev/ (git-ignored):
#   rauc-ca.{key,pem}            dev CA (rauc-keyring.pem is its certificate)
#   rauc-signing.{key,crt}       bundle signing key / cert (codeSigning EKU)
#   apt-signing.asc              apt repository secret key (reprepro)
#   apt-archive-keyring.gpg      apt repository public keyring (goes into the image)
#
# Images built with these keys report KEYRING_KIND=dev and accept ONLY bundles
# and packages signed with these keys. Never ship them. Production keys:
# docs/OS.md §9.
set -eu
TOP="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$TOP/keys/dev"
if [ -e "$DEST" ]; then
    for f in rauc-ca.key rauc-keyring.pem rauc-signing.key rauc-signing.crt apt-signing.asc apt-archive-keyring.gpg; do
        [ -s "$DEST/$f" ] || { echo "keys/dev is incomplete (no $f): remove it and run again" >&2; exit 1; }
    done
    echo "keys/dev already exists"
    exit 0
fi
umask 077
# Built in a scratch dir and renamed into place: an interrupted run never leaves
# a half set of keys that later steps would take for a complete one.
D="$(mktemp -d "$TOP/keys/dev.tmp.XXXXXX")"
G="$(mktemp -d)"
trap 'rm -rf "$D" "$G"' EXIT

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -days 3650 \
    -subj "/O=Supernova Industries/CN=Unlook OS DEV bundle CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$D/rauc-ca.key" -out "$D/rauc-ca.pem"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes \
    -subj "/O=Supernova Industries/CN=Unlook OS DEV bundle signing" \
    -keyout "$D/rauc-signing.key" -out "$D/rauc-signing.csr"
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > "$D/ext.cnf"
openssl x509 -req -in "$D/rauc-signing.csr" -CA "$D/rauc-ca.pem" -CAkey "$D/rauc-ca.key" \
    -CAcreateserial -days 1825 -extfile "$D/ext.cnf" -out "$D/rauc-signing.crt"
rm -f "$D/rauc-signing.csr" "$D/ext.cnf"
cp "$D/rauc-ca.pem" "$D/rauc-keyring.pem"

# No pinentry in the builder container: loopback with an empty passphrase
# (gpg still needs gpg-agent for key generation: docker/Dockerfile installs it).
GNUPGHOME="$G" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Unlook DEV apt repository <dev-apt@supernovaindustries.invalid>" ed25519 sign 3y
GNUPGHOME="$G" gpg --batch --export > "$D/apt-archive-keyring.gpg"
GNUPGHOME="$G" gpg --batch --pinentry-mode loopback --passphrase '' \
    --armor --export-secret-keys > "$D/apt-signing.asc"
chmod 0644 "$D/rauc-keyring.pem" "$D/apt-archive-keyring.gpg"
chmod 0700 "$D"
mv "$D" "$DEST"
echo "dev keys in $DEST"
echo "  export RAUC_SIGNING_CERT=$DEST/rauc-signing.crt RAUC_SIGNING_KEY=$DEST/rauc-signing.key"
