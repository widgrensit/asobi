#!/usr/bin/env bash
# Fails if guides/observability.md and the telemetry events in src/ disagree.
#
#   scripts/check-telemetry-drift.sh
#
# Written because the same list already rotted once. docs/adr/0005 set out to
# be the event contract and now documents 10 of 37: the other 27 were added
# afterwards and nobody went back. A guide that tells an operator which events
# exist is worth having only if it is true, so this makes adding an event
# without documenting it a build failure rather than a discovery six months
# later.
#
# Matches the event LIST only, not measurement or metadata keys - those live in
# asobi_telemetry's moduledoc, close enough to the emission that they are hard
# to get wrong, and a shape checker for them would be more machinery than the
# problem deserves.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
guide="$repo_root/guides/observability.md"

[ -r "$guide" ] || {
  echo "guide not found at $guide" >&2
  exit 1
}

# Emitted: every [asobi, domain, event] literal in src/, as dotted names.
emitted="$(grep -rhoE '\[asobi, [a-z_]+, [a-z_]+\]' "$repo_root/src" --include=*.erl |
  sed 's/\[asobi, /asobi./; s/, /./; s/\]//' | sort -u)"

# Documented: the same dotted names inside the guide's code blocks.
documented="$(grep -ohE '\basobi\.[a-z_]+\.[a-z_]+\b' "$guide" | sort -u)"

missing="$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented"))"
extra="$(comm -13 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented"))"

status=0

if [ -n "$missing" ]; then
  printf '\nEmitted in src/ but not documented in guides/observability.md:\n\n' >&2
  printf '%s\n' "$missing" | sed 's/^/  /' >&2
  status=1
fi

if [ -n "$extra" ]; then
  printf '\nDocumented in guides/observability.md but not emitted anywhere:\n\n' >&2
  printf '%s\n' "$extra" | sed 's/^/  /' >&2
  printf '\n  Either the event was removed, or the name is a typo.\n' >&2
  status=1
fi

if [ "$status" -ne 0 ]; then
  count_e="$(printf '%s\n' "$emitted" | grep -c . || true)"
  count_d="$(printf '%s\n' "$documented" | grep -c . || true)"
  printf '\nDRIFT: %s event(s) emitted, %s documented.\n' "$count_e" "$count_d" >&2
  exit 1
fi

echo "OK: every telemetry event is documented ($(printf '%s\n' "$emitted" | grep -c .) events)."
