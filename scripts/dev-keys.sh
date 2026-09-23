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
D="$TOP/keys/dev"
[ -e "$D/rauc-keyring.pem" ] && { echo "keys/dev already exists"; exit 0; }
umask 077
mkdir -p "$D"

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

G="$(mktemp -d)"
trap 'rm -rf "$G"' EXIT
# No agent / pinentry in the builder container: loopback with an empty passphrase.
GNUPGHOME="$G" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Unlook DEV apt repository <dev-apt@supernovaindustries.invalid>" ed25519 sign 3y
GNUPGHOME="$G" gpg --batch --export > "$D/apt-archive-keyring.gpg"
GNUPGHOME="$G" gpg --batch --pinentry-mode loopback --passphrase '' \
    --armor --export-secret-keys > "$D/apt-signing.asc"
chmod 0644 "$D/rauc-keyring.pem" "$D/apt-archive-keyring.gpg"
echo "dev keys in $D"
echo "  export RAUC_SIGNING_CERT=$D/rauc-signing.crt RAUC_SIGNING_KEY=$D/rauc-signing.key"
