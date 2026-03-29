# Clustering

Asobi runs on a single BEAM node by default. This guide covers how to run
multiple independent nodes behind a load balancer — the typical setup for
Kubernetes, ECS, or any cloud deployment.

## Architecture

Each Asobi node is standalone — no distributed Erlang required. Nodes share
a PostgreSQL database and use PostgreSQL LISTEN/NOTIFY (via Shigoto) for
cross-node messaging.

```
              Load Balancer (sticky sessions for WebSocket)
              ┌───────────┬───────────┬───────────┐
              ▼           ▼           ▼           ▼
           Node A      Node B      Node C      Node D
           ┌────┐      ┌────┐      ┌────┐      ┌────┐
           │ pg │      │ pg │      │ pg │      │ pg │
           └──┬─┘      └──┬─┘      └──┬─┘      └──┬─┘
              │           │           │           │
              └─────┬─────┴─────┬─────┘           │
                    ▼           ▼                  │
              ┌──────────┐  ┌──────────┐          │
              │ NOTIFY   │  │ NOTIFY   │◄─────────┘
              └────┬─────┘  └────┬─────┘
                   │             │
                   ▼             ▼
              ┌─────────────────────┐
              │     PostgreSQL      │
              └─────────────────────┘
```

- **`pg`** handles pub/sub within a single node (player sessions, chat channels, presence)
- **PostgreSQL NOTIFY** handles fan-out between nodes (via Shigoto's notifier)
- **Sticky sessions** ensure a player's WebSocket stays on the same node

## How Cross-Node Messaging Works

When a player sends a chat message:

1. Player A is connected to Node 1
2. Node 1 persists the message to PostgreSQL
3. Node 1 sends `pg_notify('asobi:chat:lobby', payload)`
4. PostgreSQL delivers the notification to all listening connections
5. Each node's Shigoto notifier receives it
6. Each node broadcasts locally via `pg` to connected players in that channel

The same pattern works for presence updates, notifications, and any event
that needs to reach players on other nodes.

## What Stays Node-Local

Not everything needs cross-node messaging:

| Component | Scope | Why |
|-----------|-------|-----|
| **Match Server** | Single node | All players in a match connect to the same node (sticky sessions). The match process and all its players are co-located. |
| **Player Session** | Single node | One process per connected player, tied to the WebSocket connection. |
| **Leaderboards (ETS)** | Single node | Hot reads from local ETS. Persisted to PostgreSQL for durability. Each node builds its own ETS cache on startup. |
| **Chat broadcast** | Cross-node | Players in the same channel may be on different nodes. |
| **Presence updates** | Cross-node | Friends on different nodes need to see status changes. |
| **Notifications** | Cross-node | Target player may be on any node. |

## Configuration

Enable the Shigoto notifier in your `sys.config`:

```erlang
{shigoto, [
    {pool, asobi_repo},
    {notifier, #{
        host => "localhost",
        port => 5432,
        database => "my_game",
        user => "postgres",
        password => "postgres"
    }}
]}
```

The notifier opens a dedicated PostgreSQL connection for LISTEN/NOTIFY
(separate from the query pool, since LISTEN requires a persistent connection).

## Sticky Sessions

WebSocket connections must be sticky — a player's connection stays on the
same node for the lifetime of the session. Configure your load balancer:

**Kubernetes (Ingress):**

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/session-cookie-name: "asobi_node"
```

**AWS ALB:**

Target group stickiness with application cookie.

**HAProxy:**

```
backend asobi
    balance roundrobin
    cookie ASOBI_NODE insert indirect nocache
    server node1 10.0.0.1:8080 check cookie node1
    server node2 10.0.0.2:8080 check cookie node2
```

## Matchmaking Across Nodes

The matchmaker needs a global view of all queued tickets. Two approaches:

### Shared PostgreSQL Queue (Recommended)

Matchmaker tickets are stored in PostgreSQL. One node runs the matchmaker
tick (elected via `pg_advisory_lock`). When a match is formed, the matched
players are notified via NOTIFY and each node's Shigoto notifier delivers
the event to the local player sessions.

```erlang
%% Only one node runs the matchmaker tick at a time
case pgo:query("SELECT pg_try_advisory_lock(12345)", [], #{pool => asobi_repo}) of
    #{rows => [#{pg_try_advisory_lock => true}]} ->
        run_matchmaker_tick();
    _ ->
        skip  %% another node holds the lock
end
```

### Dedicated Matchmaker Node

Run a dedicated node for matchmaking. Players submit tickets via REST
(any node can accept). The matchmaker node reads from PostgreSQL and
notifies matched players via NOTIFY.

## Scaling Guidelines

| Players | Nodes | Notes |
|---------|-------|-------|
| < 50K | 1 | Single node handles everything |
| 50K - 200K | 2-4 | Add nodes behind load balancer |
| 200K+ | 4+ | Consider dedicated matchmaker node, read replicas for leaderboards |

The main bottleneck is typically PostgreSQL, not the BEAM nodes. Use
connection pooling, read replicas, and table partitioning for high-volume
tables (transactions, chat messages) as you scale.

## Why Not Distributed Erlang?

Distributed Erlang works well on a local network but has challenges in
cloud/container environments:

- **Service discovery** — nodes need to find each other (requires epmd or custom discovery)
- **Network partitions** — split-brain scenarios need careful handling
- **Security** — Erlang distribution uses a shared cookie, not TLS by default
- **Container orchestration** — pod IPs change, nodes come and go frequently

PostgreSQL NOTIFY avoids all of these issues. The database is already your
shared state — using it for cross-node messaging keeps the architecture
simple and ops-friendly. The latency cost (a few ms per notification) is
negligible for chat, presence, and matchmaking events.

For latency-critical use cases (match state updates at 10+ ticks/sec),
co-locate players on the same node via sticky sessions so `pg` handles
the broadcast locally with no network hop.
