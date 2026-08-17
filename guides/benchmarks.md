# Benchmarks

Single-node performance measurements. Client and server run on the same
machine, so a real deployment with the load generator elsewhere will see higher
server throughput than the tables below.

Measured on 2026-04-02 at commit `8069c02`. Re-run them yourself before you
size anything: the numbers below are one machine on one day, not a promise.

## Test environment

- 8 cores, client and server sharing them
- Erlang/OTP 28 and PostgreSQL 17, what the image was built on at that commit.
  asobi builds on OTP 29 today - see [Self-hosting](self-hosting.md)
- PostgreSQL in Docker with `max_connections=500`, `shared_buffers=256MB`
- Database pool: 200 connections (the `dev_sys.config.src` default the CT
  profile runs with)
- One Erlang node, no clustering

## WebSocket throughput

Heartbeat round-trip: the client sends `session.heartbeat`, the server replies
with a timestamp. This measures the whole WebSocket pipeline including JSON
encode and decode.

| Connections | Messages | Throughput | RTT p50 | RTT p99 | Memory/conn |
|-------------|----------|------------|---------|---------|-------------|
| 100 | 10,000 | 35,000 msg/sec | 1.4ms | 5.1ms | ~20KB |
| 3,500 | 7,000,000 | 83,000 msg/sec | 4.4ms | 6.5ms | ~15KB |
| 7,000 | 695,800 | 39,000 msg/sec | 5.8ms | 19.9ms | ~13KB |

Peak sustained: ~83,000 messages/sec at 3,500 concurrent connections.

At 7,000 connections per-message throughput drops because the benchmark client
is competing with the server for CPU on the same machine.

### Blast mode

Fire-and-forget: all messages sent before waiting for any reply. Measures raw
server processing capacity.

| Connections | Messages each | Total delivered | Throughput |
|-------------|---------------|-----------------|------------|
| 3,500 | 2,000 | 7,044,000 | 83,000 msg/sec |

All messages delivered, none lost.

## HTTP REST API

100 concurrent players, each running register, login, then API reads.

| Endpoint | p50 | p95 | p99 |
|----------|-----|-----|-----|
| `POST /api/v1/auth/register` | 1,463ms | 1,464ms | 1,464ms |
| `POST /api/v1/auth/login` | 724ms | 1,278ms | 1,308ms |
| `GET /api/v1/matches` | 8ms | 45ms | 64ms |
| `GET /api/v1/friends` | 7ms | 99ms | 133ms |
| `GET /api/v1/wallets` | 11ms | 272ms | 280ms |
| `GET /api/v1/players/:id` | 14ms | 191ms | 194ms |

Register and login are slow on purpose: pbkdf2 at 100,000 iterations is meant
to cost CPU. Everything else is sub-15ms at p50.

## Game type suitability

### Mobile and casual (turn-based, party, puzzle)

Good fit. Sub-10ms WebSocket RTT, thousands of concurrent connections per node.
Most mobile games send well under 100 messages/sec per player.

### Persistent worlds

Viable per world. 3,000-7,000 concurrent connections per node with acceptable
latency.

One world lives entirely on one node and does not migrate, so a node is not a
slice of a shared world - it is a set of separate worlds. Reaching 20,000 CCU
across 5-10 nodes therefore means running 5-10 sets of worlds, with players
sharded across them by your own routing. If your design needs one world larger
than a single node can hold, adding nodes does not help. See
[Clustering](clustering.md#the-scaling-unit-is-a-world-not-a-node).

### Competitive real-time (FPS, fighting, racing)

Not the target, and the reason is head-of-line blocking rather than the median.
The RTT table above measures 1.4ms to 5.8ms p50 depending on load, which is fine
for most genres. What these ones cannot absorb is the retransmission tail when a
packet is lost: TCP will not deliver frame N+1 until it has redelivered frame N,
so a lossy path inflates the tail well past the p99 figures above, and no
server-side tuning changes that. The numbers here are measured on a clean local
path and say nothing about behaviour at 1% loss.

Run the simulation over your own UDP netcode and use asobi for everything around
it: auth, matchmaking, economy, social, leaderboards.

## Bottlenecks and tuning

### Authentication under load

pbkdf2 saturates CPU during login storms. Mitigations:

- Rate-limit `/api/v1/auth/*` at the reverse proxy. asobi's own limiter is
  per node, so it is `N x` looser across a cluster - see
  [Clustering](clustering.md#what-is-per-node).
- More nodes behind a load balancer, to spread the pbkdf2 work.

### Database pool

The pool is `pool_size` under the `kura` application in `sys.config`. What
ships:

| Config | `pool_size` |
|--------|-------------|
| `config/prod_sys.config.src` (the image) | 20 |
| `config/dev_sys.config.src` (dev and CT) | 200 |

The production default of 20 is deliberately conservative, because every node
opens its own pool and PostgreSQL's `max_connections` is a fleet-wide budget:
`nodes x pool_size` has to fit inside it with room for your own tooling. Raise
it when you see queueing on database-bound endpoints, and raise
`max_connections` to match.

### Memory

WebSocket connections cost ~13-20KB each, so at the concurrency measured above
memory is not the constraint. CPU spent on message processing is.

## Running the benchmarks

```bash
# HTTP load test (default 100 players)
ASOBI_LOAD_N=500 rebar3 ct --suite=asobi_load_bench

# WebSocket benchmark. Phase 1 registers players (cached after the first run),
# phase 2 connects and blasts heartbeats.
ASOBI_BENCH_PLAYERS=5000 \
ASOBI_WS_N=5000 \
ASOBI_WS_MSGS=2000 \
ASOBI_WS_WAVE=200 \
rebar3 ct --suite=asobi_ws_bench
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `ASOBI_LOAD_N` | 100 | HTTP benchmark: concurrent players |
| `ASOBI_BENCH_PLAYERS` | 1000 | WS benchmark: players to register |
| `ASOBI_BENCH_BATCH` | 50 | WS benchmark: registration batch size |
| `ASOBI_WS_N` | 500 | WS benchmark: concurrent connections |
| `ASOBI_WS_MSGS` | 200 | WS benchmark: messages per connection |
| `ASOBI_WS_WAVE` | 200 | WS benchmark: connections per wave |

Both suites need a running PostgreSQL 17 - see
[Self-hosting](self-hosting.md).
