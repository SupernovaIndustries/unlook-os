# keys/

Only **public** trust anchors may ever be committed here, and none are yet.

- `keys/dev/` — created by `scripts/dev-keys.sh`, git-ignored, development only.
- `keys/ci/` — written by CI from protected file variables, git-ignored.
- Production: the CA and signing keys stay offline (or in an HSM); CI gets
  the signing key only on protected tags. See docs/OS.md §9.

The build needs, in `$KEYS_DIR`:
- `rauc-keyring.pem` — CA certificate(s) the unit trusts for RAUC bundles.
- `apt-archive-keyring.gpg` — public key of the Unlook apt repository.
