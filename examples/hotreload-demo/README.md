# Hot-reload demo

A 60-second demo that shows asobi's killer feature: **edit Lua → live match updates**.
No restart. No reconnect. No kicked players.

Used to produce the landing-page video.

## Run it

```bash
docker compose up -d
```

Open `client/index.html` in a browser (any modern one — drag the file in,
or run `python3 -m http.server 3000 --directory client` and open
`http://localhost:3000`).

You'll see a cube you can drive with `W A S D`. The status line reads
`matched — you're in. edit lua/match.lua and save.` once the match
starts.

## Edit while connected

Open `lua/match.lua` in your editor. The top of the file is a config block:

```lua
cube_color = "#ff4757"     -- try "#4facfe" or "#2ed573"
cube_size  = 60            -- try 20, 100, 140
move_speed = 4             -- try 1, 8, 16
bg_color   = "#1e272e"     -- try "#ffeaa7" or "#6c5ce7"
message    = "Hello from Lua!"   -- change this text
```

Change any value. Save. **The browser cube updates on the next tick** —
no reconnect, no reload, no message loss. Try:

1. Change `cube_color` from `"#ff4757"` to `"#4facfe"` — cube goes from red to blue.
2. Change `cube_size` from `60` to `140` — cube triples in size.
3. Change `bg_color` — the backdrop shifts.
4. Change `message` — the banner text updates.
5. Change `move_speed` — your next `W A S D` input moves faster.

## How it works

asobi_lua runs your `match.lua` inside [Luerl](https://github.com/rvirding/luerl)
— a pure-Erlang Lua 5.3 interpreter. When the mounted `.lua` file changes,
the Luerl VM re-loads the module. In-flight match state is kept in the
BEAM process heap, so reloading the script doesn't reset the game.

`get_state/2` in this demo references the Lua globals directly, so every
tick picks up the current value:

```lua
function get_state(_player_id, state)
    return {
        players    = state.players,
        cube_color = cube_color,   -- reads the current global
        ...
    }
end
```

If you instead bake the globals into `state` inside `init/1`, the
globals become snapshot-on-match-start — hot-reload still works for
*new* matches but not for the live one. That's sometimes what you want
(e.g. balance changes that shouldn't alter a match mid-play). Up to you.

## Record the video

`RECORDING.md` has the shot list for the landing-page 15-second video.

## Troubleshooting

- **`matchmaker add failed: 429`** — you're rate-limited. Wait a minute
  and retry.
- **`socket error`** — check `docker compose logs asobi` for Lua
  syntax errors; a bad `.lua` file breaks match start.
- **The cube doesn't move** — make sure the browser window has focus
  (keyboard events only fire on the focused window).
- **Nothing happens on save** — confirm the file was mounted read-only
  into the container with `docker compose exec asobi ls /app/game`. You
  should see `match.lua`.
