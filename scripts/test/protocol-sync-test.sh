#!/usr/bin/env bash
# Exercises protocol-sync.sh against a throwaway SDK tree.
#
#   scripts/test/protocol-sync-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/../protocol-sync.sh"
CORPUS="$HERE/../../priv/protocol/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "ok   - $name"; else
    echo "FAIL - $name: got [$got] want [$want]"; fails=$((fails + 1))
  fi
}
has() {
  local name="$1" out="$2" needle="$3"
  if grep -qF -- "$needle" <<<"$out"; then echo "ok   - $name"; else
    echo "FAIL - $name: expected to find: $needle"; fails=$((fails + 1))
  fi
}

repo="$TMP/sdk"
dest="$repo/test/fixtures"
mkdir -p "$dest"

# 1. An empty SDK is every fixture out of sync, and says so per file.
set +e
out="$("$SYNC" check js "$repo")"; rc=$?
set -e
check "an empty vendored copy fails the check" "$rc" "1"
has "and names a missing fixture" "$out" "missing: session.connected.json"

# 2. apply brings it into sync, and check then passes.
"$SYNC" apply js "$repo" >/dev/null
out="$("$SYNC" check js "$repo")"
has "apply then check is in sync" "$out" "in sync"
check "every fixture copied" \
  "$(ls "$dest"/*.json | wc -l | tr -d ' ')" "$(ls "$CORPUS"/*.json | wc -l | tr -d ' ')"

# 3. A fixture whose content moved is drift, not just a missing file.
printf '{"type":"tampered"}' > "$dest/session.connected.json"
set +e
out="$("$SYNC" check js "$repo")"; rc=$?
set -e
check "an edited fixture fails" "$rc" "1"
has "and is reported as differing" "$out" "differs: session.connected.json"
"$SYNC" apply js "$repo" >/dev/null
check "apply restores it" "$(cat "$dest/session.connected.json")" "$(cat "$CORPUS/session.connected.json")"

# 4. A fixture for an event core no longer emits is stale, and apply removes
#    it - otherwise an SDK keeps dispatch-testing a message that cannot arrive.
printf '{"type":"gone.away"}' > "$dest/gone.away.json"
set +e
out="$("$SYNC" check js "$repo")"; rc=$?
set -e
check "a stale fixture fails" "$rc" "1"
has "and is named" "$out" "stale: gone.away.json"
"$SYNC" apply js "$repo" >/dev/null
[ ! -f "$dest/gone.away.json" ] && echo "ok   - apply removes it" || {
  echo "FAIL - apply left the stale fixture"; fails=$((fails + 1)); }

# 5. Each SDK's path is its own; unknown ones are refused rather than guessed.
check "unity path" "$("$SYNC" path unity)" "Tests/Runtime/Resources/Fixtures"
check "defold path" "$("$SYNC" path defold)" "tests/fixtures"
set +e
"$SYNC" path bevy >/dev/null 2>&1; rc=$?
set -e
check "an unknown sdk is refused" "$rc" "2"
check "seven sdks" "$("$SYNC" sdks | wc -w | tr -d ' ')" "7"

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
