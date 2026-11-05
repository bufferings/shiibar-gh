# shellcheck shell=bash
# Stopping a running "Shiibar GH.app" and its daemon before the bundle is
# replaced, so the new build does not attach to a daemon of the old one: the
# development and release builds carry the same version (docs/tasks/M3.md,
# "Version numbers"). Sourced; expects BUNDLE_ID and APP_EXECUTABLE from
# scripts/lib/bundle.sh.
#
# Processes are found by a literal substring of their command line, never a
# regular expression, so any character in the app path matches itself.

# pids_matching <text>
#
# The PIDs of this user's processes whose command line contains <text>,
# one per line. `ps -ww` prints whole command lines ("If the -w option is
# specified more than once, ps will use as many columns as necessary",
# ps(1) on macOS), `-x` includes processes without a terminal, and `-U`
# keeps to the current user. The text reaches awk through ENVIRON, which
# keeps backslashes as they are (`awk -v` would process escapes), and only
# the command line column is compared. This shell is left out; ps and awk
# never match, because the text is not in their command lines.
pids_matching() {
  ps -ww -x -U "$(id -u)" -o pid=,args= \
    | MATCH_TEXT="$1" MATCH_SELF="$$" awk '{
        pid = $1
        args = $0
        sub(/^[ \t]*[0-9]+[ \t]+/, "", args)
        if (pid != ENVIRON["MATCH_SELF"] && index(args, ENVIRON["MATCH_TEXT"]) > 0) print pid
      }'
}

# running <text>: some process's command line contains <text>.
running() {
  [ -n "$(pids_matching "$1")" ]
}

# signal_matching <signal> <text>
signal_matching() {
  local pid
  for pid in $(pids_matching "$2"); do
    kill "-$1" "$pid" 2>/dev/null || true
  done
}

# wait_for_gone <text> <attempts of 0.2 seconds>
wait_for_gone() {
  local text="$1" attempts="$2" i
  for ((i = 0; i < attempts; i++)); do
    if ! running "$text"; then
      return 0
    fi
    sleep 0.2
  done
  ! running "$text"
}

# stop_app_and_daemon <app_path>
#
# Quit the app (it shuts its daemon down), then make sure the daemon is
# gone: a `shutdown` request on the socket, then SIGTERM, then SIGKILL. The
# daemon saves every change to SQLite before answering, so stopping it is
# safe.
stop_app_and_daemon() {
  local app_path="$1"
  local app_text="$app_path/Contents/MacOS/$APP_EXECUTABLE"
  local daemon_text="$app_path/Contents/Helpers/shiibar-ghd --foreground"
  local state_dir="${SHIIBAR_GH_STATE_DIR:-$HOME/.local/state/shiibar-gh}"
  local socket="$state_dir/shiibar-ghd.sock"

  if running "$app_text"; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    if ! wait_for_gone "$app_text" 25; then
      echo "warning: the app is still running 5 s after the quit request" >&2
    fi
  fi

  if running "$daemon_text" && [ -S "$socket" ]; then
    printf '{"cmd":"shutdown"}\n' | nc -U -w 2 "$socket" >/dev/null 2>&1 || true
  fi
  if ! wait_for_gone "$daemon_text" 15; then
    echo "warning: the daemon did not stop on request; sending SIGTERM" >&2
    signal_matching TERM "$daemon_text"
    if ! wait_for_gone "$daemon_text" 10; then
      echo "warning: the daemon survived SIGTERM; sending SIGKILL" >&2
      signal_matching KILL "$daemon_text"
    fi
  fi
}
