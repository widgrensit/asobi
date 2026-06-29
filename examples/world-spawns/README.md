# Spawns — entity templates and `game.zone.spawn`

A reference world script for server-authoritative entity spawning. It
shows the two halves of the spawn API: defining a **template registry**
with `spawn_templates`, and creating entities from it with
`game.zone.spawn`.

If you want NPCs, resource nodes, loot, or anything the server owns
(not a connected player), this is the pattern.

## How it works

### 1. Define templates

`spawn_templates(config)` returns a table keyed by template id. Each
entry has a `type`, a `base_state` table, and an optional `respawn`
rule:

```lua
function spawn_templates(config)
    return {
        goblin = {
            type       = "npc",
            base_state = { health = 100, ai = "patrol" },
            respawn    = { delay = 5000, jitter = 1000 },
        },
    }
end
```

- `type` defaults to `"npc"`.
- `base_state` is the entity's starting fields.
- `respawn` schedules a timed respawn after the entity is removed. Omit
  `max_respawns` for unlimited respawns; omit the whole `respawn` key
  for a one-shot entity that never comes back. The only strategy is
  `timer`, so you supply `delay`/`jitter`/`max_respawns` (milliseconds
  and counts), not a strategy name.

The registry lives in the zone's state, not a database or config file.

### 2. Spawn from a template

```lua
game.zone.spawn(template_id, x, y)             -- returns true
game.zone.spawn(template_id, x, y, overrides)  -- overrides merged over base_state
game.zone.despawn(entity_id)
```

`overrides` is a table merged over the template's `base_state`
(overrides win); `x`, `y`, and `type` are then set from the call and
template.

## Two gotchas

- **Zone context only.** `game.zone.spawn`/`despawn` work inside
  per-zone callbacks (`zone_tick`, `handle_input`) where the zone
  process is running. Calling them from `init`/`join` returns an error,
  because there is no zone yet.
- **The call is an async cast.** An unknown `template_id` fails
  server-side (`{error, unknown_template}` in the zone), not as a Lua
  return value, so a typo in a template id will not raise in your
  script. The entity simply will not appear.

## Run the server

```bash
docker compose up
```

Asobi reads `lua/config.lua`, sees `spawns = "world.lua"`, and
registers `spawns` as a world mode. On the first zone tick the script
seeds a goblin, an ore node, and a chest; connect any client that
speaks the asobi WebSocket protocol to watch them appear.
