# Threat model

asobi is a **single-tenant, single-node** game backend library by
design. The trust assumptions and architectural constraints below
follow from that.

## Trusted vs. untrusted code

| Component | Status | Notes |
|-----------|--------|-------|
| asobi library code | trusted | this repo |
| Loaded game module (`Mod:tick/1`, `Mod:join/2`, …) | **trusted** | callbacks run inline in the match gen_server. A crash in a callback restarts the match (transient + intensity 10) and can take the lobby down. |
| Loaded NIFs | trusted | NIFs run in-VM; a misbehaving NIF crashes the BEAM. |
| Loaded plugins | trusted | plugins observe / mutate every request and have full access to public ETS. |
| Lua scripts (via `asobi_lua` runtime) | sandboxed | see `asobi_lua` SECURITY.md. The Lua sandbox sits *on top* of the asobi-side trust boundary; it is the place where untrusted-script hardening belongs. |
| HTTP request bodies / WS payloads | untrusted | input validation lives in controllers / `asobi_ws_handler`. |
| Bearer tokens, OAuth claims, IAP receipts | untrusted | verified via `asobi_auth_plugin`, `asobi_oauth_controller`, `asobi_iap`. |

## Single-node BEAM distribution

`config/vm.args.src` boots with `-name` and `-setcookie`. EPMD binds to
`0.0.0.0:4369` and the dist port range is unbounded. The cookie is the
only protection.

For single-node deploys (the default), uncomment the localhost-bind
line in `vm.args.src`:

```
-kernel inet_dist_use_interface "{127,0,0,1}"
```

For clustered deploys via `asobi_cluster.erl` (k8s DNS discovery),
constrain the dist port range and enable TLS for distribution:

```
-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9105
-proto_dist inet_tls
-ssl_dist_optfile /etc/asobi/ssl_dist.config
```

## Public ETS tables

These named ETS tables are `public` and hold live game state:

- `asobi_world_state` (`asobi_world_sup`)
- `asobi_player_worlds` (`asobi_world_sup`)
- `asobi_match_state` (`asobi_match_sup`)
- `asobi_chat_registry` (`asobi_chat_channel`)
- `asobi_zone_mgr` (`asobi_zone_manager`)

Anything in the same BEAM (game callbacks, plugins) can read, mutate,
or delete entries. asobi treats this as acceptable because all in-VM
code is trusted (above). Any sandboxed runtime layered on top
(`asobi_lua`) MUST keep its sandbox out of these tables — Luerl is
not given access to ETS.

## UUIDv7 and timestamp leakage

`asobi_id:generate/0` produces UUIDv7 ids that embed a millisecond
timestamp in the high 48 bits. Match ids, world ids, ticket ids, and
`player.id` all use this generator. `player.id` is the long-lived
case: the timestamp inside it reveals account-creation time, which is
acceptable for a game backend but worth knowing if you build features
on top.

If you ever need an unguessable, non-correlatable id (auth tokens,
invite codes, etc.) generate them via `crypto:strong_rand_bytes/1`
rather than `asobi_id:generate/0`.

## What the supervisor will tolerate

`asobi_match_sup` runs each match gen_server with `transient` restart
and `intensity 10 / period 60`. After 10 crashes in 60s the entire
match supervisor falls over, intentionally taking the lobby with it so
an obviously broken game module cannot keep churning silently.

`asobi_world_lobby_server` serializes `find_or_create/1` to close a
documented TOCTOU race (two concurrent `find_or_create` for the same
mode no longer spawn duplicate worlds).
