#!/usr/bin/env bash
# Guards the guides' error tables against the controllers they describe.
#
# An error table is a contract a client acts on: the guest table here listed 11
# of the 15 atoms asobi_guest_controller returns, and one of the four missing
# was the retryable 409 device_already_registered - a client reading the guide
# would treat it as fatal and fail a launch a retry resolves (#176). Both
# directions are checked: every atom the source returns is documented, and every
# atom documented is reachable.
#
# The sibling asobi_site runs the same check against its own hand-written docs
# (asobi_site#90). Two surfaces describe these endpoints, so both need guarding.
#
# Usage: scripts/check-error-drift.sh
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

# Every "<status> <atom>" pair a module returns. Newlines are flattened and runs
# of spaces squeezed first, so erlfmt reflowing a return across lines can never
# hide it from the regex.
src_pairs() {
	tr '\n' ' ' <"$1" | tr -s ' ' |
		grep -oE '\{json, ?[0-9]+, ?#\{\}, ?#\{ ?error => ~"[a-z_]+"' |
		sed -E 's/.*\{json, ?([0-9]+).*error => ~"([a-z_]+)"/\1 \2/'
}

# Every "<status> <atom>" row of the markdown error table inside one guide
# section. Scoped to the section so an unrelated table added elsewhere in the
# same guide cannot bleed in and fail this spuriously.
doc_pairs() {
	# SC2016: the backticks are literal markdown, not command substitution -
	# single quotes are what keeps them literal.
	# shellcheck disable=SC2016
	awk -v heading="$2" '$0 == heading {f=1; next} /^## /{f=0} f' "$1" |
		grep -oE '^\| `[0-9]{3}` *\| `[a-z_]+`' |
		sed -E 's/^\| `([0-9]{3})` *\| `([a-z_]+)`/\1 \2/'
}

indent() {
	local line
	while IFS= read -r line; do printf '        %s\n' "$line"; done
}

# check_table <label> <guide> <section-heading> <module...>
#
# Every listed module is authoritative: the table must document exactly the
# union of what they return, no more and no less. asobi_auth_error is shared
# with register/login, but every atom it can return on this path is one the
# endpoint genuinely can return, so it earns the same exactness as the
# controller. A new atom there failing this check is the point - a human should
# look, not let the table drift silently.
check_table() {
	local label="$1" guide="$2" heading="$3"
	shift 3
	local f
	for f in "$guide" "$@"; do
		if [ ! -f "$f" ]; then
			echo "  !!  $label - $f not found"
			fail=1
			return
		fi
	done

	local documented returned missing extra m
	documented=$(doc_pairs "$guide" "$heading" | sort -u)
	returned=$(
		for m in "$@"; do src_pairs "$m"; done | sort -u
	)

	if [ -z "$documented" ]; then
		echo "  !!  $label - no error table found under '$heading' in $(basename "$guide")"
		fail=1
		return
	fi

	missing=$(comm -23 <(echo "$returned") <(echo "$documented"))
	extra=$(comm -13 <(echo "$returned") <(echo "$documented"))

	if [ -n "$missing" ]; then
		echo "  !!  $label - returned by source, undocumented:"
		echo "$missing" | indent
		fail=1
	fi
	if [ -n "$extra" ]; then
		echo "  !!  $label - documented, but no source returns it:"
		echo "$extra" | indent
		fail=1
	fi
	if [ -z "$missing$extra" ]; then
		echo "  OK  $label - $(echo "$documented" | wc -l) rows match source"
	fi
}

echo "== Guest auth =="
check_table "guest error table" \
	"$repo_root/guides/authentication.md" \
	'## Guest (Anonymous)' \
	"$repo_root/src/controllers/asobi_guest_controller.erl" \
	"$repo_root/src/asobi_auth_error.erl"

# Add a check_table line above as other exhaustive error tables are written. A
# table that is deliberately partial ("common errors") must not be listed here -
# this guard reads every table it is given as a complete contract.

echo
if [ "$fail" -ne 0 ]; then
	echo "DRIFT: a guide's error table no longer matches the controller it describes."
	exit 1
fi
echo "OK: every documented error atom matches source."
