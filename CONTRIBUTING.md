# Contributing to Asobi

Thanks for helping improve Asobi.

## Build

Requires Erlang/OTP 28 or later and rebar3.

```bash
rebar3 compile
```

## Tests

```bash
rebar3 eunit
rebar3 ct
```

The Common Test suites exercise the HTTP and WebSocket API against a real
Postgres; bring one up with Docker before running them.

## Pre-push checklist

Run these before opening a pull request and fix every warning, doc
warnings included:

```bash
rebar3 fmt --check
rebar3 xref
rebar3 dialyzer
rebar3 ex_doc
rebar3 eunit
rebar3 ct
```

## Pull requests

Without write access, work from a fork: fork the repository, push your branch
there, and open the pull request against `main`.

- Branch off `main`; do not push to `main` directly.
- Use conventional commit messages (`feat:`, `fix:`, `docs:`, `refactor:`, ...).
- Keep changes focused, and add or update tests alongside the code.
- Public modules use `-moduledoc`/`-doc` attributes so they render in the
  generated API reference.

## Review

Every pull request needs an approving review from a code owner
([CODEOWNERS](.github/CODEOWNERS)) before it can be merged, and pushing further
commits dismisses an approval already given. CI on a pull request from a
first-time contributor waits for a maintainer to start it.

## Security

Do not open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contributions are licensed under
Apache-2.0.
