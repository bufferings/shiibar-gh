#!/bin/sh
# Carries the working tree's measurement mode (app/Sources/ShiibarGhApp/
# Perf.swift) into scripts/perf/measure-0.4.patch, which adds the mode to
# 0.4.0 for `measure.sh --before`. The rest of the patch (the hooks in
# AppDelegate, Surfaces, Services and CardViews of 0.4.0, and 0.4.0's
# PerfSteps.swift) stays as it is.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d /tmp/shiibar-gh-patch.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/a" "$work/b"
git -C "$repo" archive v0.4.0 app | tar -x -C "$work/a"
git -C "$repo" archive v0.4.0 app | tar -x -C "$work/b"
(cd "$work/b" && patch -p1 -s < "$repo/scripts/perf/measure-0.4.patch")
cp "$repo/app/Sources/ShiibarGhApp/Perf.swift" "$work/b/app/Sources/ShiibarGhApp/Perf.swift"
# The file headers carry no modification times: `patch` does not need them.
(cd "$work" && diff -ruN a/app b/app || true) |
    sed -E 's/^((---|\+\+\+) [ab]\/[^[:space:]]+)[[:space:]].*$/\1/' \
        > "$repo/scripts/perf/measure-0.4.patch"
