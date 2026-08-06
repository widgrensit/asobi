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

# The code -> status table, read out of asobi_error's ?CODES macro. Since the
# shared error object landed (plan item 1b) a controller names a code and never
# a status, so the status a client sees is asobi_error's business, not the call
# site's - and this guard has to resolve it the same way.
#
# Newlines are flattened first, as in src_pairs below: erlfmt reflows a long
# entry across three lines, and a per-line regex missed those and fell through
# to the 500 default - which is how the guide came to document a 403 as a 500.
code_status() {
	tr '\n' ' ' <"$repo_root/src/asobi_error.erl" | tr -s ' ' |
		grep -oE '\{ ?~"[a-z_.]+", ?[0-9]{3},' |
		sed -E 's/\{ ?~"([a-z_.]+)", ?([0-9]{3}),/\1 \2/'
}

# Every "<status> <code>" pair a module returns. Newlines are flattened and runs
# of spaces squeezed first, so erlfmt reflowing a return across lines can never
# hide it from the regex. Both {asobi_error, Code} and {asobi_error, Code,
# Details} are matched; the status comes from the table above.
#
# `asobi_error:legacy(Code, Details)` is matched too. It returns a rendered
# `{json, ...}` rather than an {asobi_error, Code} tuple, so the tuple regex
# alone missed every code raised through it - which is how the guest table came
# to omit the 422 the upgrade path returns on a bad username or password.
src_pairs() {
	local codes
	codes=$(
		tr '\n' ' ' <"$1" | tr -s ' ' |
			grep -oE '\{asobi_error, ?~"[a-z_.]+"|asobi_error:legacy\( ?~"[a-z_.]+"' |
			sed -E 's/.*~"([a-z_.]+)"/\1/' | sort -u
	)
	[ -z "$codes" ] && return 0
	# Join code -> status. A code with no ?CODES entry is a server bug that
	# asobi_error answers 500 for, so report it as 500 rather than dropping it -
	# dropping it would let an undefined code hide from this guard entirely.
	local c st
	while IFS= read -r c; do
		[ -z "$c" ] && continue
		st=$(code_status | awk -v k="$c" '$1 == k {print $2; exit}')
		printf '%s %s\n' "${st:-500}" "$c"
	done <<<"$codes"
}

# Every "<status> <atom>" row of the markdown error table inside one guide
# section. Scoped to the section so an unrelated table added elsewhere in the
# same guide cannot bleed in and fail this spuriously.
doc_pairs() {
	# SC2016: the backticks are literal markdown, not command substitution -
	# single quotes are what keeps them literal.
	# shellcheck disable=SC2016
	awk -v heading="$2" '$0 == heading {f=1; next} /^## /{f=0} f' "$1" |
		grep -oE '^\| `[0-9]{3}` *\| `[a-z_.]+`' |
		sed -E 's/^\| `([0-9]{3})` *\| `([a-z_.]+)`/\1 \2/'
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
echo "OK: every documented error code matches source."
