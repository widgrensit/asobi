# Asobi — Game Backend Platform

Asobi (遊び, "play") is an open-source game backend platform built on Erlang/OTP and the Nova ecosystem. It provides authentication, player management, real-time multiplayer, matchmaking, leaderboards, virtual economy, social features, and an admin dashboard — all in a single BEAM release.

Asobi is platform-agnostic: mobile, PC, console, web, and MMO. The transport layer (WebSocket + REST) works for any client. For latency-critical genres (FPS, action MMO), an optional UDP transport can be added alongside WebSocket without changing the core architecture.

## Competitive Landscape

Asobi targets the same space as **Nakama** (Go, Heroic Labs) and **Colyseus** (Node.js). No production-grade game backend exists on BEAM despite the platform being arguably the best fit for this workload.

### Why BEAM Over Go (Nakama)

| Concern | Nakama (Go) | Asobi (BEAM) |
|---------|-------------|--------------|
| GC impact | Stop-the-world affects ALL matches | Per-process GC — isolated per match |
| Fault tolerance | Panic = match lost | OTP supervision — match restarts |
| Deployment | Restart = disconnect everyone | Hot code upgrade — zero downtime |
| Pub/sub | Requires external Redis | `pg` module — cluster-native |
| In-memory state | External cache (Redis) | ETS — zero serialization overhead |
| Distribution | External coordination (etcd/consul) | Distributed Erlang — built in |
| Scheduling | Cooperative (goroutine blocks = starve) | Preemptive — fair scheduling |
| Connection density | ~100K per node | ~500K+ per node |

## Stack

| Layer | Technology |
|-------|-----------|
| HTTP / REST | Nova (Cowboy) |
| WebSocket | Nova WebSocket (Cowboy) |
| Database / ORM | Kura (PostgreSQL via pgo) |
| Real-time UI / Admin | Arizona Core + arizona_nova |
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
│  │ Controllers  │  │ Handler      │  │ (Arizona)    │ │
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
                                    ├── Tracks: current match, party, chat channels
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

Runs periodic matching ticks via Shigoto. Query-based matching with expanding windows.

**Ticket:**
```erlang
#{
    player_id => binary(),
    properties => #{
        skill => integer(),
        region => binary(),
        mode => binary()
    },
    query => binary(),          %% match query expression
    party => [binary()],        %% party member IDs
    submitted_at => integer(),
    expansion_level => integer()
}
```

**Algorithm (each tick):**
1. Load all active tickets from ETS
2. Group by mode/region
3. Within each group, find mutually compatible tickets (both match each other's query)
4. Form matches from compatible pools (fill to min/max player count)
5. For unfilled tickets, increment `expansion_level` (widens skill range)
6. Tickets past max wait time → return error to player
7. Matched tickets → spawn `asobi_match_server`, notify players

**Query language** (simple, like Nakama):
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

**Connection:**
- `session.connect` → authenticate WebSocket, start player session
- `session.heartbeat` → keep-alive ping/pong

**Matches:**
- `match.join` → join a match
- `match.leave` → leave current match
- `match.input` → send game input to match server
- `match.state` → server pushes state updates (delta)
- `match.started` → server notification: match began
- `match.finished` → server notification: match ended with results

**Matchmaking:**
- `matchmaker.add` → submit matchmaking ticket
- `matchmaker.remove` → cancel ticket
- `matchmaker.matched` → server notification: match found

**Chat:**
- `chat.join` → join a channel
- `chat.leave` → leave a channel
- `chat.send` → send message to channel
- `chat.message` → server pushes new message
- `chat.history` → request message history

**Social:**
- `presence.update` → update own status
- `presence.changed` → server pushes friend status change
- `notification.new` → server pushes notification

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

All REST endpoints under `/api/v1`. JSON request/response.

### Auth (nova_auth)
```
POST   /api/v1/auth/register          Register with email/password
POST   /api/v1/auth/login             Login, returns session token
POST   /api/v1/auth/link              Link additional provider
POST   /api/v1/auth/refresh           Refresh session token
POST   /api/v1/auth/device            Device ID authentication
POST   /api/v1/auth/apple             Apple Game Center auth
POST   /api/v1/auth/google            Google Play Games auth
```

### Players
```
GET    /api/v1/players/:id            Get player profile
PUT    /api/v1/players/:id            Update own profile
GET    /api/v1/players/:id/stats      Get player stats
```

### Social
```
GET    /api/v1/friends                List friends
POST   /api/v1/friends                Send friend request
PUT    /api/v1/friends/:id            Accept/reject/block
DELETE /api/v1/friends/:id            Remove friend

POST   /api/v1/groups                 Create group
GET    /api/v1/groups/:id             Get group
PUT    /api/v1/groups/:id             Update group
POST   /api/v1/groups/:id/join        Join group
POST   /api/v1/groups/:id/leave       Leave group
PUT    /api/v1/groups/:id/members/:pid Update member role
```

### Economy
```
GET    /api/v1/wallets                List player wallets
GET    /api/v1/wallets/:currency/history  Transaction history

GET    /api/v1/store                  List store catalog
POST   /api/v1/store/purchase         Purchase item

POST   /api/v1/iap/apple/verify       Validate Apple receipt
POST   /api/v1/iap/google/verify      Validate Google receipt
```

### Inventory
```
GET    /api/v1/inventory              List player items
POST   /api/v1/inventory/consume      Consume item
POST   /api/v1/inventory/equip        Equip/unequip item
```

### Leaderboards
```
GET    /api/v1/leaderboards/:id              Top N entries
GET    /api/v1/leaderboards/:id/around/:pid  Around player
POST   /api/v1/leaderboards/:id              Submit score
```

### Tournaments
```
GET    /api/v1/tournaments            List active tournaments
GET    /api/v1/tournaments/:id        Get tournament details
POST   /api/v1/tournaments/:id/join   Join tournament
```

### Storage
```
GET    /api/v1/storage/:collection/:key        Read object
PUT    /api/v1/storage/:collection/:key        Write object (with version for OCC)
DELETE /api/v1/storage/:collection/:key        Delete object
GET    /api/v1/storage/:collection             List objects in collection
```

### Cloud Saves
```
GET    /api/v1/saves                  List save slots
GET    /api/v1/saves/:slot            Get save data
PUT    /api/v1/saves/:slot            Write save (with version)
```

### Notifications
```
GET    /api/v1/notifications          List notifications (paginated)
PUT    /api/v1/notifications/:id/read Mark as read
DELETE /api/v1/notifications/:id      Delete notification
```

## Admin Dashboard (Arizona)

Arizona LiveView admin console at `/admin`. Real-time updates via Arizona PubSub.

### Views

- **Dashboard** — online players, active matches, server stats (ETS counters)
- **Players** — search, view profile, ban/unban, edit metadata, view transactions
- **Matches** — live match list, spectate match state, force-end
- **Economy** — grant/revoke currency, edit store listings, transaction audit
- **Leaderboards** — view boards, manual entry management, trigger reset
- **Groups** — view groups, moderate, edit
- **Chat** — monitor channels, moderate messages
- **Tournaments** — create/edit tournaments, view standings
- **Config** — remote config key-value editor, feature flags

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

## Dependencies (rebar.config)

```erlang
{deps, [
    {nova, {git, "https://github.com/novaframework/nova.git", {branch, "main"}}},
    {kura, {git, "https://github.com/Taure/kura.git", {branch, "main"}}},
    {arizona_core, {git, "https://github.com/novaframework/arizona_core.git", {branch, "main"}}},
    {arizona_nova, {git, "https://github.com/novaframework/arizona_nova.git", {branch, "main"}}},
    {nova_auth, {git, "https://github.com/novaframework/nova_auth.git", {branch, "main"}}},
    {shigoto, {git, "https://github.com/Taure/shigoto.git", {branch, "main"}}},
    {nova_test, {git, "https://github.com/novaframework/nova_test.git", {branch, "main"}}},
    {opentelemetry_kura, {git, "https://github.com/novaframework/opentelemetry_kura.git", {branch, "main"}}}
]}.
```

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

## Unique Selling Points

1. **Zero-downtime deploys** — hot code upgrade game logic without disconnecting players
2. **Self-healing matches** — OTP supervision restarts crashed matches
3. **Predictable latency** — per-process GC, no global pauses
4. **500K+ connections per node** — dramatically lower infrastructure costs
5. **No external dependencies for state** — ETS replaces Redis, pg replaces pub/sub services
6. **Native clustering** — distributed Erlang, no etcd/consul/Redis coordination
7. **Full Nova ecosystem** — web framework, ORM, LiveView admin, background jobs, auth, mailer all native
