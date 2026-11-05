#!/usr/bin/env bash
# Development install: build the daemon, the CLI and the app in release
# mode, assemble "Shiibar GH.app" in ~/Applications, sign it with the fixed
# local signing identity (created once, in the login keychain), point
# ~/.local/bin/shiibar-gh at the bundled CLI, and launch the app. The app
# starts the bundled daemon itself; there is no launchd job.
#
# This changes ~/Applications, the login keychain (the signing identity) and,
# through the app's first launch, the login items. It is run by the owner,
# never by an agent or a test (docs/tasks/M3.md, "How to test").

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${SHIIBAR_GH_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${SHIIBAR_GH_APP_DIR:-$HOME/Applications}"

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"
# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"
# shellcheck source=scripts/lib/app-lifecycle.sh
source "$ROOT/scripts/lib/app-lifecycle.sh"

APP_PATH="$APP_DIR/$APP_NAME"
# The same version as a release (the app and the daemon compare it), and a
# fresh CFBundleVersion per install: LaunchServices and the icon cache key on
# the bundle id and version, so a constant one keeps stale icons.
VERSION="$(read_workspace_version "$ROOT/Cargo.toml")"
BUILD_STAMP="$(date +%Y%m%d%H%M%S)"

echo "==> Building shiibar-ghd and shiibar-gh (release)"
(cd "$ROOT" && cargo build --release --locked -p shiibar-ghd -p shiibar-gh)
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

echo "==> Building the app (release)"
(cd "$ROOT/app" && swift build -c release)
APP_BIN_DIR="$(cd "$ROOT/app" && swift build -c release --show-bin-path)"

echo "==> Stopping the running app and daemon, if any"
stop_app_and_daemon "$APP_PATH"

echo "==> Assembling $APP_PATH (version $VERSION, build $BUILD_STAMP)"
mkdir -p "$APP_DIR"
assemble_app_bundle \
  "$APP_PATH" \
  "$APP_BIN_DIR/$APP_EXECUTABLE" \
  "$TARGET_DIR/release/shiibar-ghd" \
  "$TARGET_DIR/release/shiibar-gh" \
  "$VERSION" \
  "$BUILD_STAMP"

echo "==> Signing with the local identity $SIGNING_IDENTITY_CN"
SIGN_ID="$(find_signing_identity || true)"
if [ -z "$SIGN_ID" ]; then
  echo "    creating it (one time; see scripts/lib/make-local-signing-identity.sh)"
  "$ROOT/scripts/lib/make-local-signing-identity.sh" "$SIGNING_IDENTITY_CN" || true
  SIGN_ID="$(find_signing_identity || true)"
fi
if [ -z "$SIGN_ID" ]; then
  echo "error: no '$SIGNING_IDENTITY_CN' code-signing identity. An ad hoc signature" >&2
  echo "would make the Keychain and the notification permission ask again after" >&2
  echo "every rebuild, so this install stops here. Fix the identity (see the" >&2
  echo "messages above) and run this script again." >&2
  exit 1
fi
# The same hardened runtime as a release, so the daemon reads the Keychain
# the way the release does (docs/tasks/M3.md, owner check).
sign_app_bundle "$SIGN_ID" "$APP_PATH" --options runtime
codesign --verify --deep --strict "$APP_PATH"
echo "    signed with $SIGN_ID"

echo "==> Linking $BIN_DIR/shiibar-gh to the bundled CLI"
mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/shiibar-gh"
ln -s "$APP_PATH/Contents/Helpers/shiibar-gh" "$BIN_DIR/shiibar-gh"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "warning: $BIN_DIR is not on PATH" ;;
esac

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP_PATH"
fi

echo "==> Launching $APP_PATH"
open "$APP_PATH"
echo
echo "Installed $APP_PATH and $BIN_DIR/shiibar-gh."
echo "The first launch asks for the notification permission and registers"
echo "Launch at login; macOS may ask you to allow it in System Settings."
