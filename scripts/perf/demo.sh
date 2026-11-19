#!/bin/sh
# The demo mode: the app with made-up data, to try it by hand (drag, scroll,
# read) without touching the real state directory, the Keychain or GitHub.
#
#   1. a dev-ingest shiibar-ghd (no Keychain, no GitHub, no token), built
#      from the working tree (0.8) into $SHIIBAR_GH_PERF_WORK/target-wt
#      (default under /tmp; printed) unless SHIIBAR_GH_PERF_DAEMON names one;
#   2. a release build of the app in the working tree;
#   3. a new state directory under /tmp (the socket path must stay short),
#      filled by `make-data.py --demo`;
#   4. the app in its demo mode (SHIIBAR_GH_DEMO=1, app/Sources/ShiibarGhApp/
#      Perf.swift): a scratch UserDefaults suite, that state directory and
#      daemon, no login item, no notification permission. It runs next to an
#      installed Shiibar GH (a second menu bar icon), which keeps its own
#      state directory and daemon.
#
# Usage: scripts/perf/demo.sh
# Quit with the demo's ⌄ menu › Quit (or Ctrl-C here); the script
# then stops the demo daemon and removes the state directory.
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${SHIIBAR_GH_PERF_WORK:-/tmp/shiibar-gh-perf-work}
mkdir -p "$work"

daemon=${SHIIBAR_GH_PERF_DAEMON:-}
if [ -z "$daemon" ]; then
    # The working tree's daemon (0.8: its schema with the labels and the
    # rows' avatars, the draft rows, Mine's sections, mute rules, team
    # mentions), built out of the repository's target/.
    (cd "$repo" && CARGO_TARGET_DIR="$work/target-wt" cargo build --release -p shiibar-ghd --features dev-ingest)
    daemon="$work/target-wt/release/shiibar-ghd"
fi
echo "demo: daemon $daemon; app $repo/app/.build/release/ShiibarGhApp; builds under $work"
swift build --package-path "$repo/app" -c release
app_bin="$repo/app/.build/release/ShiibarGhApp"

state=$(mktemp -d /tmp/sgdemo.XXXXXX)
cleanup() {
    # The daemon of this state directory, if the app left it running.
    python3 - "$state/shiibar-ghd.sock" <<'PY' || true
import socket, sys
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5)
        s.connect(sys.argv[1])
        s.sendall(b'{"cmd":"shutdown"}\n')
        s.recv(4096)
except OSError:
    pass
PY
    rm -rf "$state"
}
trap cleanup EXIT INT TERM
python3 "$repo/scripts/perf/make-data.py" "$daemon" "$state" --demo

echo "demo: running with state directory $state; quit from the demo's menu (⌄ › Quit) or press Ctrl-C"
SHIIBAR_GH_DEMO=1 \
SHIIBAR_GH_STATE_DIR="$state" \
SHIIBAR_GH_PERF_DAEMON="$daemon" \
    "$app_bin"
