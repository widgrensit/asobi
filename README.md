<p align="center">
  <img src="docs/logo.png" alt="asobi" height="96">
</p>

<h1 align="center">asobi</h1>

<p align="center">
  <b>Multiplayer game backend on Erlang/OTP. Hot-reloadable, Apache-2.</b>
</p>

<p align="center">
  <a href="https://hex.pm/packages/asobi"><img alt="Hex.pm" src="https://img.shields.io/hexpm/v/asobi.svg"></a>
  <a href="https://hexdocs.pm/asobi"><img alt="Hexdocs" src="https://img.shields.io/badge/hex-docs-green"></a>
  <a href="https://github.com/widgrensit/asobi/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/widgrensit/asobi/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg"></a>
</p>

<p align="center">
  <a href="https://asobi.dev/docs">Docs</a> •
  <a href="https://asobi.dev/demo">Live demo</a> •
  <a href="https://discord.gg/vYSfYYyXpu">Discord</a> •
  <a href="https://github.com/widgrensit/asobi/issues">Issues</a>
</p>

---

## Two ways to use asobi

**Write your game in Lua** — use the [**asobi_lua**](https://github.com/widgrensit/asobi_lua)
Docker runtime. One container, hot-reloadable Lua match scripts, batteries
included. No Erlang required. **This is what most people want.**

**Write your game in Erlang** — depend on this library directly. You get the
same match supervisor, matchmaker, leaderboards, economy, world server, and
voting primitives, implemented as OTP behaviours you compose with the rest of
your release.

```erlang
%% rebar.config
{deps, [
    {asobi, "~> 0.1"}
]}.
```

## Features

- **`asobi_match`** — behaviour for per-match logic, backed by a supervised `gen_server` with ETS state backup on crash.
- **`asobi_matchmaker`** — pluggable strategies (`fill`, `skill_based`); your own via the `asobi_matchmaker_strategy` behaviour.
- **`asobi_world_server`** — persistent worlds with lazy zones, spatial grid indexing, terrain chunk serving, adaptive tick rates.
- **`asobi_vote_server`** — plurality, ranked choice, approval, weighted. Fixed / ready-up / hybrid / adaptive windows. Spectator voting, veto tokens, majority-tyranny mitigations.
- **`asobi_phase`, `asobi_season_manager`, `asobi_timer`** — phase engine, season lifecycles, five timer primitives.
- **Rate limiting** via `seki` (sliding window, per route group), **sessions** cached in ETS, **presence** via `pg`, **chat / social / economy / inventory / storage / tournaments / notifications** as Nova controllers.
- **Client SDKs** for Godot, Defold, Unity, Unreal, JS/TS, Dart, Flame — [see below](#client-sdks).

## Benchmarks

Single node, 8 cores, same-machine client. See [guides/benchmarks.md](guides/benchmarks.md) for full numbers.

| | Peak |
|---|---|
| WebSocket throughput | **83,000 msg/sec** @ 3,500 concurrent connections |
| RTT p50 / p99 | 4.4 ms / 6.5 ms |
| REST reads (matches / friends / wallets) | 7–14 ms p50 |
| Memory per connection | ~15 KB |

Not a twitch-FPS backend — WebSocket/TCP has a latency floor. Excellent for
turn-based, casual, MMO zone, roguelike, co-op, and party games. Pair with a
UDP relay if you need sub-3ms physics.

## Client SDKs

Godot, Defold, Unity, Unreal, JS/TS, Dart/Flutter, Flame — all under the
[widgrensit](https://github.com/widgrensit?tab=repositories&q=asobi-&type=public)
org, each with install instructions and a sample game. The
[asobi_lua README](https://github.com/widgrensit/asobi_lua#client-sdks) has
the table.

## Documentation

- [**Getting started**](guides/getting-started.md) — stand up a local asobi node from Erlang
- [**Architecture**](guides/architecture.md) — supervision tree, modules, design
- [**REST API**](guides/rest-api.md) · [**WebSocket protocol**](guides/websocket-protocol.md)
- [**Matchmaking**](guides/matchmaking.md) · [**Voting**](guides/voting.md) · [**World server**](guides/world-server.md) · [**Large worlds**](guides/large-worlds.md)
- [**Economy**](guides/economy.md) · [**Authentication**](guides/authentication.md) · [**IAP**](guides/iap.md)
- [**Lua scripting**](guides/lua-scripting.md) · [**Lua bots**](guides/lua-bots.md)
- [**Configuration**](guides/configuration.md) · [**Clustering**](guides/clustering.md) · [**Performance tuning**](guides/performance-tuning.md)
- [**Benchmarks**](guides/benchmarks.md) · [**Comparison vs Nakama / Colyseus / SpacetimeDB**](guides/comparison.md)
- [**HexDocs**](https://hexdocs.pm/asobi) — full API reference

## Migrating?

- [**from Hathora**](guides/migrate-from-hathora.md) — Hathora shuts down 2026-05-05.
- [**from PlayFab**](guides/migrate-from-playfab.md)
- [**from Nakama self-host**](guides/migrate-from-nakama.md)

## Related projects

- [**asobi_lua**](https://github.com/widgrensit/asobi_lua) — Lua scripting runtime + Docker image (`ghcr.io/widgrensit/asobi_lua`)
- [**asobi-cli**](https://github.com/widgrensit/asobi-cli) — deploy, manage, and scaffold games
- [**asobi_admin**](https://github.com/widgrensit/asobi_admin) — admin dashboard
- Client SDKs: [asobi-godot](https://github.com/widgrensit/asobi-godot) · [asobi-defold](https://github.com/widgrensit/asobi-defold) · [asobi-unity](https://github.com/widgrensit/asobi-unity) · [asobi-unreal](https://github.com/widgrensit/asobi-unreal) · [asobi-js](https://github.com/widgrensit/asobi-js) · [asobi-dart](https://github.com/widgrensit/asobi-dart) · [flame_asobi](https://github.com/widgrensit/flame_asobi)

## Stability

> [!NOTE]
> asobi is pre-1.0. The API is stabilising; expect minor breaking changes
> until 1.0. We will never relicense — see [guides/exit.md](guides/exit.md)
> for the "if asobi disappears tomorrow" runbook.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the build setup, pre-push
checklist, and test matrix. Security issues: see [SECURITY.md](SECURITY.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
