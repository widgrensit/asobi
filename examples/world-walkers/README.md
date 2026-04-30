# Walkers — two players in one shared room

The simplest possible world demo. One persistent world, any number of
players, everyone walks around and sees each other. No matchmaking, no
zones to debug, no terrain provider, no phases.

If you're trying to build something on top of asobi and just want to
see "two avatars on a screen", **start here**.

## Run the server

```bash
docker compose up
```

That brings up Postgres + asobi_lua. Asobi reads `lua/config.lua`,
sees `walkers = "world.lua"`, and registers `walkers` as a world mode.

## Connect two clients

Use any client that speaks the asobi WebSocket protocol. The two
canonical paths:

- **Defold** — see [`defold-client/`](./defold-client/) for a
  ~120-line `.script` you can drop into a Defold project that already
  has the [asobi-defold](https://github.com/widgrensit/asobi-defold)
  SDK installed.
- **Browser / Node / your-game-engine** — the protocol is six message
  types. Register, connect WebSocket, send `session.connect`, send
  `world.find_or_create`, send `world.input` on each move, render the
  `world.tick` updates.

## The full protocol used here

Client → server:

| `type`                    | `payload`                                  |
|---------------------------|--------------------------------------------|
| `session.connect`         | `{ token: <session_token> }`               |
| `world.find_or_create`    | `{ mode: "walkers" }`                      |
| `world.input`             | `{ kind: "move", x: 600.0, y: 480.0 }`     |
| `world.leave`             | `{}`                                       |

Server → client:

| `type`           | `payload`                                                                  |
|------------------|----------------------------------------------------------------------------|
| `session.connected` | `{ player_id, username }`                                               |
| `world.joined`   | `{ world_id, mode, ... }` (full world info)                                |
| `world.tick`     | `{ tick: N, updates: [{ op, id, x, y, type, ... }] }`                      |
| `world.left`     | `{ success: true }`                                                        |
| `world.finished` | `{ ... }`                                                                  |
| `error`          | `{ reason: "..." }`                                                        |

`updates` is a list of entity deltas. `op` is `"a"` (added — full
state), `"u"` (updated — diff), or `"r"` (removed — id only). The first
`world.tick` you receive after joining is `tick = 0` and contains an
`"a"` for every entity already in the zone.

## What `world.lua` does

- Declares one world mode (`game_type = "world"`).
- One zone. The whole "room" is 1200×1200 units. `view_radius = 0`
  means a player only subscribes to their own zone — and since there's
  only one zone, everyone always sees everyone.
- 20 Hz tick (`tick_rate = 50` ms).
- `handle_input` accepts `{ kind = "move", x, y }` and writes the
  player's entity into the zone's entities map. The zone diffs that
  against the previous tick and broadcasts deltas as `world.tick`.

That's it. Roughly 30 lines of actual logic.

## Common pitfalls

1. **`type = "world"` is silently ignored.** The Lua loader reads
   `game_type`. If you write `type = "world"`, your script registers as
   a *match* mode, and `world.find_or_create` returns `mode_not_found`.

2. **`view_radius = 1` (the default) is too narrow for "see each other"
   demos.** With default `zone_size = 200`, two random spawns are very
   often outside each other's 3×3 interest window. The walkers world
   sidesteps this by using a single zone (`grid_size = 1`,
   `view_radius = 0`).

3. **Register your `world_tick` handler before sending
   `world.find_or_create`.** The first snapshot arrives as a `world.tick`
   immediately after `world.joined`. If your handler isn't registered
   yet, you miss it and the client looks empty until the next entity
   moves.

4. **`empty_grace_ms = 0` (the default) tears the world down the
   instant the last player leaves.** If you're testing two clients and
   one drops a frame, the other gets `world.finished`. The walkers world
   sets `empty_grace_ms = 10000`.

## Adapting Barrow

Barrow's `hub.lua` already follows this exact shape — `game_type =
"world"`, single zone, `handle_input` writes a `move` entity. The
difference is barrow's hub uses `grid_size = 1` implicitly (no
`generate_world` table beyond `"0,0"`) and `empty_grace_ms = 900000`.
Use this example as the reference and Barrow's hub.lua as a
working production-shaped derivative.
