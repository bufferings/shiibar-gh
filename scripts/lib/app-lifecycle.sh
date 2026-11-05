# shellcheck shell=bash
# Stopping a running "Shiibar GH.app" and its daemon before the bundle is
# replaced, so the new build does not attach to a daemon of the old one: the
# development and release builds carry the same version (docs/tasks/M3.md,
# "Version numbers"). Sourced; expects BUNDLE_ID from scripts/lib/bundle.sh.

# ere_escape <text>
#
# The text as a literal in an extended regular expression: pgrep and pkill
# read their pattern as one ("they are used as extended regular expressions",
# pgrep(1) on macOS). Without this, `.` in "Shiibar GH.app" matches any
# character, and a path with ( ) + [ * ? ^ $ | { } or \ can fail to match, so
# the old daemon would keep running.
ere_escape() {
  printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'
}

# wait_for_gone <pgrep -f pattern> <attempts of 0.2 seconds>
wait_for_gone() {
  local pattern="$1" attempts="$2" i
  for ((i = 0; i < attempts; i++)); do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  ! pgrep -f "$pattern" >/dev/null 2>&1
}

# stop_app_and_daemon <app_path>
#
# Quit the app (it shuts its daemon down), then make sure the daemon is
# gone: a `shutdown` request on the socket, then SIGTERM, then SIGKILL. The
# daemon saves every change to SQLite before answering, so stopping it is
# safe.
stop_app_and_daemon() {
  local app_path="$1"
  local app_pattern daemon_pattern
  app_pattern="$(ere_escape "$app_path/Contents/MacOS/$APP_EXECUTABLE")"
  daemon_pattern="$(ere_escape "$app_path/Contents/Helpers/shiibar-ghd") --foreground"
  local state_dir="${SHIIBAR_GH_STATE_DIR:-$HOME/.local/state/shiibar-gh}"
  local socket="$state_dir/shiibar-ghd.sock"

  if pgrep -f "$app_pattern" >/dev/null 2>&1; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    if ! wait_for_gone "$app_pattern" 25; then
      echo "warning: the app is still running 5 s after the quit request" >&2
    fi
  fi

  if pgrep -f "$daemon_pattern" >/dev/null 2>&1 && [ -S "$socket" ]; then
    printf '{"cmd":"shutdown"}\n' | nc -U -w 2 "$socket" >/dev/null 2>&1 || true
  fi
  if ! wait_for_gone "$daemon_pattern" 15; then
    echo "warning: the daemon did not stop on request; sending SIGTERM" >&2
    pkill -f "$daemon_pattern" 2>/dev/null || true
    if ! wait_for_gone "$daemon_pattern" 10; then
      echo "warning: the daemon survived SIGTERM; sending SIGKILL" >&2
      pkill -9 -f "$daemon_pattern" 2>/dev/null || true
    fi
  fi
}
