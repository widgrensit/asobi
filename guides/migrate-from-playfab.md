# Migrating from PlayFab to asobi

If you're reading this, you've probably been through the PlayFab v2
migration, watched features quietly get removed, or watched your Azure
bill climb while the product got thinner. You're not alone — the
[Imperium42 write-up](https://medium.com/@imperium42/the-silent-death-of-playfab-29614f5b9f15)
catalogues the situation far better than we can.

This guide walks you from "my PlayFab stack is working but brittle" to
"I run my game on a Docker container I own."

> **Draft notice.** This guide is a starting point, not a playbook — nobody
> has yet migrated a shipped PlayFab title to asobi end-to-end. The
> asobi-side endpoints and events below are verified against the current
> code. PlayFab-side SDK names come from the public PlayFab documentation
> and may have drifted. **The fastest path is pairing with us in the
> [Discord](https://discord.gg/vYSfYYyXpu) `#migrations` channel.**

## TL;DR

1. Your Unity/Unreal/JS game keeps shipping. You don't touch the client.
2. Stand up asobi in parallel on Hetzner / Fly / your laptop.
3. Port one PlayFab API domain at a time — usually **Auth → Player
   Inventory → Virtual Currency → Leaderboards → Matchmaking**, in that
   order.
4. When all domains are ported, flip a feature flag to point at asobi and
   retire the PlayFab Title.

## Why asobi specifically

- **Apache-2.0, open-source, self-hostable.** Not a Microsoft product, not
  a SaaS. The repos are [widgrensit/asobi](https://github.com/widgrensit/asobi)
  and [widgrensit/asobi_lua](https://github.com/widgrensit/asobi_lua). See
  the [exit guide](exit.md) if you want to know what happens if *we*
  disappear.
- **Flat infra cost.** PlayFab Essentials starts free but scales steeply
  through compute-based tiers, Data Explorer add-ons, and dedicated
  multiplayer server VMs. asobi is a single container whose cost you
  control — a small Hetzner box (€5-15/mo) comfortably holds thousands of
  players.
- **Linux dedicated servers work.** Unlike PlayFab's Unreal OSS SDK which
  historically forced Windows hosts (and their licensing costs), asobi
  just runs in any Linux container.
- **Hot-reload Lua.** Ship a fix at 11pm. Connected players stay connected.
- **One matchmaking service.** Not three (Client::Matchmaker, Multiplayer
  Matchmaking 2.0, OSS SDK) with no canonical guidance — just
  `asobi_matchmaker` with pluggable strategies.
- **Friends work.** Request, approve, block — all in the library.
- **Lobbies hold state.** Our matchmaker tickets + match "waiting" phase
  replace the v1 Lobby. Not the stateless read-only v2 Lobby that broke
  half the games on PlayFab.

## Concept map

| PlayFab | asobi | Notes |
|---|---|---|
| **Title** | Tenant / deployment | One Docker container per environment (dev/live). |
| **TitleId** + SDK config | Base URL of your asobi deployment | No opaque ID — you point the SDK at a URL. |
| **Entity (`master_player_account`)** | Player | Same concept: durable ID + profile. |
| **Virtual Currency** | Economy | `game.economy.grant`, `debit`, `balance`, `purchase`. Multiple named currencies; per-player ledgers. |
| **Catalog** | Store + inventory | `asobi_store_listing` + `asobi_item_def` tables; `/api/v1/store`. |
| **Inventory** | Inventory | `game.player_items` in Lua / `/api/v1/inventory` REST. |
| **CloudScript (JS functions)** | Lua in `match.lua` + REST controllers | Your server logic runs as part of the match process — no separate Functions runtime, no cold starts. |
| **Matchmaking (Queue)** | `asobi_matchmaker` | Strategies: `fill`, `skill_based`, or bring your own via `asobi_matchmaker_strategy`. |
| **Multiplayer Server (Build)** | Match process | No container-per-match. One Docker container hosts thousands of matches as BEAM processes. Simpler ops, cheaper. |
| **Data → Player → KeyValue** | `/api/v1/storage/:collection/:key` | Per-player and shared collections with public/owner/none permissions. |
| **Data → Title Data** | `/api/v1/storage/global/:key` | Use a well-known collection. |
| **Data → Title Internal Data** | Erlang `sys.config` or Kura schema | Sensitive config stays out of the API. |
| **Leaderboards + Statistics** | Leaderboards (`/api/v1/leaderboards/:id`) | ETS for microsecond reads, Postgres for persistence. |
| **Friends list** | Friends (`/api/v1/friends`) | Request / approve / block / update status all work. |
| **Player Groups** | Groups (`/api/v1/groups`) | Roles, member management, chat channel per group. |
| **Push Notifications** | Notifications table + WS push | `match.notification` event or polled via `/api/v1/notifications`. |
| **PlayFab Party (voice/chat)** | Chat channels + DM | Text only. For voice, pair asobi with Vivox / Dissonance / a WebRTC service. |
| **Receipt validation (IAP)** | `/api/v1/iap/apple`, `/api/v1/iap/google` | Verifies Apple App Store and Google Play receipts. |
| **Automation rules / webhooks** | Shigoto jobs | Write the rule as an Erlang callback or Lua handler. |
| **Insights / Analytics** | `asobi_telemetry` + your pipeline | We emit telemetry; pipe to Prometheus / Grafana / ClickHouse. No hosted analytics yet. |
| **Game Manager (web console)** | [asobi_admin](https://github.com/widgrensit/asobi_admin) | Players, leaderboards, economy, chat. Pre-1.0. |

## Migration path

### Phase 1 — stand up asobi alongside PlayFab (1 day)

Bring up asobi on a spare machine:

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

```bash
docker compose up -d
curl localhost:8080/api/v1/auth/register \
  -H 'content-type: application/json' \
  -d '{"username":"alice","password":"hunter2"}'
# → { "player_id": "...", "session_token": "...", "username": "alice" }
```

### Phase 2 — port Auth (2-5 days)

PlayFab auth paths map 1:1:

```csharp
// Before (PlayFab)
PlayFabClientAPI.LoginWithCustomID(new LoginWithCustomIDRequest {
  CustomId = deviceId, CreateAccount = true
}, OnSuccess, OnError);

// After (asobi) — generate creds once, persist locally, then login
var client = new AsobiClient("https://api.my-game.com");
if (!PlayerPrefs.HasKey("asobi_pw")) {
  PlayerPrefs.SetString("asobi_pw", Guid.NewGuid().ToString("N"));
  await client.Auth.RegisterAsync(deviceId, PlayerPrefs.GetString("asobi_pw"));
} else {
  await client.Auth.LoginAsync(deviceId, PlayerPrefs.GetString("asobi_pw"));
}
```

OAuth providers (Google, Apple, Steam) go through
`POST /api/v1/auth/oauth` — same as PlayFab's `LoginWithGoogleAccount` etc.

### Phase 3 — port the data domains one at a time (1-2 weeks)

Run PlayFab and asobi in parallel. For each domain:

- Migrate the PlayFab data snapshot to asobi's Postgres schema (one-off
  script per domain)
- Dual-write: the client hits PlayFab AND asobi for the same action
- Read from asobi; diff vs PlayFab for a day
- Switch reads to asobi; keep PlayFab dual-write for rollback
- After a week of clean asobi reads, stop writing to PlayFab

Order: **Leaderboards → Inventory → Virtual Currency → Storage → Friends →
Groups → Matchmaking**. Leave matchmaking last because it's the most
stateful handoff.

### Phase 4 — port CloudScript (2 days – 2 weeks)

Rewrite each CloudScript function either as:

- A **Lua callback** in `match.lua` (for per-match logic — e.g.
  `handle_input`, `tick`)
- An **asobi REST controller** in Erlang (for domain logic — economy
  rules, tournament brackets, daily quest resets)

If your PlayFab workload is CloudScript-heavy, budget more time for this
phase. The upside: hot-reload replaces the CloudScript deploy loop.

### Phase 5 — cut over (1 day)

Flip the SDK base URL from PlayFab to your asobi endpoint via a feature
flag. Monitor for 24h. Retire the PlayFab Title.

## Deploy story

| Host | Fit | Rough cost |
|---|---|---|
| **Hetzner Cloud** (CX22–CX42) | Best price/perf. EU-only. | €4–15 / month |
| **Scaleway Serverless** | Auto-scale for dev / low traffic | Free tier → pay per req |
| **Fly.io** | Multi-region one-liner | $5+/month/region |
| **Clever Cloud** | git-push deploy, EU | €10+/month |
| **On-prem (your datacentre)** | Regulated / sovereign workloads | Your hardware cost |

A studio running PlayFab Multiplayer Servers at, say, $300/month in VM
credits typically fits on a €15/month Hetzner CX32 box with asobi.

## Things asobi does NOT do (compared to PlayFab)

- **No hosted analytics dashboard.** We emit telemetry; you pipe it
  somewhere. PlayFab Insights is the biggest DX gap.
- **No built-in A/B testing / segmentation framework.** Coming in 2026. For
  now, roll it in your match logic.
- **No push notification service.** Use OneSignal, Firebase Cloud
  Messaging, or APNs directly.
- **No hosted voice.** Pair with Vivox / Dissonance / Agora.
- **No Title-as-a-product support tools** (refunds portal, player support
  console). On the admin dashboard roadmap.
- **No mandated Entity model.** asobi is pragmatic: player_id is the
  primary key; you don't have to model everything as Entity-With-Objects.

## Things asobi does that PlayFab doesn't

- Hot-reload game logic without dropping players
- Open-source — read the code, fork it, own it
- Linux servers are first-class
- One unified matchmaker, not three competing services
- Friends / groups / chat / votes / tournaments / seasons / phases as
  first-class primitives, not bolt-ons
- Built-in voting system (plurality, ranked, approval, weighted)
- Godot and Defold SDKs at engine-parity with Unity

## Cost comparison

| | PlayFab Essentials | PlayFab paid | asobi self-host | asobi managed (soon) |
|---|---|---|---|---|
| Base | Free tier | $99+/mo | €5–20/mo infra | ~€9–29/mo |
| Multiplayer servers | N/A | VM-minute billing | Same container | Included |
| Analytics add-ons | Limited | Data Explorer metered | Bring your own stack | Bring your own |
| Egress | N/A | Azure rates | Your host's rates | Flat |
| Vendor lock-in | High (Azure) | High | None (Apache-2) | Exit runbook |

## Do this today

- [ ] `git clone` [asobi_lua](https://github.com/widgrensit/asobi_lua) and
  `docker compose up`. Register a player. Confirm it works.
- [ ] Pick the smallest PlayFab API your game calls (often leaderboards
  or a single CloudScript function). Port it to asobi in a feature flag.
- [ ] Join the [Discord](https://discord.gg/vYSfYYyXpu) `#migrations`
  channel. We'll sanity-check your staging order.

## Getting help

- **Discord**: [#migrations](https://discord.gg/vYSfYYyXpu) channel
- **Email**: hello@asobi.dev
- **GitHub Discussions**: [widgrensit/asobi_lua/discussions](https://github.com/widgrensit/asobi_lua/discussions)

## See also

- [Migrating from Hathora](migrate-from-hathora.md)
- [Migrating from Nakama self-host](migrate-from-nakama.md)
- [Exit guarantee](exit.md)
- [Comparison vs Nakama, Colyseus, SpacetimeDB](comparison.md)
