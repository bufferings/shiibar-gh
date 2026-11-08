#!/usr/bin/env bash
# Removes what scripts/dev-install.sh set up: the app's login item, the app
# in ~/Applications, the ~/.local/bin/shiibar-gh link, a daemon left
# running, and the local signing identity. The state directory and the
# Keychain tokens stay unless --purge is given; then the state directory,
# the app's UserDefaults and the saved tokens go too.
#
# Run by the owner, never by an agent or a test (docs/tasks/M3.md, "How to
# test"). The notification permission has no command to remove it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *) echo "usage: $(basename "$0") [--purge]" >&2; exit 1 ;;
esac

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"
# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"
# shellcheck source=scripts/lib/app-lifecycle.sh
source "$ROOT/scripts/lib/app-lifecycle.sh"

BIN_DIR="${SHIIBAR_GH_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${SHIIBAR_GH_APP_DIR:-$HOME/Applications}"
APP_PATH="$APP_DIR/$APP_NAME"
STATE_DIR="${SHIIBAR_GH_STATE_DIR:-$HOME/.local/state/shiibar-gh}"

if [ -d "$APP_PATH" ]; then
  echo "==> Stopping the app and its daemon"
  stop_app_and_daemon "$APP_PATH"

  if [ "$PURGE" -eq 1 ] && [ -x "$APP_PATH/Contents/Helpers/shiibar-gh" ]; then
    echo "==> Deleting the saved tokens (token reset deletes the Keychain item)"
    # The daemon is the only one that touches the Keychain, so it does it.
    "$APP_PATH/Contents/Helpers/shiibar-ghd" --foreground 2>/dev/null &
    daemon_pid=$!
    for _ in $(seq 1 50); do
      "$APP_PATH/Contents/Helpers/shiibar-gh" account list >/dev/null 2>&1 && break
      sleep 0.1
    done
    # `token reset` needs readable saved state; an unreadable database is
    # set aside first (the state directory goes below anyway).
    if ! "$APP_PATH/Contents/Helpers/shiibar-gh" token reset; then
      "$APP_PATH/Contents/Helpers/shiibar-gh" reset >/dev/null 2>&1 || true
      "$APP_PATH/Contents/Helpers/shiibar-gh" token reset \
        || echo "    could not delete the Keychain item shiibar-gh / accounts; delete it in Keychain Access"
    fi
    printf '{"cmd":"shutdown"}\n' | nc -U -w 2 "$STATE_DIR/shiibar-ghd.sock" >/dev/null 2>&1 \
      || kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    echo "    a 0.1 Keychain item (shiibar-gh / tokens) is not touched;"
    echo "    delete it in Keychain Access if you want it gone"
  fi

  echo "==> Unregistering the login item"
  # SMAppService.mainApp can only be unregistered from inside the bundle.
  open -W -a "$APP_PATH" --args --unregister-login-item 2>/dev/null || true

  echo "==> Removing $APP_PATH"
  rm -rf "$APP_PATH"
else
  echo "no $APP_PATH; skipping the app"
fi

# A daemon whose socket is gone cannot be asked to stop. The daemon always
# runs as "<path>/Shiibar GH.app/Contents/Helpers/shiibar-ghd --foreground";
# -x matches that whole command line only.
pkill -xf '/.*/Shiibar GH\.app/Contents/Helpers/shiibar-ghd --foreground' || true

if [ -L "$BIN_DIR/shiibar-gh" ] || [ -e "$BIN_DIR/shiibar-gh" ]; then
  rm -f "$BIN_DIR/shiibar-gh"
  echo "removed $BIN_DIR/shiibar-gh"
fi

echo "==> Removing the local signing identity ($SIGNING_IDENTITY_CN)"
security delete-identity -c "$SIGNING_IDENTITY_CN" >/dev/null 2>&1 \
  || security delete-certificate -c "$SIGNING_IDENTITY_CN" >/dev/null 2>&1 \
  || echo "    none found"

if [ "$PURGE" -eq 1 ]; then
  echo "==> Removing $STATE_DIR and the app's UserDefaults"
  rm -rf "$STATE_DIR"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo
echo "The notification permission has no removal command: System Settings ›"
echo "Notifications › Shiibar GH."
