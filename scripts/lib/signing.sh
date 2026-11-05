# shellcheck shell=bash
# The local code-signing identity of development builds, sourced by
# scripts/dev-install.sh and scripts/dev-uninstall.sh. A self-signed
# certificate gives every rebuild the same designated requirement, so the
# Keychain and notification permissions survive a rebuild; an ad hoc
# signature is tied to one build (Apple TN3127, docs/DESIGN.md,
# "Distribution and signing").
SIGNING_IDENTITY_CN="shiibar-gh-local-signing"

# The identity's hash, so codesign is never ambiguous about which
# certificate it uses.
find_signing_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "$SIGNING_IDENTITY_CN" \
    | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]+)[[:space:]].*$/\1/'
}
