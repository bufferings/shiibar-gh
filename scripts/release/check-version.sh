#!/usr/bin/env bash
# Fails unless a release tag vX.Y.Z matches the [workspace.package] version
# of the root Cargo.toml, the one source of the version (docs/tasks/M3.md,
# "Version numbers").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"

TAG="${1:?usage: check-version.sh <tag> (e.g. v0.1.0)}"
if ! printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: '$TAG' is not vX.Y.Z" >&2
  exit 1
fi
TAG_VERSION="${TAG#v}"
CARGO_VERSION="$(read_workspace_version "$ROOT/Cargo.toml")"
if [ "$TAG_VERSION" != "$CARGO_VERSION" ]; then
  echo "error: the tag does not match Cargo.toml [workspace.package] version:" >&2
  echo "  tag:        $TAG" >&2
  echo "  Cargo.toml: $CARGO_VERSION" >&2
  exit 1
fi
echo "version match: $CARGO_VERSION"
