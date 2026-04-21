# Migrating from Hathora to asobi

**Hathora's game-hosting service shuts down on 2026-05-05.** If you're reading
this with a running game on `hathora.dev` or `hathora.cloud`, this guide walks
you from "we need a new backend by May" to "we're running on asobi and we
never have to do this again."

> **Draft notice.** This guide is a starting point, not a battle-tested
> playbook — nobody has yet migrated a Hathora game to asobi end-to-end.
> The asobi-side endpoint and event names below are **verified against the
> current code**. The Hathora-side method names come from our memory of the
> pre-shutdown SDK and may have drifted. **The fastest path to a working
> migration is pairing with us in the
> [Discord](https://discord.gg/vYSfYYyXpu) `#migrations` channel** — we'll
> walk through your specific setup rather than you fighting this doc in the
> dark.

> This guide targets studios on Hathora's *managed* service. If you're a
> self-hosted `hathora-core` user your situation is different — skip to
> [§ Self-hosted Hathora users](#self-hosted-hathora-users).

## TL;DR

1. Your game-server logic (C#, Go, Node, whatever it is today) **keeps
   running in its own process** while you migrate.
2. You bring up an asobi_lua container. Your game-server talks to it over
   WebSocket like it would any other auth/matchmaker/leaderboard service.
3. You port the Hathora-specific calls — `createLobby`, `getRoomInfo`,
   `listActivePublicLobbies`, `HathoraClient.loginAnonymous`, etc. — to the
   asobi equivalents in the table below.
4. Once asobi is doing auth/matchmaking/lobbies, you drop Hathora entirely
   and either (a) keep running your existing server code in a plain
   container on Hetzner / Fly / Scaleway or (b) fold your game logic into an
   asobi Lua script and let asobi host that too.

Option (b) is more work up front, but it means no game-server container at
all. For most Hathora games the game-server is a few hundred lines of
state-mutation code — well within the scope of a `match.lua` file.

## Why asobi specifically

The reason you're reading this is that Hathora pivoted to AI. We don't want
that to be you again.

- **Apache-2.0, open-source, self-hostable.** The engine is at
  [github.com/widgrensit/asobi](https://github.com/widgrensit/asobi) and the
  Docker runtime is at
  [github.com/widgrensit/asobi_lua](https://github.com/widgrensit/asobi_lua).
  Fork it. Mirror it. Run it on your own hardware. Our [exit
  guide](exit.md) is a 1-page runbook for keeping your game alive if we
  vanish tomorrow.
- **No CCU billing.** Managed asobi cloud (opening later in 2026) is flat
  per-container. Self-host is free.
- **Hot-reload Lua.** Edit your match logic, save, connected matches pick it
  up — no rebuild, no redeploy, no kicked players.
- **One container, one Postgres.** No CockroachDB. No Redis. No Kubernetes.
- **Matchmaking, lobbies, rooms, leaderboards, economy, chat, friends,
  tournaments, voting, phases, seasons, reconnection** are all already there
  — see the [feature list](../README.md#features).
- **Godot and Defold SDKs are first-class**, alongside Unity/Unreal/JS/Flutter.
- **EU-hosted, GDPR-ready, NIS2-aware** if that matters to you.

## Concept map

| Hathora | asobi | Notes |
|---|---|---|
| Application | asobi deployment | One container per environment (dev/live). |
| Room | Match | An OTP process per match, state kept in the process heap with ETS backup. |
| Process | *(no equivalent)* | asobi doesn't spin a container per match. One container hosts thousands of matches as BEAM processes. Simpler ops. |
| Lobby | Matchmaker ticket + Match in "waiting" phase | Players hit `/matchmaker/tickets`; when `match_size` is reached the match transitions to "running". |
| Region | Deployment location | Deploy one container per region. No region abstraction baked in — you pick where to run the container. |
| Matchmaker (2.0) | `asobi_matchmaker` | Pluggable strategies (`fill`, `skill_based`); custom via `asobi_matchmaker_strategy` behaviour. |
| `HathoraClient.loginAnonymous` | `POST /api/v1/auth/register` with `username` + `password` | **No anonymous flag today.** You generate a random username/password in the client and persist it locally (or use OAuth). Response fields: `player_id`, `session_token`, `username`. |
| `HathoraClient.loginGoogle` | `POST /api/v1/auth/oauth` | OAuth/OIDC flow. |
| `createLobby` / `createRoom` / queue | `POST /api/v1/matchmaker` body `{"mode":"default","properties":{},"party":[playerId]}` | Response: `{"ticket_id":"...","status":"pending"}`. |
| Ticket poll | `GET /api/v1/matchmaker/:ticket_id` | |
| Cancel | `DELETE /api/v1/matchmaker/:ticket_id` | |
| `listActivePublicLobbies` | `GET /api/v1/matches` | Query params filter results. |
| `getConnectionInfo(roomId)` | WebSocket upgrade on `GET /ws` | See [§ WebSocket handshake](#websocket-handshake) — first frame must authenticate. |
| `ping` region API | *(none)* | If you need client-side region selection, probe each deployment endpoint yourself. |
| Hathora SDK | asobi SDKs | [asobi-unity](https://github.com/widgrensit/asobi-unity), [asobi-unreal](https://github.com/widgrensit/asobi-unreal), [asobi-js](https://github.com/widgrensit/asobi-js), [asobi-godot](https://github.com/widgrensit/asobi-godot), [asobi-defold](https://github.com/widgrensit/asobi-defold), [asobi-dart](https://github.com/widgrensit/asobi-dart), [flame_asobi](https://github.com/widgrensit/flame_asobi). |
| Hathora Console | [asobi-admin](https://github.com/widgrensit/asobi_admin) | Tenants, games, API keys, match inspection. Pre-1.0. |
| `hathora.yml` | `docker-compose.yml` | Plain Compose, no proprietary spec. |
| Process-hour billing | Flat per-container | No surprise invoices. |

## Migration path

### Phase 1 — stand up asobi alongside Hathora (1 day)

Run asobi on the same cloud (or locally) without touching the Hathora
deployment. Goal: verify auth, a lobby, and a match work end-to-end from
your client.

```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: my_game

  asobi:
    image: ghcr.io/widgrensit/asobi_lua:latest
    depends_on: [postgres]
    ports: ["8080:8080"]
    volumes: ["./lua:/app/game:ro"]
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: my_game
```

Put a minimal `lua/match.lua` in place (see the [asobi_lua
README](https://github.com/widgrensit/asobi_lua#quick-start)) and bring it
up:

```bash
docker compose up -d
curl localhost:8080/api/v1/auth/register \
  -H 'content-type: application/json' \
  -d '{"username":"test","password":"test1234"}'
# → { "player_id": "01HX...", "session_token": "...", "username": "test" }
```

### Phase 2 — port the client SDK calls (2–5 days)

In your Unity / Unreal / JS / Godot client, replace the Hathora SDK with the
asobi one for the same engine. The call shape is close but not identical:

**Unity — before (Hathora):**
```csharp
var client = new HathoraClient("my-app-id");
await client.LoginAnonymousAsync();
var lobby = await client.CreateLobbyAsync(Visibility.Public, …);
var info = await client.GetConnectionInfoAsync(lobby.RoomId);
// then open a websocket to info.ExposedPort.Host:Port
```

**Unity — after (asobi):**
```csharp
var client = new AsobiClient("https://api.my-game.com");
await client.Auth.RegisterAsync("alice", "hunter2");     // or LoginAsync
await client.WebSocket.ConnectAsync();                    // /ws
client.WebSocket.SendSessionConnect(sessionToken);        // first frame
client.WebSocket.On("match.matched", OnMatched);          // payload: { match_id, players }
await client.Matchmaker.QueueAsync(mode: "default");      // POST /api/v1/matchmaker
```

Matchmaker tickets resolve asynchronously over the WebSocket via the
`match.matched` event (payload `{match_id, players}`). You can poll
`GET /api/v1/matchmaker/:ticket_id` if you prefer.

Do this one feature at a time: **auth first, then WebSocket handshake, then
matchmaking, then the game-session messages**. Hathora and asobi can
coexist in the client during this phase (different base URLs).

### WebSocket handshake

Asobi expects every WebSocket client to authenticate with a `session.connect`
frame *before* it can use any other WS message type:

```json
{"type":"session.connect","payload":{"session_token":"eyJ..."}}
```

After this the server routes match/matchmaker/chat/world events to this
player. Other message types the server handles: `matchmaker.add`,
`matchmaker.remove`, `match.input`, `match.join`, `match.leave`, `chat.send`,
`chat.join`, `chat.leave`, `dm.send`, `presence.update`, `vote.cast`,
`vote.veto`, `world.list`, `world.create`, `world.find_or_create`,
`world.join`, `world.leave`, `session.heartbeat`.

Server-pushed event types follow the pattern `{domain}.{event}` — notably:
`match.matched` (matched into a game), `match.state` (full state push),
`match.finished`, `world.tick`, `world.terrain`, `chat.message`,
`dm.message`, `error`.

### Phase 3 — port the game logic (2 days – 2 weeks)

You have two choices here.

**Option A — keep your existing game server.** If you've got a lot of C#/Go
server code you'd rather not rewrite, keep running it in its own container
on Hetzner / Fly / Scaleway. Use asobi for auth, matchmaking, lobbies,
leaderboards, and persistence. When the matchmaker fires `match.matched`,
the client has a `session_token` from asobi — pass it (plus `player_id` and
`match_id`) to your game server over your own connection, and have your
game server validate the token with asobi before accepting input.

> **Reality check:** the public asobi library does not ship a built-in
> "server-to-server token validation" endpoint today — token verification
> on your own server means calling `POST /api/v1/auth/refresh` with the
> token, or adding a small validation route yourself. If this is a blocker
> for you, ping us in Discord — it's a natural library addition and we'll
> prioritise it.

**Option B — fold the game logic into Lua.** Rewrite your tick / input /
state logic as a `match.lua` file. The callbacks are:

```lua
function init(config)         -- once per match
function join(player_id, state)
function leave(player_id, state)
function handle_input(player_id, input, state)
function tick(state)           -- default 10Hz, configurable
function get_state(player_id, state)   -- per-player view
```

For most Hathora games this is a few hundred lines of Lua. You get hot
reload for free (edit + save + live matches update) and you delete a
container.

### Phase 4 — cut over (1 day)

Flip a feature flag in the client to point at the asobi endpoint. Monitor
for 24h. Shut Hathora down.

## Deploy story

You can run asobi anywhere Docker runs. Common choices:

| Host | Fit | Rough cost |
|---|---|---|
| **Hetzner Cloud** (CX22–CX42) | Best price/perf. EU-only if that matters. | €4–15 / month |
| **Scaleway Serverless** | Auto-scale for dev / low traffic | Free tier → pay per req |
| **Fly.io** | Multi-region one-liner | $5+/month/region |
| **Clever Cloud** | git-push deploy, EU | €10+/month |
| **Your laptop** | Development / LAN party | — |

Typical Hathora cost for a small-indie game was **$200–800 / month** on
process-hours. The same game on asobi at Hetzner is **€5–20 / month**,
often 10–40× cheaper.

## Pricing comparison

| | Hathora (pre-shutdown) | asobi self-host | asobi managed (soon) |
|---|---|---|---|
| Pricing model | Process-hours ($0.03–0.15/hr) + bandwidth | Flat infra cost you choose | Flat per-container |
| Free tier | Small credit | Unlimited | TBD |
| 100 CCU | ~$50–150/mo | €5–15/mo infra | ~€9/mo |
| 1,000 CCU | ~$300–800/mo | €15–50/mo infra | ~€29/mo |
| Bandwidth surcharges | Yes | No (infra cost) | No |
| Multi-region | First-class, auto | DIY (one container per region) | Per-region tier |

## Self-hosted Hathora users

If you run `hathora-core` on your own infra, your situation is better: you
still own the stack. You can keep running it as long as it works. But the
same migration strategy applies when you decide to move — asobi's single
container + Postgres is operationally simpler than Hathora's Go monolith +
Redis + Cockroach.

## Things asobi does NOT do (yet)

Be honest with yourself before committing:

- **No UDP transport.** WebSocket/TCP only. If you're a twitch FPS /
  fighting game / racing game that needs sub-3ms physics, pair asobi with a
  UDP relay (Photon, ENet server, custom). Use asobi for auth / matchmaker
  / economy / leaderboard / social.
- **No anonymous-login shortcut.** Auth is `username+password` or OAuth.
  If your Hathora game used `loginAnonymous`, you'll generate a random
  username/password in the client and persist it locally, or wire OAuth.
- **No server-to-server token validation endpoint** in the public library
  (see Option A note above).
- **No auto multi-region.** Deploy one container per region yourself.
- **No client-side prediction / rollback netcode primitives.** On the
  roadmap.
- **Pre-1.0 API.** Minor breaking changes possible until 1.0.
- **Managed cloud opens later in 2026** — today, self-host.

## Do this today

- [ ] `git clone` [asobi_lua](https://github.com/widgrensit/asobi_lua) and
  bring up `docker compose up` locally. Register a player. Confirm it works.
- [ ] Pick a single SDK call in your client to port first (usually
  `loginAnonymous`). Get it compiling against asobi.
- [ ] Join the [Discord](https://discord.gg/vYSfYYyXpu). We'll help you debug.
- [ ] Decide Option A (keep game server) vs Option B (Lua rewrite). Open
  a thread in [Discussions](https://github.com/widgrensit/asobi_lua/discussions)
  and we'll sanity-check.
- [ ] Set a cutover date before 2026-05-05.

## Getting help

- **Discord**: [#migrations](https://discord.gg/vYSfYYyXpu) channel
- **Email**: hello@asobi.dev
- **GitHub Discussions**: [widgrensit/asobi_lua/discussions](https://github.com/widgrensit/asobi_lua/discussions)

We'll prioritise Hathora-migration support through May 2026.

## See also

- [Migrating from PlayFab](migrate-from-playfab.md)
- [Migrating from Nakama self-host](migrate-from-nakama.md)
- [Exit guarantee](exit.md) — if asobi disappears tomorrow
- [Comparison vs Nakama, Colyseus, SpacetimeDB](comparison.md)
