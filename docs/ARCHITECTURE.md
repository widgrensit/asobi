# Architecture

This document describes Asobi's internal architecture, supervision trees,
data model, and protocol design.

> This is an internal design document. It is not published to HexDocs and is not
> the API reference. For the canonical, maintained references see the
> [Architecture guide](../guides/architecture.md) (supervision, lifecycles,
> deployment models), the [REST API guide](../guides/rest-api.md) (every HTTP
> endpoint and status code), and the
> [WebSocket protocol guide](../guides/websocket-protocol.md) (the message catalogue).

## Stack

| Layer | Technology |
|-------|-----------|
| HTTP / REST | Nova (Cowboy) |
| WebSocket | Nova WebSocket (Cowboy) |
| Database / ORM | Kura (PostgreSQL via pgo) |
| Authentication | nova_auth |
| Background Jobs | Shigoto |
| Pub/Sub / Presence | `pg` module + Nova PubSub |
| Telemetry | OpenTelemetry (opentelemetry_kura) |
| JSON | OTP `json` module |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Mobile Game Clients                    │
│              (Unity, Unreal, Godot, Native)              │
└────────────┬──────────────────────┬─────────────────────┘
             │ REST (JSON)          │ WebSocket (JSON)
             ▼                      ▼
┌────────────────────────────────────────────────────────┐
│                      Nova Router                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ REST API     │  │ WebSocket    │  │ Admin        │ │
│  │ Controllers  │  │ Handler      │  │ (ext. repo)  │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
└─────────┼─────────────────┼─────────────────┼──────────┘
          │                 │                 │
          ▼                 ▼                 ▼
┌────────────────────────────────────────────────────────┐
│                   Asobi Core Services                   │
│                                                         │
│  ┌─────────┐ ┌──────────┐ ┌────────┐ ┌─────────────┐  │
│  │ Players │ │ Matches  │ │ Social │ │ Economy     │  │
│  │         │ │          │ │        │ │             │  │
│  │ Session │ │ Match    │ │ Chat   │ │ Wallet      │  │
│  │ Profile │ │ Maker    │ │ Groups │ │ Inventory   │  │
│  │ Stats   │ │ Boards   │ │ Friends│ │ Store       │  │
│  └────┬────┘ └────┬─────┘ └───┬────┘ └──────┬──────┘  │
│       │           │           │              │          │
│       ▼           ▼           ▼              ▼          │
│  ┌──────────────────────────────────────────────────┐   │
│  │           pg (Pub/Sub + Presence)                │   │
│  │           ETS (Hot State + Leaderboards)         │   │
│  │           Shigoto (Background Jobs)              │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────┬───────────────────────────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │   PostgreSQL (Kura)   │
              └───────────────────────┘
```

## Supervision Tree

```
asobi_sup (one_for_one)
├── asobi_repo                          # Kura repo worker (pgo pool)
├── asobi_registry                      # global process registry (via pg)
├── asobi_presence                      # gen_server — online status via pg
│
├── asobi_player_sup (simple_one_for_one)
│   └── asobi_player_session            # gen_server per connected player
│
├── asobi_match_sup (one_for_one)
│   ├── asobi_matchmaker                # gen_server — periodic tick via Shigoto
│   └── asobi_match_runner_sup (simple_one_for_one)
│       └── asobi_match_server          # gen_statem per active match
│
├── asobi_leaderboard_sup (simple_one_for_one)
│   └── asobi_leaderboard_server        # gen_server per leaderboard (ETS-backed)
│
├── asobi_chat_sup (simple_one_for_one)
│   └── asobi_chat_channel              # gen_server per active channel
│
└── asobi_tournament_sup (simple_one_for_one)
    └── asobi_tournament_server         # gen_server per active tournament
```

### Key Design Decisions

- **simple_one_for_one** for dynamic processes (players, matches, channels) — efficient for thousands of children
- **one_for_one** at the top level — services are independent, one crash doesn't take down others
- **gen_statem for matches** — match lifecycle is inherently a state machine (waiting → running → paused → finished)
- **gen_server for everything else** — player sessions, leaderboards, chat channels are simpler request/response

## Data Model (Kura Schemas)

### Players

```
┌─────────────────────┐     ┌──────────────────────────┐
│ asobi_player        │     │ asobi_player_auth        │
├─────────────────────┤     ├──────────────────────────┤
│ id         uuid PK  │◄────│ player_id  uuid FK       │
│ username   string   │     │ id         uuid PK       │
│ display_name string │     │ provider   enum          │
│ avatar_url string   │     │ provider_id string       │
│ metadata   jsonb    │     │ credentials_hash string  │
│ banned_at  datetime │     │ inserted_at datetime     │
│ inserted_at datetime│     │ updated_at  datetime     │
│ updated_at datetime │     └──────────────────────────┘
└─────────────────────┘
         │
         │ has_one
         ▼
┌─────────────────────┐
│ asobi_player_stats  │
├─────────────────────┤
│ player_id  uuid FK  │
│ games_played integer│
│ wins       integer  │
│ losses     integer  │
│ rating     float    │
│ rating_dev float    │
│ metadata   jsonb    │
│ updated_at datetime │
└─────────────────────┘
```

### Economy

```
┌─────────────────────┐     ┌──────────────────────────┐
│ asobi_wallet        │     │ asobi_transaction        │
├─────────────────────┤     ├──────────────────────────┤
│ id         uuid PK  │     │ id           uuid PK     │
│ player_id  uuid FK  │     │ wallet_id    uuid FK     │
│ currency   enum     │     │ amount       integer     │
│ balance    integer  │     │ balance_after integer    │
│ inserted_at datetime│     │ reason       enum        │
│ updated_at datetime │     │ reference_type string    │
└─────────────────────┘     │ reference_id   string    │
                            │ metadata     jsonb       │
                            │ inserted_at  datetime    │
                            └──────────────────────────┘

┌─────────────────────┐     ┌──────────────────────────┐
│ asobi_item_def      │     │ asobi_player_item        │
├─────────────────────┤     ├──────────────────────────┤
│ id         uuid PK  │     │ id           uuid PK     │
│ slug       string   │◄────│ item_def_id  uuid FK     │
│ name       string   │     │ player_id    uuid FK     │
│ category   enum     │     │ quantity     integer     │
│ rarity     enum     │     │ metadata     jsonb       │
│ stackable  boolean  │     │ acquired_at  datetime    │
│ metadata   jsonb    │     │ updated_at   datetime    │
│ inserted_at datetime│     └──────────────────────────┘
└─────────────────────┘

┌─────────────────────┐
│ asobi_store_listing │
├─────────────────────┤
│ id         uuid PK  │
│ item_def_id uuid FK │
│ currency   enum     │
│ price      integer  │
│ active     boolean  │
│ valid_from datetime │
│ valid_until datetime│
│ metadata   jsonb    │
└─────────────────────┘
```

### Social

```
┌─────────────────────┐     ┌──────────────────────────┐
│ asobi_friendship    │     │ asobi_group              │
├─────────────────────┤     ├──────────────────────────┤
│ id         uuid PK  │     │ id           uuid PK     │
│ player_id  uuid FK  │     │ name         string      │
│ friend_id  uuid FK  │     │ description  string      │
│ status     enum     │     │ max_members  integer     │
│ inserted_at datetime│     │ open         boolean     │
│ updated_at datetime │     │ metadata     jsonb       │
└─────────────────────┘     │ creator_id   uuid FK     │
 (pending/accepted/blocked) │ inserted_at  datetime    │
                            │ updated_at   datetime    │
                            └──────────────────────────┘
                                       │
                            ┌──────────┴───────────────┐
                            │ asobi_group_member       │
                            ├──────────────────────────┤
                            │ group_id   uuid FK       │
                            │ player_id  uuid FK       │
                            │ role       enum          │
                            │ joined_at  datetime      │
                            └──────────────────────────┘
                             (owner/admin/member)
```

### Chat & Notifications

```
┌─────────────────────┐     ┌──────────────────────────┐
│ asobi_chat_message  │     │ asobi_notification       │
├─────────────────────┤     ├──────────────────────────┤
│ id         uuid PK  │     │ id           uuid PK     │
│ channel_type enum   │     │ player_id    uuid FK     │
│ channel_id string   │     │ type         enum        │
│ sender_id  uuid FK  │     │ subject      string      │
│ content    string   │     │ content      jsonb       │
│ metadata   jsonb    │     │ read         boolean     │
│ sent_at    datetime │     │ sent_at      datetime    │
└─────────────────────┘     └──────────────────────────┘
 (room/group/direct)
```

### Matches, Leaderboards & Tournaments

```
┌─────────────────────┐     ┌──────────────────────────┐
│ asobi_match_record  │     │ asobi_leaderboard_entry  │
├─────────────────────┤     ├──────────────────────────┤
│ id         uuid PK  │     │ leaderboard_id string    │
│ mode       string   │     │ player_id    uuid FK     │
│ status     enum     │     │ score        bigint      │
│ players    jsonb    │     │ sub_score    bigint      │
│ result     jsonb    │     │ metadata     jsonb       │
│ metadata   jsonb    │     │ updated_at   datetime    │
│ started_at datetime │     └──────────────────────────┘
│ finished_at datetime│
│ inserted_at datetime│     ┌──────────────────────────┐
└─────────────────────┘     │ asobi_tournament         │
                            ├──────────────────────────┤
┌─────────────────────┐     │ id           uuid PK     │
│ asobi_cloud_save    │     │ name         string      │
├─────────────────────┤     │ leaderboard_id string    │
│ player_id  uuid FK  │     │ max_entries   integer    │
│ slot       string   │     │ entry_fee    jsonb       │
│ data       jsonb    │     │ rewards      jsonb       │
│ version    integer  │     │ start_at     datetime    │
│ updated_at datetime │     │ end_at       datetime    │
└─────────────────────┘     │ metadata     jsonb       │
                            │ inserted_at  datetime    │
                            └──────────────────────────┘

┌─────────────────────┐
│ asobi_storage       │
├─────────────────────┤
│ collection string   │
│ key        string   │
│ player_id  uuid FK  │  (nullable — global objects have no owner)
│ value      jsonb    │
│ version    integer  │
│ read_perm  enum     │
│ write_perm enum     │
│ updated_at datetime │
└─────────────────────┘
 (public/owner/none)
```

## Process Architecture

### Player Session (`asobi_player_session` — gen_server)

One process per connected player. Manages WebSocket state, presence, and acts as a message router.

```
Client ←→ WebSocket Handler ←→ Player Session Process
                                    │
                                    ├── pg groups: presence, player-specific topics
                                    ├── Tracks: current match, world, chat channels
                                    └── Handles: heartbeat, disconnect cleanup
```

**State:**
```erlang
#{
    player_id => uuid(),
    ws_pid => pid(),                    %% WebSocket handler process
    match_pid => pid() | undefined,     %% current match process
    channels => [binary()],             %% joined chat channels
    presence => #{status => binary(), metadata => map()},
    connected_at => integer()
}
```

**Lifecycle:**
1. WebSocket connects → auth validated → `asobi_player_session:start_link/2`
2. Joins `pg` groups for presence tracking
3. Routes incoming WebSocket messages to appropriate service
4. On disconnect → leaves all groups, notifies match/chat, cleans up

### Match Server (`asobi_match_server` — gen_statem)

One process per active match. Runs the game loop with configurable tick rate.

```
State Machine:
  waiting ──[enough players]──→ running ──[game over]──→ finished
     │                            │                         │
     │ ←──[player leaves]        │ ←──[pause]──→ paused   │
     │                            │                         │
     └──[timeout]──→ cancelled   └──[error]──→ crashed    done
```

**States:**
- `waiting` — accepting players, waiting for minimum count
- `running` — game loop active, ticking at configured rate
- `paused` — game loop suspended (all players disconnected, admin pause)
- `finished` — game over, results calculated, persisting to DB
- `cancelled` — not enough players, timeout

**Game Logic Behaviour:**

Game developers implement the `asobi_match` behaviour to define their game:

```erlang
-module(asobi_match).

-callback init(Config :: map()) ->
    {ok, GameState :: term()}.

-callback join(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()} | {error, Reason :: term()}.

-callback leave(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback handle_input(PlayerId :: binary(), Input :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback tick(GameState :: term()) ->
    {ok, GameState1 :: term()} |
    {finished, Result :: map(), GameState1 :: term()}.

-callback get_state(PlayerId :: binary(), GameState :: term()) ->
    StateForPlayer :: map().
```

**Tick loop** runs at a configurable rate (default 10/sec). Each tick:
1. Collect queued player inputs
2. Call `Mod:tick(GameState)` with accumulated inputs
3. Compute state diff per player via `Mod:get_state/2`
4. Broadcast diffs over WebSocket

### Matchmaker (`asobi_matchmaker` — gen_server)

Runs periodic matching ticks. Strategy modules group tickets; the shipped
strategies are `fill` (FCFS) and `skill_based` (expanding window).

**Ticket** (`asobi_matchmaker:add/2`):
```erlang
#{
    id => binary(),
    player_id => binary(),
    mode => binary(),
    properties => map(),        %% game-defined, read by your strategy
    submitted_at => integer(),
    status => pending
}
```

There is no query expression and no party field. Ticket filtering beyond
`mode` happens inside your strategy module against `properties`. See
[Matchmaking](../guides/matchmaking.md).

**Algorithm (each tick):**
1. Load all active tickets from ETS
2. Group by mode/region
3. Within each group, find mutually compatible tickets (both match each other's query)
4. Form matches from compatible pools (fill to min/max player count)
5. For unfilled tickets, increment `expansion_level` (widens skill range)
6. Tickets past max wait time → return error to player
7. Matched tickets → spawn `asobi_match_server`, notify players

**Query language:**
```
+region:eu-west mode:ranked skill:>=800 skill:<=1200
```

### Leaderboard Server (`asobi_leaderboard_server` — gen_server)

Hybrid ETS + PostgreSQL. ETS for hot reads, Kura for persistence.

**ETS table** per leaderboard: `ordered_set` keyed by `{-Score, -SubScore, PlayerId}` for automatic ordering.

**Operations:**
- `submit(BoardId, PlayerId, Score)` — insert/update in ETS, async persist via Shigoto
- `top(BoardId, N)` — read top N from ETS (microsecond response)
- `around(BoardId, PlayerId, N)` — player's rank ± N entries from ETS
- `rank(BoardId, PlayerId)` — player's rank via ETS position
- `reset(BoardId)` — snapshot to archive table, clear ETS, Shigoto job

**Time-scoped boards:** Shigoto schedules resets (daily/weekly/monthly). On reset, current entries archived to `asobi_leaderboard_archive` with period metadata.

### Chat Channel (`asobi_chat_channel` — gen_server)

One process per active channel. Uses `pg` for member management.

**Channel types:**
- `room` — named persistent channel (e.g., `~"chat:lobby"`)
- `group` — tied to a group/guild
- `direct` — between two players
- `match` — ephemeral, tied to a match lifetime

**Flow:**
1. Player joins channel → process joins `pg` group `{chat, ChannelId}`
2. Send message → broadcast to all members via `pg`
3. Messages persisted to `asobi_chat_message` via Shigoto (async)
4. History loaded from Kura on join (paginated)

### Presence (`asobi_presence` — gen_server)

Tracks online players and their status using `pg`.

**Design:**
- Player session joins `pg` group `{presence, PlayerId}` on connect
- Status updates broadcast via Nova PubSub on channel `presence`
- Friends receive presence updates by subscribing to their friends' presence topics
- `pg` automatically cleans up when processes die — no stale presence

## WebSocket Protocol

Single WebSocket connection per client. JSON message envelope:

### Client → Server

```json
{
    "cid": "optional-correlation-id",
    "type": "message.type",
    "payload": {}
}
```

### Server → Client

```json
{
    "cid": "correlation-id-if-request-response",
    "type": "message.type",
    "payload": {}
}
```

### Message Types

The authoritative message catalogue is the
[WebSocket protocol guide](../guides/websocket-protocol.md). The handler
(`asobi_ws_handler`) routes each `type` to the owning service; the client sends
input, the server decides and broadcasts state deltas.

### WebSocket Handler (`asobi_ws_handler`)

Implements `nova_websocket` behaviour. Routes messages to the appropriate service:

```erlang
websocket_handle({text, Raw}, State) ->
    #{~"type" := Type, ~"payload" := Payload} = json:decode(Raw),
    Cid = maps:get(~"cid", json:decode(Raw), undefined),
    Result = route_message(Type, Payload, State),
    reply_if_needed(Cid, Result, State).

route_message(~"match.input", Payload, #{match_pid := Pid} = _State) ->
    asobi_match_server:handle_input(Pid, Payload);
route_message(~"chat.send", Payload, State) ->
    asobi_chat:send_message(Payload, State);
%% ...etc
```

## REST API

The HTTP endpoint reference is the [REST API guide](../guides/rest-api.md). It is
the single source of truth for paths, methods, and status codes; this document does
not repeat it. All endpoints sit under `/api/v1` and exchange JSON. Routing lives in
`asobi_router.erl`; the controllers are the `*_controller` modules under
[Project Structure](#project-structure).

The client sends intent over these endpoints, the server decides, and the server
persists and broadcasts the result.

## Admin

This node ships no admin console. The dashboard is a separate project,
[asobi_admin](https://github.com/widgrensit/asobi_admin), which reads the same
database. There is no `/admin` route in `asobi_router.erl`, and asobi no longer
depends on Arizona.

## Background Jobs (Shigoto)

| Job | Schedule | Description |
|-----|----------|-------------|
| `matchmaker_tick` | Every 1s | Run matchmaking algorithm |
| `leaderboard_persist` | Every 30s | Flush ETS leaderboard changes to PostgreSQL |
| `leaderboard_reset` | Cron-based | Reset time-scoped leaderboards, archive entries |
| `tournament_lifecycle` | Every 1m | Start/end tournaments based on schedule |
| `chat_persist` | Every 5s | Batch-persist chat messages from memory to DB |
| `notification_push` | On-demand | Send push notifications via APNs/FCM |
| `iap_reconcile` | Every 1h | Reconcile IAP receipts with store APIs |
| `presence_cleanup` | Every 5m | Safety net for stale presence (pg handles most) |
| `analytics_flush` | Every 1m | Flush telemetry events to analytics pipeline |
| `player_stats_sync` | Every 5m | Aggregate match results into player stats |

## Security

### Authentication Flow

1. Client authenticates via REST (email/password, device ID, or platform provider)
2. Server returns JWT session token (short-lived, 15min) + refresh token (long-lived, 30 days)
3. REST requests include token in `Authorization: Bearer <token>` header
4. WebSocket authenticates via `session.connect` message with token
5. Server validates token, starts player session process

### Server-Authoritative Design

- All game state mutations go through `asobi_match_server`
- Economy operations are ACID transactions via Kura Multi
- Client never directly modifies server state
- Leaderboard submissions validated against match results
- Purchase receipts validated server-side with Apple/Google APIs

### Rate Limiting

Nova plugin for per-player rate limiting:
- REST: token bucket per endpoint per player
- WebSocket: message rate limit per type
- Matchmaking: one active ticket per player

## Scaling Strategy

### Single Node (Phase 1)

One BEAM node handles everything. Target: 50K concurrent players.

```
Single Node
├── Nova (HTTP + WS)
├── All game processes
├── ETS tables
└── PostgreSQL connection pool
```

### Clustered (Phase 2)

Multiple BEAM nodes with distributed Erlang. `pg` handles cross-node pub/sub.

```
                    Load Balancer (sticky sessions for WS)
                    ┌───────────┬───────────┐
                    ▼           ▼           ▼
                 Node A      Node B      Node C
                    │           │           │
                    └─────── pg ────────────┘  (cluster-wide pub/sub)
                              │
                         PostgreSQL
```

- Player session lives on the node the WebSocket connected to
- Match processes can spawn on any node (least-loaded selection)
- Leaderboard ETS replicated across nodes or centralized on dedicated node
- Matchmaker runs on one node (elected leader) or partitioned by mode/region
- `pg` handles all cross-node messaging transparently

### Database Scaling (Phase 3)

- Read replicas for leaderboard persistence and analytics queries
- Connection pooling per node via pgo
- Table partitioning for high-volume tables (transactions, chat messages, analytics)

## Project Structure

```
asobi/
├── src/
│   ├── asobi_app.erl                    # OTP application
│   ├── asobi_sup.erl                    # Top-level supervisor
│   ├── asobi_router.erl                 # Nova router
│   ├── asobi_repo.erl                   # Kura repo
│   │
│   ├── asobi_ws_handler.erl             # WebSocket handler + message routing
│   │
│   ├── asobi_player.erl                 # Player schema
│   ├── asobi_player_auth.erl            # Player auth schema
│   ├── asobi_player_stats.erl           # Player stats schema
│   ├── asobi_player_session.erl         # gen_server per player
│   ├── asobi_player_controller.erl      # REST controller
│   │
│   ├── asobi_match.erl                  # Match behaviour (game devs implement)
│   ├── asobi_match_server.erl           # gen_statem per match
│   ├── asobi_match_record.erl           # Match record schema
│   ├── asobi_match_controller.erl       # REST controller
│   │
│   ├── asobi_matchmaker.erl             # Matchmaking gen_server
│   ├── asobi_matchmaker_query.erl       # Query parser/evaluator
│   ├── asobi_matchmaker_controller.erl  # REST controller
│   │
│   ├── asobi_leaderboard_server.erl     # gen_server per board (ETS)
│   ├── asobi_leaderboard_entry.erl      # Leaderboard entry schema
│   ├── asobi_leaderboard_controller.erl # REST controller
│   │
│   ├── asobi_wallet.erl                 # Wallet schema
│   ├── asobi_transaction.erl            # Transaction ledger schema
│   ├── asobi_item_def.erl               # Item definition schema
│   ├── asobi_player_item.erl            # Player item instance schema
│   ├── asobi_store_listing.erl          # Store listing schema
│   ├── asobi_economy.erl               # Economy operations (Multi transactions)
│   ├── asobi_iap.erl                    # IAP receipt validation
│   ├── asobi_economy_controller.erl     # REST controller
│   ├── asobi_inventory_controller.erl   # REST controller
│   │
│   ├── asobi_friendship.erl             # Friendship schema
│   ├── asobi_group.erl                  # Group schema
│   ├── asobi_group_member.erl           # Group member schema
│   ├── asobi_social_controller.erl      # REST controller
│   │
│   ├── asobi_chat_channel.erl           # gen_server per channel
│   ├── asobi_chat_message.erl           # Chat message schema
│   ├── asobi_chat_controller.erl        # REST (history endpoint)
│   │
│   ├── asobi_tournament.erl             # Tournament schema
│   ├── asobi_tournament_server.erl      # gen_server per tournament
│   ├── asobi_tournament_controller.erl  # REST controller
│   │
│   ├── asobi_notification.erl           # Notification schema
│   ├── asobi_notification_controller.erl # REST controller
│   │
│   ├── asobi_cloud_save.erl             # Cloud save schema
│   ├── asobi_storage.erl                # Generic storage schema
│   ├── asobi_storage_controller.erl     # REST controller
│   │
│   ├── asobi_presence.erl               # Presence tracking via pg
│   ├── asobi_auth_plugin.erl            # Nova plugin — JWT validation
│   ├── asobi_rate_limit_plugin.erl      # Nova plugin — rate limiting
│   └── asobi_telemetry.erl              # Telemetry setup
│
├── include/
│   └── asobi.hrl                        # Shared records/macros
│
├── priv/
│   ├── migrations/                      # Kura migrations
│   └── static/                          # Admin dashboard assets
│
├── test/
│   ├── asobi_match_SUITE.erl
│   ├── asobi_matchmaker_SUITE.erl
│   ├── asobi_leaderboard_SUITE.erl
│   ├── asobi_economy_SUITE.erl
│   ├── asobi_social_SUITE.erl
│   ├── asobi_chat_SUITE.erl
│   ├── asobi_ws_SUITE.erl
│   └── asobi_api_SUITE.erl
│
├── docs/
│   └── ARCHITECTURE.md                  # This file
│
├── config/
│   ├── sys.config
│   └── vm.args
│
├── docker-compose.yml                   # PostgreSQL
├── rebar.config
├── rebar.lock
└── .github/
    └── workflows/
        └── ci.yml                       # erlang-ci
```

## Configuration

### sys.config

```erlang
[
    {nova, [
        {bootstrap_application, asobi_arena},
        {environment, dev},
        {cowboy_configuration, #{
            port => 8084
        }},
        {json_lib, json}
    ]},
    {kura, [
        {repo, asobi_repo},
        {host, "localhost"},
        {port, 5432},
        {database, "asobi_dev"},
        {user, "postgres"},
        {password, "postgres"},
        {pool_size, 10}
    ]},
    {shigoto, [
        {pool, asobi_repo}
    ]},
    {asobi, [
        {plugins, [
            {pre_request, nova_request_plugin, #{
                decode_json_body => true,
                parse_qs => true
            }},
            {pre_request, nova_cors_plugin, #{
                allow_origins => <<"*">>
            }},
            {pre_request, nova_correlation_plugin, #{}}
        ]},
        {game_modes, #{
            ~"arena" => asobi_arena_game
        }},
        {matchmaker, #{
            tick_interval => 1000,
            max_wait_seconds => 60
        }},
        {session, #{
            token_ttl => 900,
            refresh_ttl => 2592000
        }}
    ]},
    {pg, [{scope, [nova_scope, arizona_pubsub]}]}
].
```

## Dependencies

`rebar.config` is the authoritative list. asobi builds on Nova, Kura (with
kura_postgres), nova_auth, nova_auth_oidc, nova_resilience, seki, and Shigoto. It
does not depend on Arizona.

## Build Phases

### Phase 1 — Foundation
- Project scaffold (rebar3 nova)
- PostgreSQL + Docker Compose
- Kura repo + initial migrations
- Player schema + CRUD
- nova_auth integration (register, login, JWT)
- REST API skeleton with auth plugin
- CI setup (erlang-ci)

### Phase 2 — Real-Time
- WebSocket handler with message routing
- Player session process (gen_server)
- Presence tracking via pg
- Chat system (channels, messaging, persistence)

### Phase 3 — Game Infrastructure
- Match behaviour definition
- Match server (gen_statem) with tick loop
- Matchmaker with query-based matching
- Leaderboard server (ETS + Kura hybrid)
- Example game implementation (simple card game or trivia)

### Phase 4 — Economy
- Wallet + transaction ledger
- Item definitions + player inventory
- Store catalog + purchase flow
- IAP receipt validation (Apple + Google)

### Phase 5 — Social & Live Ops
- Friends system
- Groups/guilds
- Tournaments
- Cloud saves
- Push notifications (via Hikyaku)
- Generic key-value storage

### Phase 6 — Admin & Polish
- Arizona admin dashboard
- Telemetry + observability
- Rate limiting plugin
- Security hardening
- Documentation + guides

