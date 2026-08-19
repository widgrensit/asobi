# Comparison

How asobi compares to other game backend platforms.

asobi is one Erlang/OTP node containing the game backend, the Lua runtime and
the operator console. There are two front doors into it: run the image
(`ghcr.io/widgrensit/asobi`) and write Lua, or depend on the Hex package and
write Erlang. Same node, same features, different surface.

The asobi column is checked against this repository. The other columns are
summarised from each vendor's own public documentation
([Nakama](https://heroiclabs.com/docs/nakama/),
[Colyseus](https://docs.colyseus.io/),
[PlayFab](https://learn.microsoft.com/en-us/gaming/playfab/)) and were last
read on 2026-08-06. Check them against the vendor before you make a decision
on one.

## Feature matrix

| Feature | asobi | Nakama | Colyseus | PlayFab |
|---------|:-----:|:------:|:--------:|:-------:|
| Runtime | BEAM (Erlang/OTP) | Go | Node.js | Cloud |
| Authentication | Built-in | Built-in | Plugin | Built-in |
| Anonymous / guest auth | Built-in, upgradeable, opt-in | Built-in | Manual | Built-in |
| Player management | Built-in | Built-in | Manual | Built-in |
| Real-time multiplayer | WebSocket | WebSocket | WebSocket | WebSocket |
| Server-authoritative game loop | Built-in, tick-based | Lua / Go / TS runtime | Room-based | CloudScript |
| Matchmaking | Modes plus pluggable strategies | Query-based | Manual | Built-in |
| Leaderboards | ETS reads, PostgreSQL persistence | Built-in | Manual | Built-in |
| Virtual economy | Wallets, store, inventory | IAP validation | Manual | Built-in |
| Friends / groups | Built-in | Built-in | Manual | Built-in |
| Chat | Built-in, channels plus DMs | Built-in | Manual | Manual |
| Tournaments | Built-in | Built-in | Manual | Manual |
| Cloud saves | Built-in | Storage API | Manual | Built-in |
| Notifications | Built-in | Built-in | Manual | Built-in |
| Background jobs | Shigoto, built-in | Manual | Manual | Scheduled tasks |
| Custom server-side logic | Lua callbacks plus extension RPC | Runtime modules and RPCs | Room handlers | CloudScript |
| Operator console | Built-in, read-only | Nakama Console, mutating | Monitor | Game Manager |
| Database | PostgreSQL, Kura ORM | PostgreSQL or CockroachDB | MongoDB / custom | Managed |
| Self-hosted | Yes | Yes | Yes | No |

Two rows are worth reading twice.

The console is a React SPA served from `priv/console` by the same node that
serves the game. Core's ops routes are reads apart from erasing and exporting
one player; the third mutating route is `/api/v1/ops/ext/:extension/:action`,
whose behaviour comes from an installed extension. So there is no ban, kick,
grant, refund or match-end button. Nakama Console and PlayFab Game Manager both
mutate; if you are moving from one of those, that is a real gap. See
[Operator console](console.md).

Custom server-side logic that is not per-match goes over the WebSocket as
`rpc.call` with `{protocol: 1, method, params}`, answered by `rpc.ok` or
`rpc.error` and correlated by `cid`. All seven client SDKs speak it. That is
the replacement for a Nakama RPC, a PlayFab CloudScript function and a Hathora
custom message. See [Extensions](extensions.md).

## Runtime characteristics

| Concern | asobi (BEAM) | Nakama (Go) | Colyseus (Node.js) |
|---------|-------------|-------------|-------------------|
| Garbage collection | Per-process, isolated per match | Stop-the-world | Stop-the-world |
| Fault tolerance | OTP supervision, crashed matches restart | Panic recovery, manual | Process crash, manual |
| Live game-logic reload | Lua re-evaluated in place on the next tick | Restart required | Restart required |
| Pub/sub | `pg`, cluster-native | Built-in plus optional Redis | Built-in, single node |
| In-memory state | ETS and process heaps | In-process maps | In-process objects |
| Clustering | Distributed Erlang, built in | etcd / Consul | Redis, presence only |
| Scheduling | Pre-emptive, fair across all processes | Cooperative goroutines | Single-threaded event loop |

Live reload is a Lua mechanism, not an OTP release upgrade: the runtime stats
the script file each tick, and a changed mtime re-executes the script body
against the running Luerl state, re-declaring globals and functions while
in-flight game state survives. It needs the game directory to be a live mount.
asobi ships no `appup` or `relup`, so upgrading the node itself is a restart.

Connection density on a single node is **3,000-7,000 concurrent WebSocket
connections** measured on 8 cores, at 4.4ms p50 round-trip with 3,500
connections. Each connection costs ~13-20KB, so at that concurrency the ceiling
is CPU spent on message processing, not memory. Figures and method are in
[Benchmarks](benchmarks.md).

## When to choose asobi

- You want a single deployable with auth, matchmaking, economy, social and
  real-time multiplayer.
- You need fault-tolerant game sessions that survive crashes without losing
  state.
- You want hot-reloadable Lua so bug fixes ship without kicking players.
- You are building for many simultaneous matches or worlds.
- You prefer self-hosted Apache-2.0 over a closed managed cloud, with a real
  exit runbook (see [Exit guarantee](exit.md)).
- You want a PostgreSQL-backed system with a proper ORM.

## When to choose something else

- You are building a twitch FPS, fighting game or racer, where what kills you is
  the retransmission tail on a lossy path rather than the median RTT. Run the
  simulation over your own UDP netcode and use asobi for everything around it,
  or take a physics-first product for the simulation layer. Worth checking the
  alternatives on this point specifically rather than assuming: a production UDP
  game-state transport is rarer in this category than the marketing suggests,
  and several of the obvious comparisons are WebSocket-over-TCP underneath.
- You need deep LiveOps tooling (A/B testing, segmentation, push campaigns)
  today.
- You need a fully managed cloud at hyperscaler breadth. asobi's managed
  version is [asobi.dev/cloud](https://asobi.dev/cloud), which is the same
  open-source core rather than a different product - invite-only today, and
  narrower than self-hosting in ways [Cloud](cloud.md) lists.
- You are building a single-player game that only needs analytics and IAP.
  Analytics plus a store validator is cheaper than any backend here.

## Clustering

Multiple nodes share Postgres and `pg`-scoped presence, chat and process
lookups. Four things stay node-local and change how you deploy: the matchmaker
queue, the rate-limit buckets, the console session store and the player-to-world
table - so the console needs a sticky route, players queuing against different
nodes never match each other, and a player who reconnects to a different node
loses their world with no error. That last one is the only item here a player
notices and an operator does not, which is why it belongs in the summary rather
than only in the full list. [Clustering](clustering.md) has the rest.

## Client SDKs

Seven first-class SDKs: [Godot](https://github.com/widgrensit/asobi-godot),
[Defold](https://github.com/widgrensit/asobi-defold),
[LÖVE](https://github.com/widgrensit/asobi-love2d),
[Unity](https://github.com/widgrensit/asobi-unity),
[Unreal](https://github.com/widgrensit/asobi-unreal),
[JavaScript/TypeScript](https://github.com/widgrensit/asobi-js) and
[Dart/Flutter](https://github.com/widgrensit/asobi-dart).
[flame_asobi](https://github.com/widgrensit/flame_asobi) is a Flame bridge on
top of the Dart SDK rather than an eighth protocol implementation. The table
with guides and demos is in the [README](../README.md#client-sdks).

## Migrating from another backend

- [From Hathora](migrate-from-hathora.md) - shutdown 2026-05-05
- [From PlayFab](migrate-from-playfab.md)
- [From Nakama self-host](migrate-from-nakama.md)
