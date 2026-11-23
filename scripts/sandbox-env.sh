#!/usr/bin/env bash
# The sandbox: the app on made-up data, isolated from GitHub, the Keychain,
# the real state directory and the installed app's settings, with
# notifications working. For checking the screens by hand and for the
# README's pictures.
#
#   scripts/sandbox-env.sh start <set>   edge-cases or screenshots
#                                        (scripts/lib/make-data.py)
#   scripts/sandbox-env.sh notify        one new event of the set: the app
#                                        shows a notification banner
#   scripts/sandbox-env.sh stop          quits the app and removes what
#                                        start made
#
# start builds a `dev-ingest` daemon and CLI and the app (release), loads
# the set into a new state directory under /tmp (the socket path must stay
# short), assembles an app bundle with its own bundle identifier
# (shiibar.gh.sandbox) around them, and launches it with the app's sandbox
# mode (SHIIBAR_GH_SANDBOX=1, app/Sources/ShiibarGhApp/Perf.swift):
#
# - The bundled daemon is the dev-ingest build that loaded the data: it has
#   no GitHub and only a test Keychain file in the state directory (the
#   data's made-up tokens). A release daemon would read the real Keychain,
#   so the bundle never takes one.
# - The bundle identifier gives the app its own UserDefaults domain and its
#   own notification permission; the first start asks for the permission.
# - The bundle lives in ~/Library/Caches/shiibar.gh.sandbox, where its
#   notification banners were checked to show (macOS 27.2.1, 2026-11-23); an
#   app under /tmp was not tried. It is registered with LaunchServices and
#   launched with `open`, which passes the environment with --env.
# - The sandbox registers no login item, and runs next to an installed
#   Shiibar GH (a second set of menu bar icons) without touching it. Quit
#   the installed app first when its icons must not show in a picture.
#
# SHIIBAR_GH_SANDBOX_REFRESH_SECONDS=5 (0 to 60) holds the answer of Refresh
# for that many seconds, so the turning Refresh icon can be looked at; the
# sandbox's daemon answers at once otherwise.
#
# stop quits the app (as its Quit does, so the daemon stops too), and
# removes the bundle, the state directory and the app's defaults domain.
# The notification permission stays in System Settings › Notifications
# (macOS keeps it after the app is gone); remove it there if needed.
#
# Builds go to $SHIIBAR_GH_PERF_WORK (default /tmp/shiibar-gh-perf-work),
# shared with scripts/perf/measure.sh, never to the repository's target/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"
# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"

SANDBOX_ID="shiibar.gh.sandbox"
SANDBOX_DIR="$HOME/Library/Caches/$SANDBOX_ID"
SANDBOX_APP="$SANDBOX_DIR/$APP_NAME"
# The state directory and the set of a running sandbox, one per line.
POINTER="$SANDBOX_DIR/sandbox"
WORK="${SHIIBAR_GH_PERF_WORK:-/tmp/shiibar-gh-perf-work}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# The state directory of the pointer, checked: a directory that start made.
pointed_state() {
  local state
  state="$(sed -n 1p "$POINTER")"
  case "$state" in
    /tmp/sgsbx.*) ;;
    *) echo "error: $POINTER names '$state', not a sandbox state directory" >&2; exit 1 ;;
  esac
  printf '%s\n' "$state"
}

start() {
  local set="$1"
  case "$set" in
    edge-cases | screenshots) ;;
    *) usage ;;
  esac
  if [ -e "$POINTER" ] || [ -e "$SANDBOX_APP" ]; then
    echo "error: a sandbox is already there ($SANDBOX_DIR); run '$0 stop' first" >&2
    exit 1
  fi

  echo "==> Building the dev-ingest daemon and the CLI (release) under $WORK"
  mkdir -p "$WORK"
  (cd "$ROOT" && CARGO_TARGET_DIR="$WORK/target-wt" cargo build --release --locked \
    -p shiibar-ghd -p shiibar-gh --features shiibar-ghd/dev-ingest)
  local daemon="$WORK/target-wt/release/shiibar-ghd"
  local cli="$WORK/target-wt/release/shiibar-gh"
  echo "==> Building the app (release)"
  swift build --package-path "$ROOT/app" -c release
  local app_bin
  app_bin="$(swift build --package-path "$ROOT/app" -c release --show-bin-path)/$APP_EXECUTABLE"

  local state
  state="$(mktemp -d /tmp/sgsbx.XXXXXX)"
  rmdir "$state"
  echo "==> Loading '$set' into $state"
  # Its dev_* requests succeed only on a dev-ingest build: the daemon that
  # goes into the bundle is checked here.
  if ! python3 "$ROOT/scripts/lib/make-data.py" "$daemon" "$state" "$set"; then
    rm -rf "$state"
    exit 1
  fi

  echo "==> Assembling $SANDBOX_APP ($SANDBOX_ID)"
  mkdir -p "$SANDBOX_DIR"
  printf '%s\n%s\n' "$state" "$set" > "$POINTER"
  # shellcheck disable=SC2034 # read by assemble_app_bundle and sign_app_bundle
  BUNDLE_ID="$SANDBOX_ID"
  assemble_app_bundle "$SANDBOX_APP" "$app_bin" "$daemon" "$cli" \
    "$(read_workspace_version "$ROOT/Cargo.toml")" "$(date +%Y%m%d%H%M%S)"
  # The bundled daemon is the one that loaded the data (before signing,
  # which rewrites the file).
  cmp -s "$daemon" "$SANDBOX_APP/Contents/Helpers/shiibar-ghd"
  local identity
  identity="$(find_signing_identity || true)"
  # Without the local identity an ad hoc signature: the notification
  # permission is then asked again after every start.
  sign_app_bundle "${identity:--}" "$SANDBOX_APP" --options runtime
  codesign --verify --deep --strict "$SANDBOX_APP"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SANDBOX_APP/Contents/Info.plist")" = "$SANDBOX_ID" ]

  "$LSREGISTER" -f "$SANDBOX_APP"
  local env=(--env SHIIBAR_GH_SANDBOX=1 --env "SHIIBAR_GH_STATE_DIR=$state"
    --env "SHIIBAR_GH_DEV_KEYCHAIN=$state/keychain.json")
  if [ -n "${SHIIBAR_GH_SANDBOX_REFRESH_SECONDS:-}" ]; then
    env+=(--env "SHIIBAR_GH_SANDBOX_REFRESH_SECONDS=$SHIIBAR_GH_SANDBOX_REFRESH_SECONDS")
  fi
  echo "==> Launching the sandbox"
  open -n "${env[@]}" "$SANDBOX_APP"
  echo
  echo "The sandbox runs with '$set'. '$0 notify' shows a notification;"
  echo "'$0 stop' quits it and removes it."
}

notify() {
  [ -e "$POINTER" ] || { echo "error: no sandbox; run '$0 start <set>' first" >&2; exit 1; }
  local state set
  state="$(pointed_state)"
  set="$(sed -n 2p "$POINTER")"
  python3 "$ROOT/scripts/lib/make-data.py" --notify "$state" "$set"
}

stop() {
  local state=""
  [ -e "$POINTER" ] && state="$(pointed_state)"
  # SIGTERM quits the sandbox app as its Quit does, the daemon with it.
  if pkill -TERM -f "^$SANDBOX_APP/Contents/MacOS/$APP_EXECUTABLE" 2>/dev/null; then
    for _ in $(seq 1 50); do
      pgrep -f "^$SANDBOX_APP/Contents/" >/dev/null || break
      sleep 0.2
    done
  fi
  if pgrep -f "^$SANDBOX_APP/Contents/" >/dev/null; then
    echo "error: the sandbox app or its daemon is still running; quit it and run '$0 stop' again" >&2
    exit 1
  fi
  if [ -e "$SANDBOX_APP" ]; then
    "$LSREGISTER" -u "$SANDBOX_APP" || true
  fi
  rm -rf "$SANDBOX_DIR"
  [ -n "$state" ] && rm -rf "$state"
  defaults delete "$SANDBOX_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$SANDBOX_ID.plist"
  echo "The sandbox is removed."
}

case "${1:-}" in
  start) [ $# -eq 2 ] || usage; start "$2" ;;
  notify) [ $# -eq 1 ] || usage; notify ;;
  stop) [ $# -eq 1 ] || usage; stop ;;
  *) usage ;;
esac
