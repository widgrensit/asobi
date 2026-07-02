# AGENTS.md

Working agreement for agents and contributors on **asobi** - a multiplayer
game backend platform for Erlang/OTP, built on Nova. A public, Apache-2.0
library published to Hex: depend on it directly and compose the match,
matchmaker, world, economy, leaderboard, and voting primitives into your own
release.

## What it is and what it is not

asobi ships the backend pieces indie 2D multiplayer devs would otherwise
rebuild: auth, players, matches, matchmaker, chat, social, leaderboards,
economy, inventory, tournaments, votes, phases, worlds, presence, storage,
notifications, and IAP verification. Transport is REST + WebSocket over Nova
(Cowboy); persistence is Kura over PostgreSQL (pgo).

- **Public and brand-neutral.** This repo is engine-agnostic and carries no
  commercial coupling. Never add anything that names a hosted product, a
  tenant-validation endpoint, billing, or commercial plans. Those concerns
  live in separate private repos and must never leak here.
- **Single-node by design.** One BEAM node handles tens of thousands of
  connections. Shard at the app level (game-per-node, region-per-node); do
  not try to cluster a single match across hosts.
- **No media relay.** No UDP/TURN/SIP/WebRTC/voice. Pair with a UDP relay
  externally if sub-3ms physics is needed.
- **Lua lives elsewhere.** asobi has no luerl or scripting deps. The `game.*`
  Lua runtime and Docker image are a separate downstream app; keep Lua
  integration out of this library.

Before any change that adds a module, behaviour, API surface, or dependency -
especially one motivated by a single game's need - run it past the
**`asobi-architecture-guardian`** agent. Its job is to keep asobi a
general-purpose backend and reject single-consumer warping.

## Commands

```bash
rebar3 compile
make db-up                 # Postgres via Docker Compose (docker-compose.yml)
rebar3 eunit
rebar3 ct                  # CT suites run against Docker Postgres
make test                  # db-reset + rebar3 ct --sname asobi_test
make db-reset              # drop + recreate asobi_dev between runs
rebar3 fmt                 # erlfmt (write); CI runs fmt --check
rebar3 xref
rebar3 dialyzer
rebar3 ex_doc              # fix every new warning before pushing
rebar3 kura compile        # generate migrations - never hand-write them
rebar3 shell               # dev node on port 8082, DB asobi_dev
```

Postgres is Docker Compose only, never a system install. CT integration
suites talk to that container.

## Pre-push checklist (mandatory)

`rebar3 fmt` -> `rebar3 xref` -> `rebar3 dialyzer` -> `rebar3 eunit` ->
`rebar3 ct` -> `rebar3 ex_doc` (fix every warning) -> `rebar3 fmt --check`, all
green. Run the full suite and fix any pre-existing failures before starting
new work.

CI (Taure/erlang-ci) additionally runs dependency audit; eqwalize/lint/mutate
are not wired in this repo (eqwalize panics on OTP 29) - add them here if that
changes.

## Conventions

- **OTP 29.0.2**, rebar `3.27.0` (pinned in `.tool-versions`). `rebar3` only,
  never raw `erl`.
- `~"..."` sigil for binaries, never `<<"...">>`.
- No `lists:foldl/foldr` - list comprehensions + `maps:from_list`, or explicit
  named recursion.
- JSON: OTP `json` module, never thoas/jiffy.
- Logging: `?LOG_*` macros with `#{...}` map reports, never
  `logger:info/error` format strings; structured logging via `nova_jsonlogger`.
- Migrations: `rebar3 kura compile` generates them under `src/migrations/`.
  Never write a migration by hand.
- `{vsn, git}` in `.app.src` - the version derives from git tags. Never
  hand-edit it, never publish to Hex (the maintainer does that manually).
- **British English** for all asobi content (docs, guides, comments, copy).
- No em dashes anywhere - plain ASCII hyphen only.
- Default to zero comments; code should be self-documenting.
- `applications` order in `.app.src` is OTP boot order, not alphabetical.

## Architecture

`asobi_app` boots `asobi_sup` (`one_for_one`), whose children are the core
services:

```
asobi_sup (one_for_one)
├── rate_limit (seki limiters: auth/iap/api/ws_connect)
├── asobi_auth_cache
├── asobi_cluster
├── asobi_player_session_sup
├── asobi_match_sup
├── asobi_world_sup
├── asobi_world_lobby_server
├── asobi_vote_sup
├── asobi_matchmaker
├── asobi_leaderboard_sup
├── asobi_chat_sup
├── asobi_tournament_sup
├── asobi_presence            (pg-backed)
└── asobi_season_manager
```

- **REST** is Nova controllers under `src/controllers/`
  (`asobi_*_controller`); **WebSocket** is `asobi_ws_handler`. Routing is
  `asobi_router`; cross-cutting behaviour is Nova plugins under `src/plugins/`
  (`asobi_auth_plugin`, `asobi_rate_limit_plugin`,
  `asobi_security_headers_plugin`).
- **Matches** are supervised `gen_server`s with ETS state backup for
  crash recovery. **Worlds** use lazy zones, spatial-grid indexing, and
  adaptive tick rates. **Matchmaker** strategies (`fill`, `skill_based`) are
  pluggable via the `asobi_matchmaker_strategy` behaviour.
- Persistence: Kura schemas (`asobi_player`, `asobi_wallet`,
  `asobi_leaderboard_entry`, ...) over PostgreSQL via `asobi_repo`. Rate
  limiting via `seki`; background jobs via `shigoto`; sessions cached in ETS;
  presence via `pg`.

Deps: `nova`, `kura` + `kura_postgres`, `nova_auth`, `nova_auth_oidc`,
`nova_resilience`, `seki`, `shigoto`. Full internal map:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Decisions live in ADRs

Before changing a behaviour or a contract, read [docs/adr/](docs/adr/). Write
a new ADR (Nygard format) for any new behaviour, primitive, or contract
change.

## Tests

EUnit (`*_tests.erl`), Common Test suites (`*_SUITE.erl`), and PropEr
properties (`prop_*.erl`) live under `test/`. CT suites exercise the real
Nova + Kura + Postgres stack, so `make db-up` first. Test-only deps (`meck`,
`proper`, `nova_test`) are in the `test` profile. Always add or update tests
alongside code changes.

## Git and PRs

Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`,
`refactor:`). Always branch and open a PR - never push to `main`. Pull `main`
and read current state before branching. No `Co-Authored-By` trailer and no
"Generated with Claude" branding on any commit or PR. Every merge to `main`
tags a release, so keep each PR coherent. CI is `Taure/erlang-ci` (audit, CT,
dependency submission, summary) pinned to an exact SHA.
</content>
</invoke>
