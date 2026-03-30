# Architecture

## Overview

Asobi is an Erlang/OTP game backend built on Nova. This document covers the
runtime architecture, session lifecycle, how services communicate, and the
trade-offs for single-node, distributed Erlang, and cloud-native deployments.

## Supervision Tree

```
asobi_sup (one_for_one)
├── asobi_rate_limit_server     — per-node ETS rate limiter
├── asobi_cluster               — node discovery (DNS/EPMD)
├── asobi_player_session_sup    — dynamic simple_one_for_one
│   └── asobi_player_session    — one per connected player
├── asobi_match_sup             — dynamic simple_one_for_one
│   └── asobi_match_server      — one per active match (gen_statem)
├── asobi_matchmaker            — matching algorithm, tick-based
├── asobi_leaderboard_sup       — one child per leaderboard
│   └── asobi_leaderboard_server — in-memory buffer, periodic DB flush
├── asobi_chat_sup              — chat channel processes
├── asobi_tournament_sup        — tournament processes
└── asobi_presence              — tracks online players via pg
```

## Session Lifecycle

```
Client                    WS Handler              Session              Presence (pg)
  │                          │                       │                      │
  │── WS connect ───────────►│                       │                      │
  │── session.connect ──────►│                       │                      │
  │                          │── authenticate(token) │                      │
  │                          │   (DB lookup)         │                      │
  │                          │── start_session ─────►│                      │
  │                          │                       │── track(id, self) ──►│
  │                          │                       │   pg:join(player,id) │
  │◄── session.connected ───│                       │                      │
  │                          │                       │                      │
  │   ... gameplay ...       │                       │                      │
  │                          │                       │                      │
  │── disconnect ───────────►│                       │                      │
  │                          │── stop(session) ─────►│                      │
  │                          │                       │── untrack(id) ──────►│
  │                          │                       │   pg:leave           │
```

**Key points:**
- Token is validated **once** at `session.connect` via DB lookup
- After authentication, `player_id` lives in process state — no further DB checks
- The session process monitors the WS process; if WS dies, session cleans up
- WS terminate calls `session:stop/1` for the reverse direction

## Session Revocation

When a player is banned, deleted, or their token is revoked:

```erlang
asobi_presence:revoke_session(PlayerId, ~"banned").
```

**Flow:**
1. `revoke_session/2` enqueues a job on the `broadcast` fanout queue via Shigoto
2. All nodes poll the fanout queue and pick up the job
3. Each node calls `asobi_presence:disconnect/2` locally
4. `disconnect/2` looks up session processes in the local `pg` group
5. Sends `{session_revoked, Reason}` to each session process
6. Session forwards to WS process, then stops
7. WS handler logs and returns `{stop, State}`

This uses Shigoto's fanout queue mode — every node processes every broadcast
job. Jobs are ephemeral (120s window, auto-pruned). Workers are idempotent.
The source of truth is always the database.

**Two-layer API:**
- `asobi_presence:revoke_session/2` — public API, enqueues broadcast job (cross-node)
- `asobi_presence:disconnect/2` — local delivery mechanism, called by the broadcast worker

## Match Lifecycle

```
Matchmaker              Match Sup            Match Server          Players (via pg)
  │                        │                      │                     │
  │── start_match(Config)─►│                      │                     │
  │                        │── start_link ────────►│ (waiting state)     │
  │                        │                      │                     │
  │── join(Pid, Player1) ─────────────────────────►│                     │
  │── join(Pid, Player2) ─────────────────────────►│ (min_players met)   │
  │                        │                      │── enter running ───►│
  │                        │                      │                     │
  │                        │                      │◄── {input, ...} ────│
  │                        │                      │── tick ──────────── │
  │                        │                      │── broadcast_state ─►│
  │                        │                      │   (10 Hz loop)      │
  │                        │                      │                     │
  │                        │                      │── enter finished    │
  │                        │                      │── persist_result ──►DB
  │                        │                      │── notify_players ──►│
  │                        │                      │── cleanup (5s) ────►stop
```

**Match states:** `waiting → running → finished` (also `paused`)

**Server-authoritative:** The match process owns all game state. Clients send
inputs, the server applies them each tick, and broadcasts the resulting state.
The game module (`asobi_match` behaviour) provides `init/1`, `join/2`,
`handle_input/3`, `tick/1`, and `get_state/2`.

## Database & Migrations

Each node runs its own PGO connection pool. Migrations run automatically at
application startup via `kura_migrator:migrate(asobi_repo)`.

**Migration rules:**
- The initial schema uses `create_table` operations
- Kura topologically sorts tables by FK dependencies — order in the migration
  file doesn't matter
- All operations run in a single PostgreSQL transaction with an advisory lock
- **Never delete or modify an applied migration** — add new `alter_table`
  migrations instead
- If migration fails, the app logs the error and continues starting (by design,
  to allow the app to serve health checks even with a stale schema)

**Multi-node consideration:** The advisory lock ensures only one node runs
migrations at a time. Other nodes wait. This is safe for rolling deploys.

## Deployment Models

### Single Node (Current)

Everything runs on one BEAM node. All process communication is local.
This is the simplest model and works for small-to-medium scale.

```
┌─────────────────────────────────┐
│           BEAM Node             │
│  ┌──────────┐  ┌─────────────┐ │
│  │ WS/HTTP  │  │ Matchmaker  │ │
│  │ Handlers │  │ (local)     │ │
│  └──────────┘  └─────────────┘ │
│  ┌──────────┐  ┌─────────────┐ │
│  │ Sessions │  │ Matches     │ │
│  │ (local)  │  │ (local)     │ │
│  └──────────┘  └─────────────┘ │
│  ┌──────────────────────────┐  │
│  │ pg (presence, chat)      │  │
│  └──────────────────────────┘  │
└──────────────┬──────────────────┘
               │
         ┌─────▼─────┐
         │ PostgreSQL │
         └───────────┘
```

**Migrations:** Always run at startup. One node, no contention.

**Scale limit:** A single BEAM node can handle tens of thousands of concurrent
WebSocket connections and hundreds of active matches. The bottleneck is usually
the game tick loop CPU cost, not connection count.

### Distributed Erlang (Multi-Node)

Multiple BEAM nodes connected via distributed Erlang. The `pg` module
automatically replicates group membership across all connected nodes.

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│    Node A     │    │    Node B     │    │    Node C     │
│  WS/HTTP     │    │  WS/HTTP     │    │  WS/HTTP     │
│  Sessions    │◄──►│  Sessions    │◄──►│  Sessions    │
│  Matches     │    │  Matches     │    │  Matches     │
│  Matchmaker  │    │  Matchmaker  │    │  Matchmaker  │
│  pg (shared) │    │  pg (shared) │    │  pg (shared) │
└──────┬───────┘    └──────┬───────┘    └──────┬───────┘
       │                   │                   │
       └───────────────────┼───────────────────┘
                     ┌─────▼─────┐
                     │ PostgreSQL │
                     └───────────┘
```

**What works across nodes today:**
- **Presence** — `pg:get_members(nova_scope, {player, Id})` returns pids on all
  nodes. Sending messages to those pids works transparently.
- **Session revocation** — `asobi_presence:disconnect/2` reaches sessions on any
  node.
- **Chat** — `nova_pubsub` uses `pg` underneath, so chat messages cross nodes.
- **Match state broadcasts** — `broadcast_state` uses `asobi_presence:send/2`
  which goes through `pg`, so a match process on Node A can send state to a
  player session on Node B.

**What does NOT work today:**
- **Matchmaker** — Each node runs its own `asobi_matchmaker` (local registration).
  A player on Node A and a player on Node B won't be matched together.
- **Match lookup by ID** — `global:whereis_name({asobi_match_server, MatchId})`
  fails because matches don't register globally.
- **Rate limiting** — Per-node ETS, not shared.

**Migrations:** The Kura advisory lock ensures only one node migrates at a
time. Safe for rolling deploys, but you should NOT run migrations on every node
simultaneously — let the first node apply, others will see the version already
recorded and skip.

**When to use:** Small clusters (2-5 nodes) on the same network. Full mesh
topology. Good for HA and moderate scale. Not suitable for large clusters or
multi-region.

### Cloud-Native (No Distributed Erlang)

In Kubernetes, Fly.io, or similar platforms, distributed Erlang is often
impractical:
- Dynamic IPs and pod churn make node discovery fragile
- Full mesh doesn't scale beyond ~50 nodes
- The distribution protocol has a large security surface
- Stateless horizontal scaling is the expected model

In this model, each BEAM node is independent. Cross-node communication goes
through PostgreSQL (which you already have) and Shigoto (which you already have).
No Redis, no NATS, no additional infrastructure.

#### The Shigoto Broadcast Pattern

The core idea: **every cross-node event is a Shigoto fanout job**. All nodes
consume the fanout queue. When a node picks up a job, it broadcasts locally
via `pg` to the affected sessions, which push to clients via WebSocket.

```
Producer Node                 PostgreSQL              All Consumer Nodes
     │                            │                         │
     │── shigoto:insert(...)────►│                         │
     │   (broadcast queue)        │                         │
     │                            │── fanout poll ─────────►│
     │                            │   (no locking,          │── local pg lookup
     │                            │    time-window)         │── broadcast to sessions
     │                            │                         │── WS push to clients
```

Fanout jobs are ephemeral — they live in the database for a configurable
window (default 120s), then are automatically pruned. Workers must be
idempotent. If a node misses a broadcast (e.g. during restart), the client
catches up from the database on reconnect. The database is always the
source of truth; fanout is best-effort push.

#### Architecture Diagram

```
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│      Pod A       │  │      Pod B       │  │      Pod C       │
│  WS/HTTP         │  │  WS/HTTP         │  │  WS/HTTP         │
│  Sessions (pg)   │  │  Sessions (pg)   │  │  Sessions (pg)   │
│  Matches (local) │  │  Matches (local) │  │  Matches (local) │
│  Shigoto worker  │  │  Shigoto worker  │  │  Shigoto worker  │
└────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘
         │                     │                     │
         └─────────────────────┼─────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │     PostgreSQL      │
                    │  ┌───────────────┐  │
                    │  │ shigoto_jobs  │  │  ← shared job queue
                    │  │ asobi tables  │  │  ← application state
                    │  └───────────────┘  │
                    └─────────────────────┘
```

No Redis. No NATS. No distributed Erlang. Just PostgreSQL.

#### What Goes Through the Fanout Queue

| Event | Producer | Consumer Behavior |
|-------|----------|-------------------|
| Session revocation (ban/delete) | Admin action | All nodes: `asobi_presence:disconnect/2` locally |
| Chat message (cross-pod) | Sender's pod | All nodes: deliver to local `pg` chat group members |
| Notification | Any service | All nodes: push to player's local session if connected |
| Presence update | Any pod | All nodes: update local presence state |
| Matchmaker ticket | Player's pod | One node (matchmaker leader): process ticket |

#### What Does NOT Go Through the Fanout Queue

| Event | Why | Mechanism |
|-------|-----|-----------|
| Match state (10 Hz) | Too fast, must be local | Local `pg` on same pod (sticky placement) |
| Match input | Same pod as match | Direct `gen_statem:cast` |
| Leaderboard flush | Already DB-backed | Local buffer → periodic `asobi_repo:insert` |

#### Sticky Match Placement

The matchmaker assigns a pod for each match. All matched players connect (or
get routed) to that pod. The match process, player sessions, and game tick
loop stay local — no cross-pod communication at 10 Hz.

The load balancer routes by match ID or a session cookie set during the
matchmaker flow.

#### Migrations

Run as a separate Kubernetes Job or init container before the deployment rolls
out. Do not race migrations across pods — use a single job with Kura's
advisory lock as a safety net.

## Match Placement: Same Node vs Distributed

**Should all players in a match be on the same node?**

Yes, for real-time games. The match server ticks at 10 Hz and broadcasts state
to all players. If players are on different nodes:

- **Distributed Erlang:** Works, but adds ~0.1-1ms per message hop. At 10 Hz
  with 10 players on 3 nodes, that's 100 cross-node messages/second. Tolerable
  for small clusters, but adds jitter.
- **Cloud-native:** Unacceptable without distributed Erlang. You'd need to
  serialize state to Redis/NATS per tick, which adds latency and complexity.

**Recommendation:** Use sticky match placement. The matchmaker assigns a node,
all matched players connect (or get routed) to that node for the duration of the
match. This keeps the tight game loop local.

**For non-real-time features** (leaderboards, chat, social, inventory): these
are request/response or low-frequency pub/sub. Cross-node or cross-pod
communication via the Shigoto fanout queue is fine.

## Summary: Which Model When

| Scale | Model | Notes |
|-------|-------|-------|
| Dev / small prod | Single node | Simplest. Up to ~10K concurrent connections. |
| Medium (HA needed) | Distributed Erlang, 2-5 nodes | Add global matchmaker, global match registration. Sticky match placement. |
| Large / cloud-native | Independent pods + Shigoto/PG | Cross-pod events via Shigoto fanout queue. Sticky match placement. No Redis/NATS needed. Migration via job. |

The current codebase is designed for single-node. Moving to distributed Erlang
requires making the matchmaker cluster-aware (global registration or a shared
queue via `pg`). Moving to cloud-native requires only PostgreSQL — Shigoto
provides the durable fanout queue for cross-pod broadcast, and `pg` handles
local-node session routing. No additional infrastructure beyond what you
already have.
