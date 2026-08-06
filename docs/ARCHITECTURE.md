# Architecture

An internal design note. It is not published to HexDocs and it is not the API
reference.

The maintained references are the [Architecture guide](../guides/architecture.md)
(what a node is, the supervision tree, lifecycles, per-subsystem detail), the
[REST API guide](../guides/rest-api.md) (every HTTP endpoint and status code),
the [WebSocket protocol guide](../guides/websocket-protocol.md) (the message
catalogue) and [Clustering](../guides/clustering.md) (what is and is not
cluster-safe). Where this file and a guide disagree, the guide wins.

## Stack

| Layer | Technology |
|-------|-----------|
| HTTP / REST | Nova (Cowboy) |
| WebSocket | Nova WebSocket (Cowboy) |
| Database | Kura with `kura_backend_postgres`, over pgo |
| Authentication | nova_auth, nova_auth_oidc |
| Rate limiting / resilience | seki, nova_resilience |
| Lua runtime | Luerl |
| Background jobs | Shigoto |
| Pub/sub and presence | `pg` plus Nova PubSub |
| Telemetry | plain `telemetry` events |
| JSON | OTP `json` module |

Telemetry is `telemetry:execute/3` and nothing else. asobi attaches no
exporter, depends on no OpenTelemetry package, and holds the event surface in
one list in `asobi_telemetry:events/0`, asserted against the module's own
`execute` calls by `asobi_telemetry_tests`. Consumers - an OpenTelemetry
bridge, a Prometheus scraper, your own handler - attach out of tree. See
`docs/adr/0005-telemetry-event-surface.md`.

## Overview

```
┌─────────────────────────────────────────────────────────┐
│                     Game clients                        │
│    (Godot, Defold, LÖVE, Unity, Unreal, JS, Dart)       │
└────────────┬──────────────────────┬─────────────────────┘
             │ REST (JSON)          │ WebSocket (JSON)
             ▼                      ▼
┌────────────────────────────────────────────────────────┐
│                      Nova router                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ REST         │  │ WebSocket    │  │ Console +    │  │
│  │ controllers  │  │ handler      │  │ ops plane    │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
└─────────┼─────────────────┼─────────────────┼──────────┘
          ▼                 ▼                 ▼
┌────────────────────────────────────────────────────────┐
│                     Core services                      │
│                                                        │
│  ┌─────────┐ ┌──────────┐ ┌────────┐ ┌─────────────┐   │
│  │ Players │ │ Matches  │ │ Social │ │ Economy     │   │
│  │ Session │ │ Worlds   │ │ Chat   │ │ Wallet      │   │
│  │ Profile │ │ Maker    │ │ Groups │ │ Inventory   │   │
│  │ Stats   │ │ Boards   │ │ Friends│ │ Store       │   │
│  └────┬────┘ └────┬─────┘ └───┬────┘ └──────┬──────┘   │
│       ▼           ▼           ▼             ▼          │
│  ┌──────────────────────────────────────────────────┐  │
│  │  pg (pub/sub + presence)                         │  │
│  │  ETS (match backup, boards, caches, registries)  │  │
│  │  Luerl (game scripts)                            │  │
│  │  Shigoto (the broadcast fanout queue)            │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────┬──────────────────────────────┘
                          ▼
              ┌───────────────────────┐
              │   PostgreSQL (Kura)   │
              └───────────────────────┘
```

The console and the ops plane are part of this node, not a second deployment.

## Supervision tree

Regenerated from `src/asobi_sup.erl` in the
[Architecture guide](../guides/architecture.md#supervision-tree), including the
boot order the merge made load-bearing. It is not duplicated here; two copies
is how the last one drifted.

Design decisions worth stating once:

- `simple_one_for_one` for dynamic children - sessions, matches, world
  instances, boards, chat channels, votes, tournaments.
- `one_for_one` at the top: services are independent and one crash does not
  take the others down.
- `gen_statem` for matches, because a match is a state machine.
- `one_for_all` inside a world instance, because its zone supervisor, zone
  manager, ticker and world server are meaningless without each other.

## Data model

23 Kura schemas. Each module carries its own `table/0` and `fields/0`; read
those rather than a diagram, which is what went stale here before.

| Area | Schema module | Table |
|---|---|---|
| Players | `asobi_player` | `players` |
| | `asobi_player_stats` | `player_stats` |
| | `asobi_player_identity` | `player_identities` |
| | `asobi_player_token` | `player_tokens` |
| Matches | `asobi_match_record` | `match_records` |
| | `asobi_vote` | `votes` |
| Worlds | `asobi_zone_snapshot` | `zone_snapshots` |
| Leaderboards | `asobi_leaderboard_entry` | `leaderboard_entries` |
| Tournaments | `asobi_tournament` | `tournaments` |
| Economy | `asobi_wallet` | `wallets` |
| | `asobi_transaction` | `transactions` |
| | `asobi_item_def` | `item_defs` |
| | `asobi_player_item` | `player_items` |
| | `asobi_store_listing` | `store_listings` |
| | `asobi_iap_transaction` | `iap_transactions` |
| Social | `asobi_friendship` | `friendships` |
| | `asobi_group` | `groups` |
| | `asobi_group_member` | `group_members` |
| | `asobi_chat_message` | `chat_messages` |
| | `asobi_notification` | `notifications` |
| Storage | `asobi_cloud_save` | `cloud_saves` |
| | `asobi_storage` | `storage` |
| Ops | `asobi_ops_audit_entry` | `ops_audit_entries` |

Enum-looking columns (`provider`, `currency`, `reason`, `category`, `rarity`,
`status`, `channel_type`, read and write permissions) are `string` in Kura, not
PostgreSQL enums. Validation is in the changeset, not the column type.

## Process architecture

### Player session (`asobi_player_session`, gen_server)

One process per connection. It holds the authenticated `player_id`, monitors
the WebSocket process, tracks the player's current match, world, zone and chat
channels, and routes to them.

```erlang
#{
    player_id => binary(),
    ws_pid => pid(),
    match_pid => pid() | undefined,
    channels => [binary()],
    presence => #{status := binary()},
    connected_at => integer()
    %% world_pid and zone_pid are added by set_zone/3 on a world join
}
```

It dies with the socket. Reconnection presents the same token and produces a
new process.

### Match server (`asobi_match_server`, gen_statem)

One process per match.

```
waiting ──[min players]──► running ──[game over]──► finished
   │                          │  ▲                     ▲
   │                          ▼  │                     │
   │                        paused                     │
   └────────────────[cancel or timeout]────────────────┘
```

`cancelled` is a result value on the `finished` state, not a state.

The game module implements the `asobi_match` behaviour. `init/1` plus exactly
one of `get_state/2` or `get_state/1` is the required minimum; the rest -
`join/2`, `join/3`, `leave/2`, `handle_input/3`, `tick/1`, `vote_requested/1`,
`vote_resolved/3`, `phases/1`, `on_phase_started/2`, `on_phase_ended/2` - are
optional. Each tick drains queued inputs, calls `tick/1`, then broadcasts
either one shared payload or one payload per player. Default tick is 100 ms.

### Matchmaker (`asobi_matchmaker`, gen_server)

One per node. It schedules its own tick with `erlang:send_after/3`; nothing
external drives it and no job queue is involved.

Tickets are entries in a map in the process's own state:

```erlang
#{
    id => binary(),
    player_id => binary(),
    mode => binary(),
    properties => map(),        %% game-defined, read by your strategy
    submitted_at => integer(),
    status => pending,
    attempts => 0
}
```

There is no ticket table and no ticket schema. The queue dies with the node.

One live ticket per player *per mode*: re-adding while already queued for the
same mode returns the existing ticket. A player may hold tickets in different
modes at the same time.

Each tick: group the tickets by mode, hand each group to the configured
strategy (`fill` or `skill_based`), start a match through `asobi_match_sup` for
each filled group on this node, expire anything past `max_wait_seconds`, keep
the rest. There is no query parser, no party field and no region concept.
Filtering beyond `mode` belongs in your strategy module, against `properties`.
See [Matchmaking](../guides/matchmaking.md).

### Leaderboard server (`asobi_leaderboard_server`, gen_server)

One per board. ETS for reads, PostgreSQL for the truth.

The table is an `ordered_set` keyed `{-Score, PlayerId}`, so iteration is rank
order. `sub_score` is persisted as 0 and plays no part in ordering.

- `submit/3` - update ETS, mark the player dirty
- `top/2`, `around/3`, `rank/2` - read from ETS
- `live_boards/0` - the boards with scores in memory

A 30 second timer in the board process flushes dirty players, upserting only
what changed; a failed write stays pending for the next flush. `terminate/2`
flushes. A board hydrates from `leaderboard_entries` before serving reads.

There is no `reset/0`, no archive table and no scheduled reset. A "weekly
board" is a separate board id.

### Chat channel (`asobi_chat_channel`, gen_server)

One per live channel. Members are a `pg` group `{chat, ChannelId}`. A send
fans out to the group, then inserts the `chat_messages` row inline in the same
callback - there is no batching worker. A bounded in-process buffer keeps
recent messages for a fast history read; older history comes from Postgres.

Channel naming and who may reach which channel are in `asobi_chat_acl`.

### Presence (`asobi_presence`, gen_server)

Delivery target and online-set membership are recorded separately: `track/2`
records both, `track_bot/2` records only the delivery target, so bots receive
broadcasts without inflating `online_count/0`. `pg` cleans up when a process
dies, so there is no stale presence to sweep. Status changes broadcast over
Nova PubSub.

## WebSocket protocol

One connection per client, JSON envelope both ways:

```json
{"cid": "optional-correlation-id", "type": "message.type", "payload": {}}
```

`cid` is echoed on a reply to a request. It is optional everywhere except
`rpc.call`, where it is required and validated.

The message catalogue is the
[WebSocket protocol guide](../guides/websocket-protocol.md). `asobi_ws_handler`
routes each `type` to the owning service; the client sends input, the server
decides and broadcasts.

Errors are always the wire object, never an internal reason atom:

```json
{"error": {"code": "matchmaker.unknown_mode", "message": "...", "details": {}}}
```

Codes and their HTTP statuses live in one list in `src/asobi_error.erl`.

## REST API

Paths, methods and status codes are the
[REST API guide](../guides/rest-api.md). Routing is `src/asobi_router.erl`;
controllers are the `*_controller` modules under `src/controllers/`.

## Console and ops plane

The node serves an operator console at `/console` and an ops HTTP API at
`/api/v1/ops/*`, on the same listener as the game.

The two are gated separately. `/console` needs `console` to be true; the ops
routes are always mounted and reject everything until an `ops_secret` is
configured, so a stock node serves neither.
[Operator console](../guides/console.md) owns the detail.

Core's ops routes are all reads. Every core route carries a capability class -
`read`, `player_data` or `config` (`src/ops/asobi_ops_caps.erl`) - and the only
route that mutates is `/api/v1/ops/ext/:extension/:action`, whose behaviour
comes from an installed extension.

The console holds no privileged path into the database; it reads the ops plane
over HTTP like any other client. It used to be a separate project,
`asobi_admin`, reading the same database directly. That is archived: a second
deployment to run, secure and keep in step was the wrong shape for something an
operator opens during an incident.

## Background jobs

One worker: `asobi_broadcast_worker`, on the `broadcast` fanout queue. Every
node consumes the queue, so every node sees every job. Three job types:

| Type | Effect on each node |
|---|---|
| `session_revoked` | `asobi_presence:disconnect/2` for the player, locally |
| `notification` | push to the player's local session if connected |
| `chat` | deliver to local members of the channel |

Anything else logs `unknown_broadcast_type`. `max_attempts` is 1 and jobs are
pruned after their window, so the queue is a best-effort push and the database
is the source of truth.

Everything else that could look like a job is not one. The matchmaker ticks
itself. Leaderboards flush on their own 30 second timer. Chat rows are inserted
inline by the channel process. Player stats are folded into `player_stats` by
`asobi_match_server` inside the same transaction that writes the match record,
so the counters and the match history cannot disagree.

## Security

### Authentication

1. The client registers or logs in over REST (password, device, guest, or an
   OAuth/OIDC provider).
2. The server returns `player_id`, `access_token`, `refresh_token` and
   `username`. Both tokens are opaque 32 random bytes issued by `nova_auth` and
   stored in `player_tokens`. They are not JWTs and carry no claims. Access is
   valid 60 minutes, refresh 30 days.
3. REST requests carry `Authorization: Bearer <access_token>`.
4. The WebSocket authenticates with `session.connect` carrying the same token.
5. Both paths resolve the token through `asobi_auth_cache`, a per-node ETS
   cache with a 60 second TTL (5 seconds for negatives). That TTL bounds
   revocation latency across a cluster.

`asobi_auth_plugin` is the Nova plugin that does step 3. It resolves a bearer
token; it does not validate a JWT.

### Server-authoritative design

- All match state mutations go through `asobi_match_server`.
- Each economy operation is one `asobi_repo:transaction/1`, serialised by a
  Postgres advisory transaction lock on `(player_id, currency)`. That is what
  makes concurrent debits on the same wallet safe; it is not Kura `Multi`.
- Client score submission is refused by default. `POST /leaderboards/:id`
  answers `leaderboard.client_submit_disabled` unless the board id is listed in
  `leaderboard_client_submit`; the intended path is server code calling
  `asobi_leaderboard_server:submit/3` from a finished match.
- IAP receipts are verified server-side: Apple's signed transaction against
  Apple's root certificates locally, Google's purchase token against the Play
  Android Publisher API. Both refuse with `*_iap_not_configured` until the
  bundle id or package name is set.

### Rate limiting

`asobi_rate_limit_plugin` selects a bucket per path (auth, register, iap, api)
and `asobi_ws_handler` gates the socket upgrade. Buckets are seki limiters
registered at boot and held in memory, per node - a 5/s bucket in a
three-node cluster is 15/s in aggregate. Matchmaking allows one active ticket
per player per mode.

## Scaling

One node is the design point: a match lives on one node, a world lives on one
node, and neither migrates. [Clustering](../guides/clustering.md) is the single
source of truth for what a second node does and does not buy you, and holds the
complete list of per-node state. Measured numbers are in
[Benchmarks](../guides/benchmarks.md); do not put a target here.

Migrations run under a Kura advisory lock, so a rolling deploy is safe: the
first node to start applies them and the rest wait, then see the version
already recorded.

## Project layout

`src/` is one directory per subsystem, compiled recursively
(`{src_dirs, [{"src", [{recursive, true}]}]}`).

| Directory | Holds |
|---|---|
| `src/` (top level) | application, supervisor, router, repo, error codes, telemetry, game-mode registry, cluster discovery |
| `src/auth/` | token issue and cache, OIDC config, Steam, IAP verification |
| `src/console/` | the operator console: shell, assets, session, CSP, environment |
| `src/controllers/` | REST controllers |
| `src/economy/` | wallets, transactions, items, listings |
| `src/extensions/` | extension resolution, supervision, the RPC dispatcher, `rebar3 asobi check` |
| `src/iap/` | IAP transaction schema |
| `src/leaderboards/` | board processes and entries |
| `src/lua/` | the Lua runtime: loader, sandbox, bridges, config, reload |
| `src/matches/` | match behaviour, match server, matchmaker and strategies |
| `src/migrations/` | Erlang migration modules |
| `src/notifications/` | notification schema and delivery |
| `src/ops/` | the ops plane: auth, capabilities, per-area readers, audit |
| `src/players/` | player, stats, identity, token, session |
| `src/plugins/` | Nova plugins: auth, rate limit, body cap, client gate, security headers |
| `src/social/` | presence, chat, DMs, friends, groups |
| `src/storage/` | cloud saves and generic key-value storage |
| `src/timers/` | phases, entity timers, reconnect windows |
| `src/tournaments/` | tournament server and schema |
| `src/votes/` | vote server and schema |
| `src/workers/` | `asobi_broadcast_worker` |
| `src/world/` | world instances, zones, terrain, spatial index, lobby |
| `src/ws/` | WebSocket handler and binary framing |

`priv/` holds two things: `priv/console/` (the built console bundle and its
manifest) and `priv/protocol/` (protocol fixtures and their README).

## Configuration

`config/dev_sys.config.src` is the worked example. Abridged:

```erlang
[
    {nova, [
        {bootstrap_application, asobi},
        {environment, dev},
        {cowboy_configuration, #{port => 8082}},
        {json_lib, json},
        {plugins, [
            {pre_request, asobi_body_cap_plugin, #{
                max_body => 1048576,
                require_content_length => true
            }},
            {pre_request, nova_request_plugin, #{
                decode_json_body => true,
                parse_qs => true
            }},
            {pre_request, nova_cors_plugin, #{allow_origins => ~"*"}},
            {pre_request, nova_correlation_plugin, #{}},
            {pre_request, asobi_rate_limit_plugin, #{}},
            {pre_request, asobi_client_gate_plugin, #{}},
            {post_request, asobi_security_headers_plugin, #{}}
        ]}
    ]},
    {kura, [
        {repo, asobi_repo},
        {backend, kura_backend_postgres},
        {host, "localhost"},
        {port, 5432},
        {database, "asobi_dev"},
        {user, "postgres"},
        {password, "postgres"},
        {pool_size, 200}
    ]},
    {shigoto, [
        {pool, asobi_repo},
        {poll_interval, 500},
        {queues, [{~"default", 10}]},
        {fanout_queues, [{~"broadcast", 5, #{window => 120}}]}
    ]},
    {asobi, [
        {game_modes, #{~"arena" => my_arena_game}},
        {matchmaker, #{tick_interval => 1000, max_wait_seconds => 60}}
    ]},
    {pg, [{scope, [nova_scope, asobi_presence, asobi_chat]}]}
].
```

Notes that bite people:

- The plugin chain belongs under `{nova, [...]}`, not `{asobi, [...]}`, and the
  listed order is the order they run in. The body cap has to precede
  `nova_request_plugin`, which is what buffers the body into the heap, and the
  rate limiter has to precede `asobi_client_gate_plugin` so the cheap in-memory
  check sheds a flood before any external verification. `asobi_client_gate_plugin`
  is a no-op until `client_gate` is configured.
- `{backend, kura_backend_postgres}` is required in the `kura` block. Without
  it Kura has no dialect.
- `nova_scope` is the only scope asobi joins - matches, worlds, zones, chat
  channels, boards, presence and per-player groups all live in it. The
  `asobi_presence` and `asobi_chat` scopes in both shipped configs are started
  by the `pg` application and nothing joins them; they are inert. Left in the
  snippet because that is what the shipped config says.
- Access and refresh token lifetimes are not configurable here. They are
  `nova_auth` defaults, 60 minutes and 30 days.

Full reference: [Configuration](../guides/configuration.md).

## Dependencies

`rebar.config` is the authoritative list. asobi builds on Nova, Kura with
`kura_postgres`, nova_auth, nova_auth_oidc, nova_resilience, seki, luerl and
Shigoto. It does not depend on Arizona and it does not depend on any
OpenTelemetry package.

Two pins are deliberate. `cowboy` is pinned to `~> 2.16` to force the patched
release (CVE-2026-43966 / GHSA-w4f7-4cxr-rv3c, which affects versions below
2.16.0). `nova` is on a git ref rather than Hex until the fix for
novaframework/nova#400 releases - a websocket controller replying with a list
of frames crashes the connection process on Hex nova 0.15.1, which is why
`asobi_ws_handler` emits exactly one frame per `websocket_info/2` return.
