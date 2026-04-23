# Project glossary

You'll see several "asobi" names in docs, repos, and the Discord. Here's what
each one is and when to reach for it. Read this page first if you're new —
the names look interchangeable and aren't.

## The open-source pieces

**asobi** — the public Erlang library published on
[Hex](https://hex.pm/packages/asobi). Depend on it in `rebar.config` if
you're writing your game backend directly in Erlang/OTP and want match,
matchmaking, world-server, voting, economy, and the rest as composable
OTP behaviours. This is the library underneath everything.

**asobi_lua** — the batteries-included runtime that wraps the `asobi`
library with a [Luerl](https://github.com/rvirding/luerl) VM so you can
write game logic in Lua without knowing Erlang. Ships as a Docker image at
`ghcr.io/widgrensit/asobi_lua`. Most people start here.

**asobi_arena_lua** — the flagship end-to-end Lua example. Read it to see
a full game, not a snippet.

## Client SDKs

**asobi-godot, asobi-defold, asobi-unity, asobi-unreal, asobi-js,
asobi-dart, flame_asobi** — one per engine, all talking to asobi over
WebSocket + REST. See the [SDK table in the
README](../README.md#client-sdks).

## The commercial layer

**asobi.dev Cloud** — managed hosting, opening later in 2026. Same binary
you can self-host today, with opinionated ops and flat per-container
pricing. Join the waitlist at [asobi.dev/cloud](https://asobi.dev/cloud).

If we disappear, the open-source pieces above are enough to run your game
forever. See [exit.md](exit.md) for the runbook.

## Which one do I start with?

- **"I want to write Lua."** → `asobi_lua`. Pull the Docker image, write
  `match.lua`, `docker compose up`.
- **"I want to write Erlang."** → `asobi`. Add it to `rebar.config`,
  implement the `asobi_match` behaviour.
- **"I want both."** → `asobi_lua` hosts your Lua code and is itself built
  on the `asobi` library. You can drop from Lua into an Erlang behaviour
  for a hot loop without leaving the process.
- **"I just want hosting."** → self-host `asobi_lua` today, or join the
  `asobi.dev/cloud` waitlist.

## Concepts, not projects

These are vocabulary, not repositories. You'll see them throughout the
docs:

- **Match** — a short-lived gameplay session. 2 to N players, finite
  duration, result persisted. Runs as a `gen_server` under a supervisor.
- **World** — a long-lived persistent environment. Players come and go,
  state persists across disconnects. Think MMO zone, town, dungeon.
- **Zone** — a spatial partition inside a world. Used for sharding large
  worlds into loadable chunks.
- **Session** — a player's authenticated connection. Survives
  reconnection with a session token.
- **Tenant** — a studio or account in the managed cloud. You don't see
  this when self-hosting.
- **Game** — the product you're shipping. One game may have many match
  modes, worlds, and tenants.

When two words compete (e.g. *match* vs *room*, *world* vs *realm*),
asobi uses the first one. The [Nakama migration
guide](migrate-from-nakama.md) and [Hathora migration
guide](migrate-from-hathora.md) include mapping tables from competitor
vocab to asobi vocab.
