#!/usr/bin/env bash
# Build, assemble and sign a release "Shiibar GH.app" into <out_dir>, for
# .github/workflows/release.yml. CFBundleShortVersionString and
# CFBundleVersion are both <version> (docs/tasks/M3.md, "Version numbers").
# Every executable gets the hardened runtime and a secure timestamp, which
# notarization requires.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"

VERSION="${1:?usage: build-release-app.sh <version> <out_dir>}"
OUT_DIR="${2:?usage: build-release-app.sh <version> <out_dir>}"
APP_PATH="$OUT_DIR/$APP_NAME"
mkdir -p "$OUT_DIR"

echo "==> Building shiibar-ghd and shiibar-gh (release)"
(cd "$ROOT" && cargo build --release --locked -p shiibar-ghd -p shiibar-gh)
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

echo "==> Building the app (release)"
(cd "$ROOT/app" && swift build -c release)
APP_BIN_DIR="$(cd "$ROOT/app" && swift build -c release --show-bin-path)"

echo "==> Assembling $APP_PATH (version $VERSION)"
assemble_app_bundle \
  "$APP_PATH" \
  "$APP_BIN_DIR/$APP_EXECUTABLE" \
  "$TARGET_DIR/release/shiibar-ghd" \
  "$TARGET_DIR/release/shiibar-gh" \
  "$VERSION" \
  "$VERSION"

# SHIIBAR_GH_SIGN_IDENTITY wins when set (CI passes the imported identity's
# hash). Otherwise the keychain's Developer ID Application identity.
if [ -n "${SHIIBAR_GH_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$SHIIBAR_GH_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]+)[[:space:]].*$/\1/')"
  if [ -z "$IDENTITY" ]; then
    echo "error: no 'Developer ID Application' identity, and SHIIBAR_GH_SIGN_IDENTITY is not set" >&2
    exit 1
  fi
fi

echo "==> Signing with $IDENTITY (hardened runtime, secure timestamp)"
sign_app_bundle "$IDENTITY" "$APP_PATH" --options runtime --timestamp
codesign --verify --deep --strict "$APP_PATH"
echo "Built $APP_PATH"
