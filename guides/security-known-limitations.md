# Known limitations

asobi closes a deliberate set of attack surfaces, documented in [Threat
model](security-threat-model.md) and [Auth and rate
limiting](security-auth.md). This page is the complement: what the runtime does
not enforce, and where the responsibility sits instead.

## A crashing game module takes matches with it

`asobi_match_server` calls game-module callbacks in Erlang (`Mod:join/2`,
`Mod:tick/1`, `Mod:handle_input/3`, phase and vote callbacks) inline, with no
`try/catch`. That is intentional:

- One VM owns the world processes, and there is no other game module to fail
  over to.
- A crash is a bug worth surfacing. The match restarts (`transient`), and past
  10 crashes in 60 seconds `asobi_match_sup` exits and `asobi_sup` restarts it,
  taking every live match on the node with it, rather than letting a broken
  game churn quietly.

Because these callbacks run inline with full BEAM access, a game module can
read public ETS, spawn processes, reach clustered nodes and crash the node.
Treat its source as part of the trusted compute base: review it and sign its
releases the way you would the asobi binary. If you need isolation inside your
own module, run the hot-path logic in a worker process so a crash is contained.

For untrusted scripting - community maps, modder content - write the game in
Lua instead. Luerl runs scripts in a hardened state with OS, I/O and
code-loading APIs stripped and a budget per callback: see [Sandbox
model](security-sandbox.md).

## Erlang distribution is on by default

`config/vm.args.src` sets `-name asobi@${ASOBI_NODE_HOST}` and
`-setcookie ${ERLANG_COOKIE}`. EPMD listens on `0.0.0.0:4369`, the distribution
port range is unbounded, and the cookie is the only protection. The published
image ships a fixed, publicly known `ERLANG_COOKIE=asobi`, so any deployment
that exposes the distribution port must override it.

For a single node, uncomment the localhost bind in `vm.args.src`. For a
cluster, constrain `inet_dist_listen_min/max` and turn on TLS for
distribution. See [Threat model](security-threat-model.md#erlang-distribution).

## Public ETS is reachable from any in-VM code

`asobi_world_state`, `asobi_player_worlds`, `asobi_match_state`,
`asobi_chat_registry`, `asobi_zone_mgr` and `asobi_terrain_cache` are all
`public`. Plugins, game modules in Erlang and NIFs in the same BEAM can read or
mutate them. asobi accepts that because all in-VM code is trusted by design.
Lua has no ETS access; the `game.*` bridge is the only path from a script into
host state.

## UUIDv7 ids leak a creation timestamp

`asobi_id:generate/0` produces UUIDv7, whose high 48 bits are a millisecond
timestamp. `player.id` lives forever and so reveals account-creation time
wherever it is exposed. For unguessable, non-correlatable identifiers - auth
tokens, invite codes - use `crypto:strong_rand_bytes/1`.

## In-VM compute and memory bounds are the OS's job

Per-request bounds exist (limits, body sizes, quantities: see [Auth and rate
limiting](security-auth.md)), and Lua callbacks are separately bounded by a
wall-clock timeout, a heap cap and a reduction budget (see [Sandbox
model](security-sandbox.md#per-callback-budgets)). What is not bounded is
trusted in-VM Erlang code: a game module, a plugin or a NIF gets no reduction
count, no heap cap and no scheduler quota. Enforcement for those is at the OS
or container layer:

- Run with cgroup memory and CPU limits.
- `vm.args` already ships `+P 1048576` and `+Q 65536`. Those are ceilings sized
  for a large node; lower them to something your cgroup can actually back, so
  the BEAM refuses a new process instead of the OOM killer taking the node.
- A plugin or game module that allocates without bound will pressure the OS
  allocator before anything in the VM notices.

## The release tree in the container is writable

The published `ghcr.io/widgrensit/asobi` image runs as the non-root `asobi`
user, and its Dockerfile chowns all of `/app` to that user. So the release tree
is writable by the process that runs it, and the image does not declare
`--read-only`.

Making it read-only takes one extra step, because the boot script renders
`sys.config` and `vm.args` from their `.src` templates at start and writes the
result next to them. Add these flags to however you already run the image, on
top of the database variables from [Self-hosting](self-hosting.md):

```
docker run --read-only \
  --tmpfs /tmp \
  --tmpfs /run/asobi \
  -e RELX_OUT_FILE_PATH=/run/asobi \
  -v /srv/mygame:/app/game:ro \
  -p 8084:8084 \
  ghcr.io/widgrensit/asobi
```

`RELX_OUT_FILE_PATH` must name a directory that already exists, or the script
falls back to writing into `/app/releases/<vsn>` and the boot fails on a
read-only filesystem. `/tmp` holds the pipe directory the release uses for
`bin/asobi remote_console`. Mount the game directory read-only unless your game
writes to it.

## Related

- [Threat model](security-threat-model.md) - the trust assumptions these limits follow from.
- [Auth and rate limiting](security-auth.md) - the per-request bounds that do exist.
- [Sandbox model](security-sandbox.md) - what the Lua sandbox removes, replaces and bounds.
- [Trust model](security-trust-model.md) - what that sandbox is and is not a boundary against.
- [Known limitations (Lua)](security-lua-known-limitations.md) - the sandbox's own sharp edges.
