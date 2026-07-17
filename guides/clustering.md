# Clustering

Run multiple asobi nodes as one cluster for horizontal scale of connections and
matches, plus automatic failover. Presence, chat, and cross-match messaging are
cluster-safe out of the box via the BEAM's process groups (`pg`).

> #### asobi is single-node by design for gameplay {: .info}
>
> A match lives on one node; the world server's zones for a given world live on
> one node. Clustering is for connection termination, cross-node messaging, and
> failover - not for live cross-node zone migration. Shard heavy load at the app
> level (for example, route players to a region's cluster).

## What's cluster-safe

- **`pg`-scoped process groups** - presence, chat channels, and world/match
  `whereis` lookups resolve across nodes.
- **Player sessions** - a session on node A can send to a match on node B; the
  send is proxied via a `pg` lookup of the match's owning process.
- **Storage** - Postgres is shared, so everything persistent is consistent
  across nodes.
- **Matchmaker** - replicated: one `gen_server` per node, with tickets held in
  Postgres, so any node can form a match.

## What isn't

- **Matches and worlds do not migrate between nodes.** If the owning node dies,
  its active matches are lost (their state persists in Postgres for post-mortem,
  but play does not resume elsewhere).
- **ETS caches** (zone entity snapshots, rate-limit counters) are per-node. Hot
  paths assume local access.
- **Luerl VMs** are per-process and per-node - there is no shared script state
  across nodes.

## Forming a cluster

asobi uses the BEAM's distribution protocol. Give each node a long name, share a
cookie, and let the `asobi_cluster` discovery loop connect them. The image reads
only `ASOBI_PORT`, `ASOBI_DB_*`, and `ASOBI_CORS_ORIGINS` from the environment;
set the node name and cookie with the standard VM flags:

```
-name asobi@10.0.0.1 -setcookie <shared-secret>
```

`asobi_cluster` is a `gen_server` that periodically resolves its peers and
connects to any it isn't already connected to. It never disconnects a node;
failover is left to the BEAM and the load balancer.

## Service discovery

Clustering is opt-in: with no `cluster` key set, `asobi_cluster` does not start
and the node runs standalone. Configure the discovery strategy under the `asobi`
app's `cluster` key to enable it. Two strategies are supported.

<!-- tabs -->
**DNS (Kubernetes headless service)**
```erlang
{asobi, [
    {cluster, #{
        strategy => dns,
        dns_name => <<"asobi-headless.default.svc.cluster.local">>,
        poll_interval => 10000
    }}
]}
```
**EPMD (static host list)**
```erlang
{asobi, [
    {cluster, #{
        strategy => epmd,
        hosts => ['host-a', 'host-b'],
        poll_interval => 10000
    }}
]}
```
<!-- /tabs -->

DNS resolves the peer addresses of the headless service; EPMD walks a fixed
`hosts` list. Either way asobi derives each peer's node name by reusing the
current node's base name (the part before `@`) and connects. `poll_interval` is
the rediscovery period in milliseconds (default 10000).

> #### Secure the distribution port {: .warning}
>
> EPMD binds `0.0.0.0:4369` and the distribution port range is unbounded by
> default; the cookie is the only protection. For anything beyond a trusted
> private network, constrain the port range and enable TLS for distribution in
> `vm.args` (`inet_dist_listen_min`/`max`, `-proto_dist inet_tls`). See the
> [Threat model](security-threat-model.md#single-node-beam-distribution).

## Routing players to nodes

Put a load balancer in front of the cluster with a sticky WebSocket cookie, or
hash on `player_id`. This keeps a player's session pinned to one node;
cross-node calls happen only for matches or worlds the player joins on a
different node.

## Deployment

Rolling restarts are safe: drain a node (stop accepting new matches, let
existing ones finish), upgrade it, and let it rejoin. Sessions on the drained
node reconnect to another node when the load balancer re-routes them.

## Observability

`asobi` emits telemetry events (`[asobi, match, *]`, `[asobi, world, *]`,
`[asobi, matchmaker, *]`). Wire them to Prometheus via
`telemetry_metrics_prometheus`, or ship them to any OpenTelemetry collector.

## Next steps

- [Configuration](configuration.md) - the full `cluster` config key.
- [Performance tuning](performance-tuning.md) - per-node tick and BEAM knobs.
- [Threat model](security-threat-model.md) - the distribution trust boundary.
