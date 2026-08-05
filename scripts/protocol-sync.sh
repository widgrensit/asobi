#!/usr/bin/env bash
# Sync priv/protocol/fixtures into a client SDK, or report the drift.
#
# The corpus is ground truth for every SDK's dispatch tests, and all seven
# vendor a copy. Copies drift: at the time this was written core had 38
# fixtures and the SDKs had between 28 and 35, with no automation to notice.
# So this is the automation - `check` fails a build on drift, `apply` fixes it.
#
#   scripts/protocol-sync.sh check <sdk> <path-to-sdk-repo>
#   scripts/protocol-sync.sh apply <sdk> <path-to-sdk-repo>
#   scripts/protocol-sync.sh path  <sdk>        # where that SDK keeps them
#   scripts/protocol-sync.sh sdks               # every SDK it knows
#
# `check` exits 1 on drift and prints one line per file, so CI output says
# which fixture is missing rather than "tests failed".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$HERE/priv/protocol/fixtures"

# Each SDK's vendored copy. Paths differ because each ecosystem has its own
# test layout, and none of them is wrong - so the map lives here rather than
# every SDK growing a config file.
sdk_path() {
  case "$1" in
    js)      echo "test/fixtures" ;;
    dart)    echo "test/fixtures" ;;
    godot)   echo "test/fixtures" ;;
    love2d)  echo "test/fixtures" ;;
    defold)  echo "tests/fixtures" ;;
    unity)   echo "Tests/Runtime/Resources/Fixtures" ;;
    unreal)  echo "Source/AsobiSDK/Tests/Fixtures" ;;
    *)       return 1 ;;
  esac
}

SDKS="js dart godot love2d defold unity unreal"

# The Unity repo does not track a .meta per fixture - the editor generates
# them and they are not committed - so this syncs the JSON and nothing else.

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

cmd="${1:-}"; shift || usage

case "$cmd" in
  sdks) echo "$SDKS"; exit 0 ;;
  path) sdk_path "${1:?usage: path <sdk>}" || { echo "unknown sdk: $1" >&2; exit 2; }; exit 0 ;;
  check|apply) : ;;
  *) usage ;;
esac

sdk="${1:?usage: $cmd <sdk> <path-to-sdk-repo>}"
repo="${2:?usage: $cmd <sdk> <path-to-sdk-repo>}"
rel="$(sdk_path "$sdk")" || { echo "unknown sdk: $sdk" >&2; exit 2; }
dest="$repo/$rel"

[ -d "$CORPUS" ] || { echo "no corpus at $CORPUS" >&2; exit 2; }
[ -d "$repo" ] || { echo "no repo at $repo" >&2; exit 2; }

drift=0
report() { echo "  $1"; drift=$((drift + 1)); }

mkdir -p "$dest"

for src in "$CORPUS"/*.json; do
  name="$(basename "$src")"
  if [ ! -f "$dest/$name" ]; then
    report "missing: $name"
    [ "$cmd" = apply ] && cp "$src" "$dest/$name"
  elif ! cmp -s "$src" "$dest/$name"; then
    report "differs: $name"
    [ "$cmd" = apply ] && cp "$src" "$dest/$name"
  fi
done

for existing in "$dest"/*.json; do
  [ -e "$existing" ] || continue
  name="$(basename "$existing")"
  if [ ! -f "$CORPUS/$name" ]; then
    report "stale: $name (no such event in core)"
    if [ "$cmd" = apply ]; then
      rm -f "$existing"
    fi
  fi
done

if [ "$drift" -eq 0 ]; then
  echo "$sdk: in sync ($(ls "$CORPUS"/*.json | wc -l | tr -d ' ') fixtures)"
  exit 0
fi

if [ "$cmd" = apply ]; then
  echo "$sdk: $drift change(s) applied to $rel"
  exit 0
fi

echo "$sdk: $drift file(s) out of sync with asobi's corpus."
echo "Run: scripts/protocol-sync.sh apply $sdk $repo"
exit 1
