# Project glossary

Names you will meet across the docs, the repos and the Discord. Read this first
if they blur together.

## asobi

One project with two front doors.

**As a runnable node.** The image `ghcr.io/widgrensit/asobi` is a complete
game backend: the match and world servers, matchmaking, economy, social, chat,
leaderboards, the Lua runtime and the operator console, in one Erlang/OTP
release. The binary inside it is `bin/asobi`. Write `match.lua`, point the node
at it, `docker compose up`.

**As a Hex library.** [`asobi` on Hex](https://hex.pm/packages/asobi) is the
same code as a dependency. Add `{asobi, "~> 0.68"}` to `rebar.config` and
implement the `asobi_match` behaviour when you want a callback in Erlang rather
than Lua.

Lua is not a wrapper, an add-on or a separate runtime. It ships in the node.
The `asobi_lua` repo is retired and its code lives here, under `src/lua/`.

`asobi_lua` still appears in three places that are correct and must not be
renamed: module names (`asobi_lua_config`, `asobi_lua_api`, `asobi_lua_loader`
and friends), the `ASOBI_LUA_RELOAD` variable, and `{asobi_lua, [...]}` config
blocks, which are still read - see
[Which application key](configuration.md#which-application-key).

The one stale `asobi_lua` is the image name. `ghcr.io/widgrensit/asobi_lua`
still publishes, so an existing compose file keeps working; change it to
`ghcr.io/widgrensit/asobi` when convenient.

## Client SDKs

One per engine, all speaking the same WebSocket and REST protocol:
[asobi-love2d](https://github.com/widgrensit/asobi-love2d) (LÖVE),
[asobi-defold](https://github.com/widgrensit/asobi-defold),
[asobi-godot](https://github.com/widgrensit/asobi-godot),
[asobi-unity](https://github.com/widgrensit/asobi-unity),
[asobi-unreal](https://github.com/widgrensit/asobi-unreal),
[asobi-js](https://github.com/widgrensit/asobi-js),
[asobi-dart](https://github.com/widgrensit/asobi-dart) and
[flame_asobi](https://github.com/widgrensit/flame_asobi). Full table with docs
and demos in the [README](../README.md#client-sdks).

## The commercial layer

**asobi.dev Cloud** - managed hosting, running the same node described above.
Invite-only today, opening more widely toward the end of 2026.
[asobi.dev/cloud](https://asobi.dev/cloud).

The differences are operational, not functional. A cloud environment is created
and fed Lua through the `asobi` CLI rather than a mounted `/app/game`, its
console is reached from the dashboard rather than by holding an operator secret,
and the environment's `sys.config` is not yours to write. Everything about the
game itself - callbacks, protocol, error codes - is identical.

If it disappears, the open-source node above is enough to run your game
forever. See [exit.md](exit.md).

## Which one do I start with?

Run the image and write Lua. That is the default path and it needs no Erlang.

Depend on the Hex package if you are writing Erlang callbacks - a hot loop, a
custom matchmaking strategy, an extension.

You do not choose between them. The same node serves both, plus the console.

## Concepts, not projects

Vocabulary you will meet throughout the docs.

- **Match** - a short-lived gameplay session. 2 to N players, finite duration,
  result persisted. One `gen_statem` under `asobi_match_sup`, ticking on a
  state timeout.
- **World** - a long-lived environment. Players come and go, state persists
  across disconnects. Think MMO zone, town, dungeon. One world lives entirely
  on one node.
- **Zone** - a spatial partition inside a world, used to shard a large world
  into separately ticked chunks.
- **Session** - one process per connection, started when the socket sends
  `session.connect` and ended when the socket closes. It does not survive the
  connection: a reconnecting client presents the same token and gets a new
  session.
- **Console** - the operator UI this node serves at `/console`. Off until
  `console` is set. See [Operator console](console.md).
- **Ops plane** - the HTTP API at `/api/v1/ops/*` that the console reads. Its
  own credential, separate from the console flag, and read-only apart from
  extension actions.
- **Capability class** - what an ops route is allowed to touch: `read`,
  `player_data` or `config`. Every core ops route carries one.
- **Extension** - an OTP application that depends on asobi, added to your
  release, declaring a manifest. It can add RPC methods, workers, schemas and
  ops actions without forking asobi. See [Extensions](extensions.md).
- **RPC method** - how a client calls an extension. One WebSocket frame type:
  `rpc.call` in with a `method` and `params`, `rpc.ok` or `rpc.error` back,
  paired by `cid`.
- **Tenant** - a studio or account in the managed cloud. Not a concept when
  self-hosting.
- **Game** - the product you are shipping. One game may have many match modes
  and worlds.

When two words compete (*match* against *room*, *world* against *realm*),
asobi uses the first. The [Nakama](migrate-from-nakama.md),
[PlayFab](migrate-from-playfab.md) and [Hathora](migrate-from-hathora.md)
migration guides carry mapping tables from competitor vocabulary.
