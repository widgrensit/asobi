#!/usr/bin/env bash
# Tells widgrensit/asobi_lua a release just happened here, so its pin-bump
# workflow runs immediately instead of waiting up to a day for its next
# nightly schedule (asobi #276, asobi_lua #103).
#
# The release job only tags when git-cliff decides a bump is due, and the
# reusable erlang-ci workflow exports no output saying whether it did. A tag
# pointing at HEAD is the signal: present means this run released, absent
# means it skipped and there is nothing for asobi_lua to pick up.
#
# Usage: scripts/dispatch-asobi-lua-pin-bump.sh
# Env:   GH_TOKEN - PAT or app token with write access to widgrensit/asobi_lua.
#        The default GITHUB_TOKEN cannot dispatch across repositories.
set -uo pipefail

tag="$(git tag --points-at HEAD --list 'v*' | sort -V | tail -1)"

if [ -z "$tag" ]; then
  echo "No release tag on HEAD; nothing to dispatch."
  exit 0
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::warning::No dispatch token configured; asobi_lua will not see $tag until its nightly pin bump."
  exit 0
fi

if ! gh api repos/widgrensit/asobi_lua/dispatches \
  -f event_type=asobi-released \
  -f "client_payload[tag]=$tag"; then
  echo "::error::Failed to dispatch asobi-released ($tag) to widgrensit/asobi_lua."
  exit 1
fi

echo "Dispatched asobi-released ($tag) to widgrensit/asobi_lua."
