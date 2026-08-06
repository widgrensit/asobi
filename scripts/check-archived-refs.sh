#!/usr/bin/env bash
# Fails if user-facing docs send a reader to a repository that is archived.
#
#   scripts/check-archived-refs.sh
#
# asobi_admin was archived on 2026-08-06 after its console moved into asobi,
# and seven guides were still telling people to install it - including three
# migration guides, which are the first thing someone arriving from Nakama or
# PlayFab reads. An archived repo is read-only and stays public and indexed, so
# nothing 404s and nothing complains; the docs are simply wrong and quietly
# stay that way.
#
# Deliberately not a link checker. The links resolve fine. What is broken is
# the advice.
set -euo pipefail

# Repositories that are archived, and what to say instead. Add a row when you
# archive something, in the same PR.
ARCHIVED=(
  "asobi_admin|the operator console ships in asobi - see guides/console.md"
  "asobi_lua|the Lua runtime ships in asobi (src/lua/) - link this repo, and use the ghcr.io/widgrensit/asobi image"
)

# Docs a reader follows. Deliberately excludes docs/adr/: an ADR records a
# decision as it stood, and rewriting that history to keep a linter quiet is
# worse than the stale name.
#
# examples/ is in scope because a reader who runs an example is following it as
# closely as a guide, and its READMEs are where a stale "install X too" line
# survives longest.
PATHS=(guides README.md docs/ARCHITECTURE.md examples CONTRIBUTING.md)

fails=0
for entry in "${ARCHIVED[@]}"; do
  repo="${entry%%|*}"
  advice="${entry#*|}"

  # Links only. Naming a repository in prose - "this used to live in X" - is
  # exactly how you explain a move, and flagging it would push writers into
  # deleting the history rather than the bad advice.
  hits="$(grep -rniE "github\.com/[a-z-]+/${repo}\b" "${PATHS[@]}" 2>/dev/null || true)"

  if [ -n "$hits" ]; then
    printf '\n%s is archived, but is still referenced as somewhere to go:\n\n' "$repo"
    printf '%s\n' "$hits" | sed 's/^/  /'
    printf '\n  Say instead: %s\n' "$advice"
    fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  printf '\n%d archived repository reference(s) in user-facing docs.\n' "$fails" >&2
  exit 1
fi

echo "no user-facing docs point at an archived repository"
