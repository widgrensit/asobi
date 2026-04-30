# Walkers — Defold client

The smallest possible Defold client for the `walkers` world. Two players
connect, walk with WASD, see each other.

## Project layout you need

- A Defold project with the [asobi-defold](https://github.com/widgrensit/asobi-defold)
  SDK added as a project dependency (`game.project` → Dependencies).
- One game object that owns this script (your local player).
- One *factory* component at `/avatars#avatar_factory` whose prototype is
  a separate `.go` with a sprite — this is what gets spawned for *other*
  players.
- Input bindings for `key_w`, `key_a`, `key_s`, `key_d` in
  `input/game.input_binding`.

## Running two clients

1. Start the backend:

   ```bash
   cd ../  # examples/world-walkers/
   docker compose up
   ```

2. In Defold, *Project → Build* twice (or Build + a HTML5 bundle in a
   browser tab) to launch two windows. Each gets a unique guest username
   (`walker_<timestamp>`), so they appear as separate players.

3. Both clients are now in the same world. Walk around with WASD — each
   client sees the other moving.

## What the script does

- Registers a guest account, then `realtime.connect()`s.
- On `connected`, calls `find_or_create_world("walkers")`. The first
  client spawns the world, the second joins it.
- Listens for `world.tick` and renders other players. Updates carry
  `op = "a"` on add, `"u"` on update, `"r"` on remove.
- Sends `world.input` at 20 Hz with the local player's predicted
  position.

That's the whole protocol. No matchmaker, no chat, no votes.
