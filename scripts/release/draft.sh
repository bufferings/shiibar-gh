#!/usr/bin/env bash
# Edit and publish the draft GitHub Release that release.yml creates, without
# ever letting it lose its tag. Two subcommands:
#
#   draft.sh notes <tag> <notes-file>   replace the draft's body
#   draft.sh publish <tag>              publish the draft
#
# Why this exists: a PATCH of a draft release that does not carry tag_name
# can leave the draft with the tag_name `untagged-<hash>`; published like
# that, the release's download URL returns 404 and bump-cask.yml refuses to
# update the tap. shiibar-cc's releases met this twice and its
# scripts/release/draft.sh is the origin of this script. So every PATCH here
# sends tag_name along with the change, and every step re-reads the release
# and stops unless tag_name is still <tag>.
#
# The draft is looked up by release ID (exactly one draft must exist): the
# tag-name-based `gh release edit <tag>` is not relied on for drafts, and a
# draft that already lost its tag cannot be found by tag at all.
set -euo pipefail

REPO="bufferings/shiibar-gh"

usage() {
  echo "usage: draft.sh notes <tag> <notes-file> | draft.sh publish <tag>" >&2
  exit 2
}

# The ID of the single draft release. Zero or several drafts is an error
# rather than a guess.
find_draft_id() {
  local ids count
  if ! ids="$(gh api --paginate "repos/$REPO/releases" --jq '.[] | select(.draft) | .id')"; then
    echo "error: could not list the releases of $REPO" >&2
    exit 1
  fi
  count="$(printf '%s' "$ids" | grep -c . || true)"
  if [ "$count" -ne 1 ]; then
    echo "error: expected exactly one draft release in $REPO, found $count" >&2
    exit 1
  fi
  printf '%s\n' "$ids"
}

# Re-read the release and stop unless its tag_name is the expected tag.
# The third argument says whether the release is already public: fixing a
# published release's tag_name alone sends no new `release: published`
# event, so the tap would never be bumped; it has to go back to draft and
# be published again.
assert_tag() {
  local id="$1" tag="$2" published="$3" actual
  actual="$(gh api "repos/$REPO/releases/$id" --jq '.tag_name')"
  if [ "$actual" != "$tag" ]; then
    echo "error: release $id has tag_name '$actual', expected '$tag'" >&2
    if [ "$published" = published ]; then
      echo "  the release is already public; recover with:" >&2
      echo "    gh api -X PATCH repos/$REPO/releases/$id -f tag_name=$tag -F draft=true" >&2
      echo "    scripts/release/draft.sh publish $tag" >&2
    else
      echo "  fix it with: gh api -X PATCH repos/$REPO/releases/$id -f tag_name=$tag" >&2
    fi
    exit 1
  fi
}

[ $# -ge 2 ] || usage
cmd="$1"
TAG="$2"
if ! printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: tag must be vX.Y.Z, got '$TAG'" >&2
  exit 2
fi
VERSION="${TAG#v}"

case "$cmd" in
  notes)
    [ $# -eq 3 ] || usage
    notes_file="$3"
    [ -f "$notes_file" ] || { echo "error: no such file: $notes_file" >&2; exit 1; }
    id="$(find_draft_id)"
    assert_tag "$id" "$TAG" draft
    gh api -X PATCH "repos/$REPO/releases/$id" \
      -f tag_name="$TAG" -F body=@"$notes_file" >/dev/null
    assert_tag "$id" "$TAG" draft
    echo "updated the notes of draft release $id ($TAG)"
    ;;
  publish)
    [ $# -eq 2 ] || usage
    id="$(find_draft_id)"
    assert_tag "$id" "$TAG" draft
    gh api -X PATCH "repos/$REPO/releases/$id" \
      -f tag_name="$TAG" -F draft=false >/dev/null
    # From here on the release is public; a wrong tag_name now needs the
    # recovery in docs/DEVELOPMENT.md (the release procedure, step 4).
    assert_tag "$id" "$TAG" published

    # Check the asset is downloadable under the tag. The query string keeps
    # this request from being answered with a stale response: the plain URL
    # can keep returning 404 for about a minute after a recovery while the
    # same URL with a query string returns 302. A few retries cover a
    # short delay right after publishing; a network failure yields 000 and
    # falls into the error branch instead of exiting silently under set -e.
    url="https://github.com/$REPO/releases/download/$TAG/shiibar-gh-$VERSION-arm64.zip"
    status=000
    for attempt in 1 2 3; do
      status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -I \
        "$url?verify=$(date +%s)" || true)"
      case "$status" in
        200 | 302) break ;;
      esac
      if [ "$attempt" -lt 3 ]; then
        sleep 5
      fi
    done
    case "$status" in
      200 | 302) echo "published $TAG (release $id); $url -> $status" ;;
      *)
        echo "error: published (release $id), but $url returned $status" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    usage
    ;;
esac
