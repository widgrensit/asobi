# Threat model

asobi is one Erlang/OTP node holding the game backend, the Lua runtime and the
operator console. One VM owns the match and world processes, the public ETS
tables and the console session store. Single-node is the default posture and
the assumptions below are written for it; [what a cluster
changes](#what-changes-under-a-cluster) is a short list further down.

## Trusted and untrusted

| Component | Status | Notes |
|---|---|---|
| asobi code | trusted | this repo |
| Game module in Erlang (`Mod:tick/1`, `Mod:join/2`, ...) | trusted | callbacks run inline in the match process. A crash restarts the match (`transient`, intensity 10 / period 60) |
| NIFs | trusted | a misbehaving NIF crashes the BEAM |
| Plugins | trusted | plugins see every request and can reach public ETS |
| Lua under `/app/game` | sandboxed, author-trusted | mechanics in [Sandbox model](security-sandbox.md), boundary in [Trust model](security-trust-model.md) |
| HTTP bodies and WebSocket payloads | untrusted | validated in the controllers and `asobi_ws_handler` |
| Bearer tokens, provider claims, IAP receipts | untrusted | verified by `asobi_auth_plugin`, `asobi_oauth_controller`, `asobi_iap` |
| Console bundle at `/console` | unauthenticated by design | the console route group in `asobi_router` is declared `security => false`: an index document, content-hashed assets and the login endpoint. No game data passes through it |
| Ops callers on `/api/v1/ops/*` | untrusted until an actor resolves | `asobi_ops_auth:verify/1` resolves an actor or returns 403 with one body for every cause |

The ops plane admits three credential sources, all resolving to the same actor
shape: the operator secret presented as a bearer token (`static_secret`), a
console session cookie plus its `x-csrf-token` header (`local_user`), and a
short-lived token minted by asobi_saas (`cloud`). A player bearer token is
never one of them - `asobi_ops_auth` does not consult the player auth cache at
all. The mechanism, the environment variables and the credential handling live
in [Operator console](console.md).

Both surfaces answer on the game port, and they are gated separately. `console`
gates `/console` alone. The ops routes are always mounted and the credential is
the only thing standing in front of them, so an `ops_secret` set for any reason
exposes `/api/v1/ops/*` whether or not the console is on. Unsetting the secret
is what closes the plane; a stock node has none. Core's ops routes are all
reads, so the blast radius of a leaked secret is disclosure plus whatever
actions an installed extension declares behind
`/api/v1/ops/ext/:extension/:action`.

## Erlang distribution

`config/vm.args.src` boots with `-name` and `-setcookie`. EPMD listens on
`0.0.0.0:4369`, the distribution port range is unbounded, and the cookie is the
only protection: anyone who can reach the port with the right cookie has code
execution in the VM.

The published image ships a fixed, publicly known `ERLANG_COOKIE=asobi`
(`Dockerfile`). It is set because relx renders an empty value otherwise and
`bin/asobi rpc` stops working, not because it is a secret. Any deployment that
exposes the distribution port must override it.

For a single node, uncomment the localhost bind in `vm.args.src`:

```
-kernel inet_dist_use_interface "{127,0,0,1}"
```

## What changes under a cluster

Clustering is opt-in through `asobi_cluster`. It moves three things in this
model:

- Distribution stops being optional, so the cookie and the dist port range
  become load-bearing. Constrain the range and turn on TLS for distribution:
  `-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9105`,
  `-proto_dist inet_tls`, `-ssl_dist_optfile /etc/asobi/ssl_dist.config`.
- Several bounds in this model are per node, so a cluster of N multiplies them
  by N. Rate-limit buckets are the ones with security weight.
- Console sessions and their CSRF secret are per node, so the console needs a
  sticky route.

[Clustering](clustering.md) holds the complete list of what is and is not
shared between nodes.

## Public ETS tables

These tables are `public` and hold live game state:

| Table | Created by | Named |
|---|---|---|
| `asobi_world_state` | `asobi_world_sup` | yes |
| `asobi_player_worlds` | `asobi_world_sup` | yes |
| `asobi_match_state` | `asobi_match_sup` | yes |
| `asobi_chat_registry` | `asobi_chat_sup` | yes |
| `asobi_zone_mgr` | `asobi_zone_manager` | only when a `name` option is passed, and then under that atom. Otherwise the table is unnamed and reached by reference |
| `asobi_terrain_cache` | `asobi_terrain_store` | no |

Anything in the same BEAM - game callbacks in Erlang, plugins, NIFs - can read,
mutate or delete entries. asobi accepts that because all in-VM code is trusted
above. Lua never reaches them: Luerl scripts are not given ETS access, and the
`game.*` bridge is the only path from a script into host state.

## UUIDv7 ids carry a timestamp

`asobi_id:generate/0` produces UUIDv7 (`jhn_uuid`), which embeds a millisecond
timestamp in the high 48 bits. Match ids, world ids, ticket ids and `player.id`
all use it. `player.id` is the long-lived case: the timestamp inside it reveals
account-creation time. That is acceptable for a game backend, but worth knowing
before you build a feature on top of it.

For an unguessable, non-correlatable id - auth tokens, invite codes - use
`crypto:strong_rand_bytes/1`, not `asobi_id:generate/0`.

## What the supervisors tolerate

`asobi_match_sup` runs each match with `restart => transient` under
`intensity 10 / period 60`. Past 10 crashes in 60 seconds the match supervisor
itself exits and `asobi_sup` restarts it, taking every live match on the node
with it. That is deliberate: an obviously broken game module should stop, not
churn quietly.

`asobi_world_lobby_server` serialises `find_or_create/1` through a single
process so two concurrent calls for the same mode cannot both create a world.

## Related

- [Auth and rate limiting](security-auth.md) - how clients authenticate and what bounds a single hostile request.
- [Known limitations](security-known-limitations.md) - the sharp edges this design accepts.
- [Sandbox model](security-sandbox.md) - what the Lua sandbox removes, replaces and bounds.
- [Trust model](security-trust-model.md) - what the Lua sandbox is and is not a boundary against.
- [Known limitations (Lua)](security-lua-known-limitations.md) - the sandbox's own sharp edges.
- [Operator console](console.md) - turning the console and ops API on, and the credentials they check.
