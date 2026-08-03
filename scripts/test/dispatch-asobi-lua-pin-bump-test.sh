#!/usr/bin/env bash
# Tests for scripts/dispatch-asobi-lua-pin-bump.sh. Runs the script against a
# throwaway git repo with `gh` stubbed on PATH, so the release-detection and
# token-handling branches are exercised without touching GitHub.
set -uo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd)"
script="$script_dir/dispatch-asobi-lua-pin-bump.sh"
fail=0

setup() {
  work="$(mktemp -d)"
  stub_bin="$work/bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
exit "${GH_EXIT:-0}"
STUB
  chmod +x "$stub_bin/gh"
  export GH_CALLS="$work/gh-calls"
  : >"$GH_CALLS"

  git init --quiet "$work/repo"
  git -C "$work/repo" config user.email test@example.com
  git -C "$work/repo" config user.name test
  git -C "$work/repo" commit --quiet --allow-empty -m "chore: initial"
}

teardown() {
  rm -rf "$work"
  unset GH_CALLS GH_EXIT
}

run_script() {
  (cd "$work/repo" && PATH="$stub_bin:$PATH" "$script" 2>&1)
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $name"
  else
    echo "FAIL - $name: expected '$expected', got '$actual'"
    fail=1
  fi
}

# Untagged HEAD: the release job skipped, so nothing is dispatched.
setup
export GH_TOKEN=t
out="$(run_script)"; rc=$?
check "untagged HEAD exits 0" 0 "$rc"
check "untagged HEAD dispatches nothing" "" "$(cat "$GH_CALLS")"
case "$out" in *"nothing to dispatch"*) echo "ok - untagged HEAD says why";; *) echo "FAIL - untagged HEAD message: $out"; fail=1;; esac
teardown

# Tagged HEAD without a token: warn loudly, never fail the release.
setup
git -C "$work/repo" tag v1.2.3
unset GH_TOKEN
out="$(run_script)"; rc=$?
check "missing token exits 0" 0 "$rc"
check "missing token dispatches nothing" "" "$(cat "$GH_CALLS")"
case "$out" in *"::warning::"*) echo "ok - missing token warns";; *) echo "FAIL - missing token warning: $out"; fail=1;; esac
teardown

# Tagged HEAD with a token: dispatch carries the tag that was just released.
setup
git -C "$work/repo" tag v1.2.3
export GH_TOKEN=t
out="$(run_script)"; rc=$?
check "release exits 0" 0 "$rc"
check "release dispatches once" \
  "api repos/widgrensit/asobi_lua/dispatches -f event_type=asobi-released -f client_payload[tag]=v1.2.3" \
  "$(cat "$GH_CALLS")"
teardown

# Several tags on one commit: the highest version wins, not the first sorted.
setup
git -C "$work/repo" tag v1.9.0
git -C "$work/repo" tag v1.10.0
export GH_TOKEN=t
run_script >/dev/null
check "highest version dispatched" \
  "api repos/widgrensit/asobi_lua/dispatches -f event_type=asobi-released -f client_payload[tag]=v1.10.0" \
  "$(cat "$GH_CALLS")"
teardown

# A refused dispatch is a red job, not a silent no-op.
setup
git -C "$work/repo" tag v1.2.3
export GH_TOKEN=t GH_EXIT=1
out="$(run_script)"; rc=$?
check "failed dispatch exits 1" 1 "$rc"
case "$out" in *"::error::"*) echo "ok - failed dispatch errors";; *) echo "FAIL - failed dispatch message: $out"; fail=1;; esac
teardown

exit "$fail"
