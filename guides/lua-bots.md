# Bots

Bots are server-side processes that join matches as ordinary players. There
are no fake clients and no network hop; a bot's decisions go through the same
`handle_input` path a human's do.

## When to use bots

- Fill empty slots so matches start instead of waiting for a full lobby.
- A tutorial or single-player sandbox with scripted opponents.
- Load-testing a tick loop without spawning real WebSocket sessions.
- Replay and record-and-replay testing.

There are two ways a bot gets into a match. **Queue fill** is automatic and
answers "not enough humans are waiting". **`game.bots.add`** is your script
placing one deliberately, at any point in the match. They are independent:
leave `bots.enabled` off and nothing arrives that your script did not ask for.

## How queue fill works

1. A player queues for matchmaking.
2. Every 8 seconds the spawner looks at each mode with someone queued. If
   fewer are queued than the mode's bot target, it queues bots for the
   difference.
3. The matchmaker forms a match from the queue as usual, bots included.
4. Within about 2 seconds of the match appearing, the spawner starts an AI
   process for each `bot_`-prefixed player in it.
5. That process calls `think(bot_id, state)` on its own fixed 100 ms loop and
   sends the result as input.

No waiting period gates any of this. The spawner's only test is "are fewer
queued for this mode than its target", so with a target of 4 and one human
waiting, three bots are queued at the next 8-second check. A mode with nobody
queued is skipped, so bots never start a match on their own. The one wait
setting that exists, `max_wait_seconds` (60 by default, under `{asobi,
[{matchmaker, #{max_wait_seconds => N}}]}`), expires an unmatched ticket
instead - it does not trigger bot fill.

Bot fill is per node, because the matchmaker queue is per node. Each node
fills its own queue from its own view. See [Clustering](clustering.md).

## Placing a bot from a match script

```lua
game.bots.add("Spark")        -- bot_Spark joins this match
game.bots.remove("bot_Spark") -- and leaves
```

This is the route to take when the *game* decides, not the queue: a co-op
mission that needs an escort, a boss that fights alongside the players, a
practice mode with no queue at all, a slot backfilled the moment a human
drops. It works in `waiting` and in `running`, so a bot can arrive mid-match.

`name` is bare and gets the `bot_` prefix here, so the roster shows
`bot_Spark`; `remove` takes either form. Names are 1-32 characters of
`[A-Za-z0-9_-]`. The bot runs the mode's `bots.script` if the mode has one and
the built-in AI otherwise, so a mode can leave `bots.enabled` off - that flag
governs queue fill only - and still configure a script.

Both calls are asynchronous and neither fails at the call site. A match that is
full, already holds that bot, or is at the 64-bot ceiling is a no-op with a line
in the node log. The bot appears in your `players` table through the same `join`
callback a human goes through, so a script that rejects unknown players will
reject bots too.

## Configuration

Add a `bots` table to the match script's globals, and a `names` list to the
bot script:

```lua
-- match.lua
match_size = 4
max_players = 8
strategy = "fill"
bots = { script = "bots/chaser.lua", min_players = 4 }
```

```lua
-- bots/chaser.lua
names = {"Spark", "Blitz", "Volt", "Neon", "Pulse"}

function think(bot_id, state)
    -- AI logic here
end
```

`bots.script` is resolved relative to the match script's own directory, and a
path that escapes it is rejected with a warning.

`bots.min_players` is the fill target. From Lua it defaults to `match_size`.
It is clamped at 64, and a larger value is clamped with a warning in the log.
The target is also capped at the mode's `max_players`, so a
`match_size = 2` / `max_players = 2` mode never overshoots into a second,
bot-only match.

`bots.enabled` defaults to `true`; declaring the table at all is the opt-in.
Set it to `false` to keep the table (to declare `min_players`, say) with fill
turned off.

Bot ids are `bot_` plus a name from the list, taken in order: `bot_Spark`,
`bot_Blitz`. Past the end of the list they fall back to their position in the
fill, so the sixth bot of a batch with five names is `bot_6` and the seventh
is `bot_7`. Give the list at least as many names as the largest fill you
expect.

With no `names` global, or none the platform can read, the defaults are
`Spark`, `Blitz`, `Volt`, `Neon` and `Pulse`.

A bot joins through the normal match join, so the script's
`join(player_id, state)` runs for it exactly as for a human.

### In Erlang

```erlang
{game_modes, #{
    ~"arena" => #{
        module => {lua, "game/match.lua"},
        match_size => 4,
        bots => #{
            enabled => true,
            min_players => 4,
            script => <<"game/bots/chaser.lua">>
        }
    }
}}
```

Two differences from the Lua path. `min_players` here defaults to **4**, not
to `match_size`, when the key is absent. And `names` can be set directly in
the `bots` map, in which case the bot script's `names` global is never read:

```erlang
bots => #{enabled => true, names => [~"Ada", ~"Grace"], script => <<"game/bots/chaser.lua">>}
```

The 64 clamp applies here too, at spawn time.

## Writing a bot AI script

A bot script defines one function: `think(bot_id, state)`. It receives the
current game state and returns an input table, in the same format a real
player would send. That is the whole callback surface: no `on_join`,
`on_leave` or `on_message` hooks, just the next input from the current state,
plus the optional `names` list.

Because a bot decides only from `state`, difficulty is a property of the
script rather than a config knob: throttle a reaction delay or degrade target
selection by keying per-bot state off `bot_id` in a module-level table.

### What a bot script gets

A bot script loads into the same hardened Luerl state a match script starts
from, but **without** the `game.*` API. That namespace is installed only for
match, world and zone scripts; inside `think`, `game` is `nil`. There is no
`game.log`, `game.economy`, `game.storage` or `game.leaderboard` for a bot.

An installed [extension](extensions.md) cannot add one either. `bot` is not a
VM kind an extension's `lua/0` may name, and declaring it fails the build
rather than installing a binding that quietly does nothing.

What is available:

- The Lua standard library, minus what the sandbox clears. `io`, `package`,
  `load`, `loadfile`, `loadstring`, `dofile`, `print`, `eprint` and
  `os.execute` / `os.exit` / `os.getenv` / `os.remove` / `os.rename` /
  `os.tmpname` are all `nil`. See [Sandbox model](security-sandbox.md).
- `require("module")`, resolved relative to the bot script's own directory, so
  `require("targeting")` reads `<bot script dir>/targeting.lua`. Dotted paths
  work; parent traversal and absolute paths are rejected.
- `math.random` and `math.sqrt`, backed by the BEAM's `rand` and `math`.
- The two arguments of `think(bot_id, state)`, plus whatever the script itself
  defines at the top level. `state` is the match state as broadcast to
  players, so a bot sees what a client sees and nothing more.

Anything else has to come through the match script: put the value in the state
the match broadcasts and read it from `state`.

Bots work under both state strategies, and `think` sees the same `state`
either way. A mode that declares `state_strategy = "shared"` still calls
`get_state` once per tick and encodes once for the connected sessions; a bot
is handed the payload behind that frame as a term, so it decodes nothing and
costs the shared path no extra encode. The difference that remains is what
`state` contains, not whether it arrives: under `"shared"` every bot sees
exactly what every player sees, so a bot cannot be given information a client
is not also given. Use per-player `get_state` when a bot needs a filtered view
of its own - see [Performance tuning](performance-tuning.md) for what each
path costs.

Each `think` call runs under a 50 ms wall-clock budget, a heap cap and a
reduction budget. A timeout, a heap or CPU overrun, an error, or a missing
`think` falls back to the built-in default AI below.

That fallback is silent to the client, so it is also logged: a persistently
broken `think` produces `bot_think_error_falling_back_to_default_ai` with the
bot id and the reason, once a minute per bot. Grep for it when a bot has
stopped behaving like your script and started behaving like the default AI.

```lua
-- game/bots/chaser.lua

function think(bot_id, state)
    local players = state.players or {}
    local me = players[bot_id]
    if not me then return {} end

    local target = find_nearest(bot_id, me, players)
    if not target then
        return wander()
    end

    local dist = distance(me, target)
    return {
        right = target.x > me.x,
        left = target.x < me.x,
        down = target.y > me.y,
        up = target.y < me.y,
        shoot = dist < 200,
        aim_x = target.x,
        aim_y = target.y
    }
end

function find_nearest(bot_id, me, players)
    local nearest, min_dist = nil, 99999
    for id, p in pairs(players) do
        if id ~= bot_id and p.hp and p.hp > 0 then
            local d = distance(me, p)
            if d < min_dist then
                nearest, min_dist = p, d
            end
        end
    end
    return nearest
end

function distance(a, b)
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

function wander()
    return {
        right = math.random(2) == 1,
        left = math.random(2) == 1,
        down = math.random(2) == 1,
        up = math.random(2) == 1,
        shoot = false
    }
end
```

## Multiple bot types

Every bot in a game mode runs the same script. To vary behaviour, branch
inside `think`:

```lua
local STRATEGIES = { "aggressive", "defensive", "random" }

function think(bot_id, state)
    -- bot_id length picks a stable strategy per bot
    local strategy = STRATEGIES[(#bot_id % #STRATEGIES) + 1]

    if strategy == "aggressive" then
        return chase(bot_id, state)
    elseif strategy == "defensive" then
        return defend(bot_id, state)
    else
        return wander()
    end
end
```

## Default AI

With no bot script configured, or when `think` fails, bots run a built-in AI
that finds the nearest living enemy, moves towards it, shoots within 200
units with slight aim jitter, and wanders when nothing is alive to chase.

It reads `players`, and each player's `x`, `y` and `hp`, from the broadcast
state. A bot with no entry of its own under `players` sends an empty input;
one whose peers carry no `hp` finds nothing alive to chase and wanders
instead.

## Boon picking and voting

Bots handle two phases without any script code:

- Boon pick: the bot picks the first offered option immediately.
- Voting: the bot casts a random vote after a delay of 1 to 4 seconds.

The boon pick is driven by the broadcast state: the phase comes from
`state.phase` (`"boon_pick"`), and the offers from `state.boon_offers`. The
vote is not - it is driven by the `vote_start` match event, which carries the
vote id and the options the bot picks from. A `state.phase` of `"voting"` or
`"vote_pending"` only stops the bot sending input while the vote runs.

## Bot ids

Bot player ids are `bot_` followed by the display name, so game logic can test
for them:

```lua
function is_bot(player_id)
    return string.sub(player_id, 1, 4) == "bot_"
end
```

Clients receive bots in the normal game state. Whether to mark them in the UI
is up to the client.

## Bots and presence

A bot is tracked with `asobi_presence:track_bot/2`, which makes it a delivery
target for everything the match server broadcasts (state, match events, votes)
exactly like a connected player session. Shared state reaches it too:
`asobi_presence:send_match_state/3` gives a session the pre-encoded frame and
a bot the same payload as a term, which is the one delivery that differs by
recipient kind - see [What a bot script gets](#what-a-bot-script-gets).

It deliberately does not make the bot *online*:

- `asobi_presence:online_count/0` counts connected humans only. Bots are never
  added to it, so the concurrency figure stays a real player count. Bot fill
  does not read it: it reads the matchmaker queue, where the bots it queued
  count like anyone else, which is what stops the fill feeding itself.
- Bots emit no `player_online` / `player_offline` broadcasts, so friend lists
  and presence subscribers never see a bot appear or disappear.

`asobi_presence:get_status/1` on a bot id does answer `online`, because that
function reports whether the id is addressable. Filter on the `bot_` prefix
if you need the human answer.

## Next steps

- [Testing with multiple players](testing-multiple-players.md) - bot fill is why
  two humans testing together each get their own match.
- [The game.\* API](lua-api.md) - what match and world scripts can call, and
  bots cannot (see [What a bot script gets](#what-a-bot-script-gets)).
- [Lua scripting](lua-scripting.md) - the match callbacks a bot's input feeds.
- [Trust model](security-trust-model.md) - a bot's `think` runs bounded, like
  any callback.
