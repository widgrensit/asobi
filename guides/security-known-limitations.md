# Known limitations

The asobi runtime closes a deliberate set of attack surfaces
(documented in [Threat model](security-threat-model.md) and
[Authentication & rate limiting](security-auth.md)). The list below
is the complement: properties the runtime does **not** enforce, and
where the responsibility lies.

## Game module crashes can take the lobby down

`asobi_match_server` calls game-module callbacks (`Mod:join/2`,
`Mod:tick/1`, `Mod:handle_input/3`, phase / vote callbacks) inline and
**without** wrapping them in `try/catch`. This is intentional:

- asobi is single-tenant by design — one VM owns the world processes
  and there is no other game module to fail over to.
- A crash is treated as a **bug** worth surfacing (transient restart,
  intensity 10 / period 60). After 10 crashes in 60s the entire
  `asobi_match_sup` falls over, intentionally taking the lobby with it
  so an obviously broken game cannot keep churning silently.
- For multi-tenant or sandboxed scenarios, layer `asobi_lua` or your
  own sandbox on top — that is the place to put callback hardening.

Because callbacks run inline with full BEAM access, a game module can read
public ETS, spawn arbitrary processes, reach clustered nodes, and crash the
lobby. Treat the game-module source as part of the trusted compute base — code
review and sign its releases the same way you would the asobi binary itself. For
untrusted scripting (community maps, modder content), use the
[Lua sandbox](https://github.com/widgrensit/asobi_lua/blob/main/guides/security-sandbox.md):
Luerl runs scripts in a hardened state with OS/IO/code-loading APIs stripped and
a wall-clock budget per callback.

If you need callback isolation in your custom game module, run the
hot-path logic in a worker process so a crash is contained.

## Erlang distribution is enabled by default

`config/vm.args.src` sets `-name asobi@${ASOBI_NODE_HOST}` and
`-setcookie ${ERLANG_COOKIE}`. EPMD binds to `0.0.0.0:4369` and dist
ports are unbounded; the cookie is the only protection. If the cookie
leaks (env var, container snapshot, k8s secret), anyone with network
reach to the dist port has full code-execution.

For single-node deploys, uncomment the localhost-bind line in
`vm.args.src`. For clusters, configure `inet_dist_listen_min/max` and
TLS for distribution. See [Threat model](security-threat-model.md).

## Public ETS tables are reachable from any in-VM code

`asobi_world_state`, `asobi_player_worlds`, `asobi_match_state`,
`asobi_chat_registry`, `asobi_zone_mgr` are all `public` named ETS
tables. Plugins, custom game modules, and NIFs in the same BEAM can
read or mutate them. asobi treats this as acceptable because all in-VM
code is trusted by design (see [Threat model](security-threat-model.md)).

Any Lua sandbox layered on top (`asobi_lua`) MUST keep its sandbox out
of these tables.

## UUIDv7 ids leak creation timestamp

`asobi_id:generate/0` produces UUIDv7. The high 48 bits are a
millisecond timestamp. `player.id` lives forever and reveals account
creation time when exposed. For unguessable, non-correlatable
identifiers (auth tokens, invite codes, session secrets) use
`crypto:strong_rand_bytes/1` — never `asobi_id:generate/0`.

## Compute / memory bounds are best-effort

The runtime caps individual *requests* (limits, body sizes, quantities;
see [Authentication & rate limiting](security-auth.md)). It does **not**
enforce a per-process reduction count, heap cap, or scheduler quota.
Enforcement of those happens at the OS / container layer:

- Production deployments should run with cgroup memory + CPU limits.
- Set `+P` (process limit) and `+Q` (port limit) in `vm.args` to
  bound BEAM-level resources.
- A long-running plugin or game module that allocates without bound
  will pressure the OS allocator before any in-VM mechanism notices.

## Container release tree is writable

The published `asobi_lua` image runs as the non-root `asobi` user but does not
declare `--read-only`. The README example mounts `/app/game` as `:ro`, but that
is the operator's responsibility, not the runtime's. For a hardened deployment,
run with `docker run --read-only --tmpfs /tmp` and chown only the game directory
to the runtime user — the rest of `/app` should stay root-owned and read-only.

## Next steps

- [Threat model](security-threat-model.md) - the trust assumptions this page's limits follow from.
- [Auth & rate limiting](security-auth.md) - the per-request bounds the runtime does enforce.
