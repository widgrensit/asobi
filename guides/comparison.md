# Comparison

How Asobi compares to other open-source game backend platforms.

## Feature Matrix

| Feature | Asobi | Nakama | Colyseus | PlayFab |
|---------|:-----:|:------:|:--------:|:-------:|
| **Runtime** | BEAM (Erlang/OTP) | Go | Node.js | Cloud |
| **Authentication** | Built-in | Built-in | Plugin | Built-in |
| **Player Management** | Built-in | Built-in | Manual | Built-in |
| **Real-Time Multiplayer** | WebSocket | WebSocket | WebSocket | WebSocket |
| **Server-Authoritative Game Loop** | Built-in (tick-based) | Lua scripting | Room-based | CloudScript |
| **Matchmaking** | Query-based | Query-based | Manual | Built-in |
| **Leaderboards** | ETS + PostgreSQL | Built-in | Manual | Built-in |
| **Virtual Economy** | Wallets, store, inventory | IAP validation | Manual | Built-in |
| **Friends / Groups** | Built-in | Built-in | Manual | Built-in |
| **Chat** | Built-in (channels) | Built-in | Manual | Manual |
| **Tournaments** | Built-in | Built-in | Manual | Manual |
| **Cloud Saves** | Built-in | Storage API | Manual | Built-in |
| **Notifications** | Built-in | Built-in | Manual | Built-in |
| **Background Jobs** | Shigoto (built-in) | Manual | Manual | Scheduled tasks |
| **Admin Dashboard** | Arizona LiveView | Built-in | Monitor | Portal |
| **Database** | PostgreSQL (Kura ORM) | CockroachDB | MongoDB / custom | Managed |
| **Self-Hosted** | Yes | Yes | Yes | No |

## Runtime Characteristics

| Concern | Asobi (BEAM) | Nakama (Go) | Colyseus (Node.js) |
|---------|-------------|-------------|-------------------|
| **Garbage Collection** | Per-process -- isolated per match | Stop-the-world -- affects all matches | Stop-the-world -- affects all rooms |
| **Fault Tolerance** | OTP supervision -- crashed matches restart | Panic recovery -- manual | Process crash -- manual |
| **Hot Code Upgrade** | Native -- zero-downtime deploys | Restart required | Restart required |
| **Pub/Sub** | `pg` module -- cluster-native | Built-in + optional Redis | Built-in (single node) |
| **In-Memory State** | ETS -- zero serialization | In-process maps | In-process objects |
| **Clustering** | Distributed Erlang -- built in | etcd / Consul | Redis (presence only) |
| **Scheduling** | Preemptive -- fair across all processes | Cooperative goroutines | Single-threaded event loop |
| **Connection Density** | ~500K+ per node | ~100K per node | ~10K per node |

## When to Choose Asobi

- You want a **single deployable** with auth, matchmaking, economy, social, and real-time multiplayer
- You need **fault-tolerant game sessions** that survive crashes without losing state
- You want **hot-reloadable Lua** so bug-fixes ship without kicking players
- You want **zero-downtime deploys** for game logic updates
- You're building for **high concurrency** (many simultaneous matches/rooms)
- You prefer **self-hosted Apache-2** over closed managed clouds, with a real exit guarantee (see [exit.md](exit.md))
- You want a **PostgreSQL-backed** system with a proper ORM

## Don't know Erlang?

You don't need to. Use [**asobi_lua**](https://github.com/widgrensit/asobi_lua) — the
same engine packaged as a Docker image with Lua scripting. Write your match
logic in a `.lua` file, `docker compose up`, you're running. The Erlang is
underneath but you never touch it.

The Erlang-library path (depending on `asobi` directly via rebar.config) is
for teams that already write OTP and want to compose asobi with the rest of
their release.

## When to Choose Something Else

- You need **sub-3ms UDP latency** for a twitch FPS / fighting game / racer. Pair asobi with a UDP relay, or use Photon Fusion / Quantum for the physics.
- You need **deep LiveOps tooling** (A/B testing, segmentation, push campaigns) today. PlayFab still leads here, though it's an operational/trust trade-off post-v2 migration.
- You need a **fully managed cloud** and are willing to pay cloud-scale prices. Our managed tier opens later in 2026; until then, self-host.
- You're building a **single-player** game that only needs analytics and IAP. Firebase Analytics + a simple store validator is cheaper than any backend here.

## Client SDKs

First-class SDKs for **Godot, Defold, Unity, Unreal, JavaScript/TypeScript, Dart/Flutter, Flame**
— see the [asobi_lua README](https://github.com/widgrensit/asobi_lua#client-sdks) for the table.

## Migrating from another backend?

- [**from Hathora**](migrate-from-hathora.md) — shutdown 2026-05-05
- [**from PlayFab**](migrate-from-playfab.md)
- [**from Nakama self-host**](migrate-from-nakama.md)
