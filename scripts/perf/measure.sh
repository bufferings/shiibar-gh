#!/bin/sh
# The speed measurement of docs/tasks/M7.md ("Speed of operation"), the same
# procedure for every build:
#
#   1. a dev-ingest shiibar-ghd (no Keychain, no GitHub), built into
#      $SHIIBAR_GH_PERF_WORK (printed);
#   2. a release (optimized) build of the app;
#   3. a new state directory under /tmp (the socket path must stay short),
#      filled by make-data.py: 200 cards, 3 rows each, file:// avatars;
#   4. the app in its measurement mode (SHIIBAR_GH_PERF=1, app/Sources/
#      ShiibarGhApp/Perf.swift), which starts that daemon, opens the
#      account's window, scrolls, runs every operation 10 times, prints the
#      summary and quits (the daemon with it);
#   5. the state directory is removed.
#
# Usage:
#   scripts/perf/measure.sh            the working tree's app
#   scripts/perf/measure.sh --before   0.4.0 (tag v0.4.0) with only the
#                                      measurement mode added
#                                      (scripts/perf/measure-0.4.patch)
#   scripts/perf/measure.sh --package <dir> <label>
#                                      another copy of the app package
#                                      (for example a snapshot of an earlier
#                                      working tree), summary as <label>
#
# The daemon is the working tree's (0.6) for the working tree and a
# --package copy, and the tag v0.4.0's for --before, unless
# SHIIBAR_GH_PERF_DAEMON names a dev-ingest build. Builds go to
# $SHIIBAR_GH_PERF_WORK (default: a directory under /tmp), never to the
# repository's target/. The summary also goes to
# $SHIIBAR_GH_PERF_WORK/<label>.json.
#
# Never touches the real state directory, the Keychain, GitHub or the
# standard UserDefaults (the app uses a scratch suite and removes it).
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${SHIIBAR_GH_PERF_WORK:-/tmp/shiibar-gh-perf-work}
mkdir -p "$work"
before=false
package=""
[ "${1:-}" = "--before" ] && before=true
if [ "${1:-}" = "--package" ]; then
    package=$(cd "$2" && pwd)
    package_label=$3
fi

daemon=${SHIIBAR_GH_PERF_DAEMON:-}
if [ -z "$daemon" ]; then
    if $before; then
        # 0.4.0: its own daemon, from the tag.
        src="$work/daemon-src"
        if [ ! -d "$src" ]; then
            mkdir -p "$src"
            git -C "$repo" archive v0.4.0 | tar -x -C "$src"
        fi
        (cd "$src" && CARGO_TARGET_DIR="$work/target" cargo build --release -p shiibar-ghd --features dev-ingest)
        daemon="$work/target/release/shiibar-ghd"
    else
        # The working tree's daemon (0.6), built out of the repository's
        # target/.
        (cd "$repo" && CARGO_TARGET_DIR="$work/target-wt" cargo build --release -p shiibar-ghd --features dev-ingest)
        daemon="$work/target-wt/release/shiibar-ghd"
    fi
fi
echo "measure: daemon $daemon; builds under $work" >&2

if $before; then
    label="0.4.0"
    app_src="$work/app-0.4.0"
    rm -rf "$app_src"
    mkdir -p "$app_src"
    git -C "$repo" archive v0.4.0 app | tar -x -C "$app_src"
    (cd "$app_src" && patch -p1 -s < "$repo/scripts/perf/measure-0.4.patch")
    app_pkg="$app_src/app"
elif [ -n "$package" ]; then
    label=$package_label
    app_pkg=$package
else
    label="working-tree"
    app_pkg="$repo/app"
fi
swift build --package-path "$app_pkg" -c release
app_bin="$app_pkg/.build/release/ShiibarGhApp"

state=$(mktemp -d /tmp/sgperf.XXXXXX)
trap 'rm -rf "$state"' EXIT
python3 "$repo/scripts/perf/make-data.py" "$daemon" "$state"

# The display on while the app runs (caffeinate(8): -u turns a sleeping
# display on, -d keeps it on), so the window is on a display that is in use.
caffeinate -u -t 2 || true
SHIIBAR_GH_PERF=1 \
SHIIBAR_GH_STATE_DIR="$state" \
SHIIBAR_GH_PERF_DAEMON="$daemon" \
SHIIBAR_GH_PERF_LABEL="$label" \
SHIIBAR_GH_PERF_OUT="$work/$label.json" \
    caffeinate -d -i "$app_bin"
