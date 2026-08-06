# Architecture

## What a node is

An asobi node is a single Erlang/OTP release holding the game backend, the Lua
runtime and the operator console. There is no separate scripting service and no
separate admin service. The image is `ghcr.io/widgrensit/asobi` and the release
binary inside it is `bin/asobi` (`Dockerfile:75`).

Two front doors onto the same node:

- Run the image and write Lua. `match.lua` or a `config.lua` manifest is loaded
  at boot and drives matches, worlds and bots.
- Depend on the Hex package and write Erlang. Implement the `asobi_match`
  behaviour and register the module under `game_modes`.

Both reach the same processes, the same database and the same console.

## Supervision tree

`asobi_sup` is `one_for_one`, 10 restarts in 60 seconds
(`src/asobi_sup.erl:16-20`). Nineteen children, in this order
(`src/asobi_sup.erl:21-41`):

```
asobi_sup (one_for_one)
├── asobi_rate_limits             temporary; registers the seki limiter buckets
├── asobi_oidc_providers          temporary; starts OIDC workers only if providers are configured
├── asobi_auth_cache              per-node bearer-token cache
├── asobi_cluster                 node discovery; returns `ignore` unless `cluster` is set
├── asobi_player_session_sup      simple_one_for_one
│   └── asobi_player_session      one per connected socket
├── asobi_match_sup               simple_one_for_one; owns the asobi_match_state table
│   └── asobi_match_server        one per match (gen_statem)
├── asobi_world_sup               owns asobi_world_state and asobi_player_worlds
│   ├── asobi_zone_snapshotter
│   ├── asobi_world_registry
│   └── asobi_world_instance_sup  simple_one_for_one
│       └── asobi_world_instance  one_for_all: zone sup, zone manager, ticker, world server
├── asobi_world_lobby_server      serialises asobi_world_lobby:find_or_create/1
├── asobi_vote_sup                simple_one_for_one
│   └── asobi_vote_server         one per open vote
├── asobi_matchmaker              the queue; ticks itself
├── asobi_leaderboard_sup         simple_one_for_one
│   └── asobi_leaderboard_server  one per board
├── asobi_chat_sup                simple_one_for_one; owns the channel registry table
│   └── asobi_chat_channel        one per live channel
├── asobi_tournament_sup          simple_one_for_one
│   └── asobi_tournament_server   registered under `global`
├── asobi_presence                online set and delivery targets, over pg
├── asobi_guest_reaper            opt-in sweep of unclaimed guest accounts
├── asobi_console_session         console session table; started whether or not the console is on
├── asobi_lua_config              temporary; loads the game config
├── asobi_lua_sup
│   ├── asobi_lua_rate_limits     temporary; `game.log` budgets
│   ├── asobi_bot_sup
│   ├── asobi_bot_spawner
│   └── asobi_lua_config_watcher
└── asobi_extension_sup           one child group per installed extension
```

The last three entries are ordered deliberately and the order is load-bearing:
core children, then the Lua config load, then the Lua children, then extensions
(`src/asobi_sup.erl:44-52`). The Lua runtime used to be its own OTP
application, which started after `asobi` and therefore loaded the game config
after every `asobi_sup` child was already up. Moving the load earlier changes
what a core child that reads configuration at `start_link/0` sees at boot, so
it stays here and the old order is preserved exactly.

A game config that fails to load aborts the boot. `load_lua_game_config/0`
raises, which arrives as a supervisor `failed_to_start_child` and takes the
already-started core children down with it (`src/asobi_sup.erl:60-72`). A node
with an unloadable game config has nothing useful to serve.

`asobi_extension_sup` is last so an extension's processes start after every
core service they might call. With no extensions installed it is one idle
supervisor with no children (`src/asobi_sup.erl:81-89`).

`asobi_rate_limits` is a temporary registration child, not a server: it calls
`seki:new_limiter/2` once per bucket and returns `ignore`
(`src/asobi_sup.erl:217-305`). The buckets themselves live in seki, in memory,
per node - ten of them, covering auth, register, iap, api, ws_connect, join,
guest_global, script_log, rehome and rehome_global.

## Session lifecycle

One `asobi_player_session` process per connection, started when the socket
sends `session.connect` and stopped when the socket closes
(`src/ws/asobi_ws_handler.erl:356-370`). A session does not survive the
connection. A client that reconnects presents the same token and gets a new
session process.

```
Client              WS handler           Session              pg
  │                     │                   │                  │
  │─ WS connect ───────►│                   │                  │
  │─ session.connect ──►│                   │                  │
  │                     │ resolve_token     │                  │
  │                     │─ start_session ──►│                  │
  │                     │                   │─ join {player,Id}►│
  │◄ session.connected ─│                   │                  │
  │     ... play ...    │                   │                  │
  │─ disconnect ───────►│                   │                  │
  │                     │─ stop ───────────►│                  │
  │                     │                   │─ leave ─────────►│
```

The token is resolved once, at `session.connect`. After that the `player_id`
lives in process state and no further lookup happens on the hot path. The
session monitors the WebSocket process, and `terminate/3` calls
`asobi_player_session:stop/1` for the other direction.

### The auth cache

Bearer tokens are opaque 32 random bytes issued by `nova_auth` and stored in
`player_tokens` (`src/asobi_auth.erl:6-18`,
`src/migrations/m20260329095708_update_schema.erl:185`). They are not JWTs, so
resolving one is a database read, and both the HTTP plugin and the WebSocket
handler go through a per-node ETS cache to avoid doing it per request
(`src/plugins/asobi_auth_plugin.erl:11`, `src/ws/asobi_ws_handler.erl:914`).

Entries expire after `auth_cache_ttl_ms`, default 60000 ms; negative results
expire after `auth_cache_negative_ttl_ms`, default 5000 ms
(`src/auth/asobi_auth_cache.erl:94-95`). That TTL is the bound on revocation
latency: a token revoked through `asobi_auth_tokens` or
`asobi_auth_cache:revoke_player/1` is invalidated immediately on the node that
did it, and everywhere else within the TTL. Access tokens are valid for 60
minutes and refresh tokens for 30 days, both `nova_auth` defaults
(`src/asobi_auth.erl:15`).

The cache is per node. Nothing replicates it.

## Session revocation

```erlang
asobi_presence:revoke_session(PlayerId, ~"banned").
```

`revoke_session/2` enqueues a job on the `broadcast` fanout queue
(`src/social/asobi_presence.erl:121-123`). Every node consumes the fanout
queue, and `asobi_broadcast_worker:perform/1` calls
`asobi_presence:disconnect/2` locally, which looks the player up in the local
`pg` group and sends `{session_revoked, Reason}` to each session process
(`src/workers/asobi_broadcast_worker.erl:24-25`).

`asobi_broadcast_worker` is the only worker asobi ships, and it handles exactly
three job types: `session_revoked`, `notification` and `chat`. Anything else
logs `unknown_broadcast_type` and returns ok.

Fanout jobs are ephemeral - a 120 second window in the dev config
(`config/dev_sys.config.src`), auto-pruned. The database is the source of
truth; the fanout is a best-effort push.

## Match lifecycle

`asobi_match_server` is a `gen_statem` under `asobi_match_sup`
(`src/matches/asobi_match_server.erl:60-62`,
`src/matches/asobi_match_sup.erl:22-33`). States are `waiting`, `running`,
`paused` and `finished`; a cancellation is a transition to `finished` with a
`cancelled` result, not a state of its own.

```
Matchmaker           Match sup         Match server        Players (pg)
  │                     │                   │                   │
  │─ start_match(Cfg)──►│                   │                   │
  │                     │─ start_link ─────►│ waiting           │
  │─ join(Pid, P1) ────────────────────────►│                   │
  │─ join(Pid, P2) ────────────────────────►│ running           │
  │                     │                   │◄─ {input, ...} ───│
  │                     │                   │── tick ───────────│
  │                     │                   │── broadcast ─────►│
  │                     │                   │ finished          │
  │                     │                   │── persist ───────►DB
```

Server-authoritative: the match process owns all game state, clients send
inputs, the server applies them on the tick and broadcasts the result. The tick
is a `state_timeout`, default 100 ms
(`src/matches/asobi_match_server.erl:47,200`).

The game module implements the `asobi_match` behaviour. Only `init/1` and
exactly one of `get_state/2` (per player) or `get_state/1` (shared,
broadcast-once) are required; everything else is optional, including
`join/2`, `join/3`, `leave/2`, `handle_input/3`, `tick/1`, `vote_requested/1`,
`vote_resolved/3`, `phases/1`, `on_phase_started/2` and `on_phase_ended/2`
(`src/matches/asobi_match.erl:30-128`). See
[Performance tuning](performance-tuning.md) for when the shared form pays.

### Finding a match

A match joins the `pg` group `{asobi_match_server, MatchId}` in `nova_scope`
when it starts, and `asobi_match_server:whereis/1` resolves through that group
(`src/matches/asobi_match_server.erl:152-156,167`). Because `pg` replicates
within a scope across connected nodes, a match pid is resolvable from any node
in the cluster. The process itself does not move, and its 10 Hz broadcast stays
where it is. Nothing registers matches under `global`. Tournament
servers do: `asobi_tournament_server` starts as
`{global, {asobi_tournament_server, TournamentId}}`
(`src/tournaments/asobi_tournament_server.erl:10`).

`asobi_match_state` is a separate thing and is often misread as the registry.
It is a node-local public ETS table owned by `asobi_match_sup`
(`src/matches/asobi_match_sup.erl:12`) into which a match writes a
pid-stripped snapshot of its state, so a crashed match restarted by its
supervisor on the same node resumes rather than starting empty
(`src/matches/asobi_match_server.erl:948-968`). It is a crash-recovery buffer,
it is per node, and it does not survive the node.

## Matchmaker

One `asobi_matchmaker` gen_server per node. It ticks itself with
`erlang:send_after/3` - once in `init/1` and once at the end of every tick
handler (`src/matches/asobi_matchmaker.erl:217,342`). The default interval is
1000 ms and the default wait before a ticket expires is 60 seconds, both under
the `matchmaker` key as `tick_interval` and `max_wait_seconds`.

Tickets are a plain map in the gen_server's own state
(`src/matches/asobi_matchmaker.erl:229,236-270`). There is no ticket table, no
ticket schema and nothing persisted: the queue dies with the node, and a
player queued against one node can never be matched with a player queued
against another. Plan for that before you run more than one node - see
[Clustering](clustering.md).

One live ticket per player *per mode*. Re-adding while already queued for the
same mode returns the existing ticket rather than minting a second, so a
double-tapped "find match" cannot fill one player into a self-match
(`src/matches/asobi_matchmaker.erl:246-252`). A player may hold tickets in two
different modes at once.

Grouping is a strategy module - `fill` (first-come, first-served) and
`skill_based` (expanding window) ship. There is no query language and no region
concept; filtering beyond `mode` happens inside your strategy against the
ticket's `properties` map. When a group fills, the matchmaker starts the match
through `asobi_match_sup` on its own node.

## Lua subsystem

The Lua runtime is fifteen modules under `src/lua/` plus the bot modules. It is
not a wrapper around asobi; it is part of it.

**Registration.** `asobi_app:start/2` calls
`asobi_lua_sup:register_game_modes/0` before the supervision tree comes up,
which registers `asobi_lua_match`, `asobi_lua_match_shared` and
`asobi_lua_world` as the providers for the three Lua mode kinds
(`src/asobi_app.erl:14,41-42`, `src/lua/asobi_lua_sup.erl:16-20`). Without that
registration every `{lua, Script}` mode resolves to
`{error, lua_runtime_unavailable}` (`src/asobi_game_modes.erl:92-100`). This is
what makes a Lua mode resolvable at all, and it happens ahead of every
`asobi_sup` child including the matchmaker.

**Config load.** `asobi_lua_config:maybe_load_game_config/0` reads either a
single `match.lua` or a `config.lua` manifest mapping mode names to script
paths (`src/lua/asobi_lua_config.erl:5-20`). If neither file exists it is a
no-op, so an Erlang project that configures modes in `sys.config` is
unaffected. If a file exists and is broken, the boot fails - fail-closed, as
described under the supervision tree above.

**Loader and sandbox.** `asobi_lua_loader` builds the Luerl state and clears
every dangerous standard-library entry point: `os.execute`, `os.exit`,
`os.getenv`, `os.remove`, `os.rename`, `os.tmpname`, the whole of `io`,
`dofile`, `loadfile`, `load`, `loadstring`, and the whole of `package`
(`src/lua/asobi_lua_loader.erl:1-31`). `package` is replaced by a controlled
`require/1` that resolves names relative to the loaded script's directory and
rejects parent traversal and absolute paths. `init_sandboxed/0` gives a
hardened state with no script attached, used for evaluating a `config.lua`
manifest; `new/1` loads a script and pins its base directory. The API surface a
script sees is `asobi_lua_api` and `asobi_lua_surface`; see
[Lua API](lua-api.md).

**Configuration keys.** The runtime's own keys go through
`asobi_lua_env:get_env/2` (`src/lua/asobi_lua_env.erl:22-32`), which reads
`asobi_lua` before `asobi` so a `sys.config` written against the old separate
application did not become dead config at the merge. See
[Which application key](configuration.md#which-application-key).

## World and zone subsystem

Twenty-two modules under `src/world/`. A world is long-lived, partitioned into
zones on a grid, and ticked by its own process.

`asobi_world_instance` is a `one_for_all` supervisor per world holding a zone
supervisor, a zone manager, a ticker and the world server, started in that
order because the world server discovers the others through the supervisor
(`src/world/asobi_world_instance.erl:30-78`). One world therefore lives entirely
on one node: its server, its ticker and every one of its zone processes are
children of one supervisor tree on one BEAM. Worlds do not migrate.

The world server joins the `pg` group `{asobi_world_server, WorldId}` so a
world is discoverable from any connected node
(`src/world/asobi_world_server.erl:174,187`). Two node-local public ETS tables
back it: `asobi_world_state`, holding zone entity snapshots, and
`asobi_player_worlds`, mapping a player to the world they are in
(`src/world/asobi_world_sup.erl:26-36`). Both are node-local, and both are
`public`, which is an explicit trust boundary - anything running in the same
BEAM can read and write them, and a sandboxed runtime layered on top must keep
its sandbox out of them.

See [World server](world-server.md) and [Large worlds](large-worlds.md).

## Leaderboards

One `asobi_leaderboard_server` per board, hydrating its ETS tables from
`leaderboard_entries` before it accepts reads
(`src/leaderboards/asobi_leaderboard_server.erl:120-122`).

The ETS table is an `ordered_set` keyed on `{-Score, PlayerId}`, so iteration
order is rank order (`src/leaderboards/asobi_leaderboard_server.erl:138-168`).
`sub_score` is written to the database as 0 and takes no part in ordering
(`src/leaderboards/asobi_leaderboard_server.erl:362`); it exists as a column,
not as a tiebreak.

A 30 second timer inside the board process flushes dirty players to Postgres
(`src/leaderboards/asobi_leaderboard_server.erl:123,177,180`). Each flush
upserts only the players that changed since the last one; a player whose write
fails stays pending and is retried. `terminate/2` flushes, so a clean restart
does not lose scores.

The exported API is `submit/3`, `top/2`, `rank/2`, `around/3` and
`live_boards/0` (`src/leaderboards/asobi_leaderboard_server.erl:6`). There is
no `reset/0`, no archive table and no scheduled reset. Time-scoped boards are
something you build with separate board ids.

## Chat

One `asobi_chat_channel` process per live channel, members tracked in the `pg`
group `{chat, ChannelId}`. A send fans out to the group's members and then
inserts the row inline, in the same `handle_cast`
(`src/social/asobi_chat_channel.erl:131-137,204-219`). There is no batching job
and no async persist queue. Channel types and who may reach them are in
`asobi_chat_acl`.

## Presence

`asobi_presence` records two separate things: the delivery target for a player
and membership of the online set. `track/2` records both; `track_bot/2` records
only the delivery target, so bots receive broadcasts without counting toward
`online_count/0` (`src/social/asobi_presence.erl:15`). Status changes go out
over `nova_pubsub`, not the fanout queue.

Everything `asobi_presence:send/2` delivers is one of the shapes in
`t:asobi_presence:message/0`.

## Extensions and the RPC seam

An extension is an OTP application listed in the release that declares a
manifest. `asobi_extension_sup` starts one child group per installed extension,
last in the tree. Extensions contribute no routes.

Clients reach an extension over the WebSocket, through one frame type:

```json
{"type": "rpc.call", "cid": "c-1",
 "payload": {"protocol": 1, "method": "shop.buy", "params": {"sku": "hat"}}}
```

The reply is `rpc.ok` with a `result`, or `rpc.error` with the standard error
object:

```json
{"type": "rpc.ok",    "cid": "c-1", "payload": {"result": {"reward": 100}}}
{"type": "rpc.error", "cid": "c-1", "payload": {"error": {"code": "...", "message": "...", "details": {}}}}
```

`cid` is required on `rpc.call` and validated, unlike the rest of the socket
where it is optional - it is the only way a client pairs a reply with the call
it made, and it is bounded and checked rather than reflected unchanged. A
rejected `cid` is not echoed back (`src/extensions/asobi_rpc.erl:12-25,118-128`).
Every client SDK speaks this. See [Extensions](extensions.md).

## Ops plane and console

The node serves an operator console at `/console` and an ops HTTP API at
`/api/v1/ops/*`, on the same listener as the game
(`src/asobi_router.erl:25-26,214,282`).

The two are gated separately. `/console` needs `console` to be true; the ops
routes are always mounted and reject everything until an `ops_secret` is
configured, so a stock node serves neither. [Operator console](console.md) owns
the detail.

Core's ops routes are all reads. Every route carries a capability class -
`read`, `player_data` or `config` (`src/ops/asobi_ops_caps.erl:22`) - and the
only route that mutates is `/api/v1/ops/ext/:extension/:action`, whose
behaviour comes from an installed extension.

The console holds no privileged path into the database. It reads the ops plane
over HTTP like any other client. It was previously a separate project,
`asobi_admin`, which read the same database directly; that is archived, because
a second deployment to secure and keep in step was the wrong shape for
something an operator opens during an incident.

## Database and migrations

Each node runs its own pgo pool through Kura. Migrations are Erlang modules in
`src/migrations/` and run at application start, before the supervision tree,
via `kura_migrator:migrate(asobi_repo)` (`src/asobi_app.erl:16-22`).

- All operations in one migration run in a single PostgreSQL transaction under
  an advisory lock, so only one node migrates at a time and the rest wait. Safe
  for a rolling deploy.
- Kura topologically sorts `create_table` operations by foreign-key dependency,
  so ordering within a migration file does not matter.
- Never edit or delete an applied migration. Add an `alter_table` migration.
- A failed migration logs `migration_failed` and the node carries on starting,
  but `asobi_readiness:mark_ready/0` is not called - the node comes up and
  reports itself unready rather than dying.

## Running more than one node

Everything above describes one node, which is the shape asobi is designed
around: a match lives on one node, a world lives on one node, and neither
migrates.

[Clustering](clustering.md) is the single source of truth for what is and is
not cluster-safe, and holds the complete list of per-node state. Do not infer
it from this page. Before you go further, four facts about a node that shape
every clustering decision:

- The matchmaker queue and its tickets are in one gen_server's state, per node,
  never persisted.
- The console session store and its CSRF secret are per node and per boot.
- Rate-limit buckets and the auth cache are per node.
- Matches and worlds are pinned to the node that started them.

Postgres is shared, so everything persistent is consistent across nodes.
`pg`-scoped lookups - presence, chat, match and world `whereis` - resolve
across connected nodes.

Sticky routing, where you need it, is a load-balancer configuration you own.
asobi does not implement placement, does not assign nodes, and sets no cookie
for it; the only cookies in the codebase are the console's
(`src/console/asobi_console_session.erl`).
