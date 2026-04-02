# Benchmarks

Performance measurements for Asobi on a single node. All tests run client and
server on the same machine (8 cores, shared schedulers), so real-world
deployments with separate client machines will see higher server throughput.

## Test environment

- **CPU**: 8 cores
- **OTP**: 28
- **PostgreSQL**: 17 (Docker, max_connections=500, shared_buffers=256MB)
- **DB pool**: 200 connections
- **Single Erlang node**, no clustering

## WebSocket throughput

Heartbeat round-trip: client sends `session.heartbeat`, server replies with
timestamp. Measures the full WebSocket pipeline including JSON encode/decode.

| Connections | Messages | Throughput | RTT p50 | RTT p99 | Memory/conn |
|-------------|----------|------------|---------|---------|-------------|
| 100 | 10,000 | 35,000 msg/sec | 1.4ms | 5.1ms | ~20KB |
| 3,500 | 7,000,000 | 83,000 msg/sec | 4.4ms | 6.5ms | ~15KB |
| 7,000 | 695,800 | 39,000 msg/sec | 5.8ms | 19.9ms | ~13KB |

**Peak sustained**: ~83,000 messages/sec with 3,500 concurrent connections.

At 7,000 connections the per-message throughput drops because the benchmark
client competes with the server for CPU on the same machine.

### Blast mode

Fire-and-forget: all messages sent before waiting for replies. Measures raw
server processing capacity.

| Connections | Messages each | Total delivered | Throughput |
|-------------|---------------|-----------------|------------|
| 3,500 | 2,000 | 7,044,000 | 83,000 msg/sec |

All messages delivered with zero loss.

## HTTP REST API

100 concurrent players, each running the full lifecycle: register, login, then
API reads.

| Endpoint | p50 | p95 | p99 |
|----------|-----|-----|-----|
| POST /auth/register | 1,463ms | 1,464ms | 1,464ms |
| POST /auth/login | 724ms | 1,278ms | 1,308ms |
| GET /matches | 8ms | 45ms | 64ms |
| GET /friends | 7ms | 99ms | 133ms |
| GET /wallets | 11ms | 272ms | 280ms |
| GET /players/:id | 14ms | 191ms | 194ms |

Registration and login are slow by design: pbkdf2 with 100,000 iterations is
CPU-intensive but correct for password security. API reads are sub-15ms p50.

## Game type suitability

### Mobile / casual (turn-based, party, puzzle)

Excellent fit. Sub-10ms WebSocket RTT, 3,000+ CCU per node. Most mobile games
need <100 messages/sec per player, so a single node handles thousands of
concurrent players comfortably.

### MMO (persistent world)

Viable for zone servers. 3,000-7,000 concurrent connections per node with good
latency. A 20,000 CCU MMO would need 5-10 nodes. Erlang's `pg`-based clustering
is designed for this.

### Competitive real-time (FPS, fighting, racing)

Not the target. WebSocket (TCP) has a 5-25ms RTT floor. These genres need UDP
transport with <3ms latency. Consider Photon or a custom UDP relay alongside
Asobi for the game state, using Asobi for everything else (auth, matchmaking,
economy, social, leaderboards).

## Bottlenecks and tuning

### Authentication under load

pbkdf2 saturates CPU during login storms (1,000+ simultaneous registrations).
Mitigations:

- **Reverse proxy rate limiting** on `/auth/*` endpoints
- **Auth result caching** for repeated token validations
- **Multiple nodes** behind a load balancer to spread pbkdf2 work

### Database pool

The default pool size matters. With 10 connections, 100+ concurrent DB
operations queue up. Recommended:

| Deployment | pool_size | PG max_connections |
|------------|-----------|--------------------|
| Development | 50 | 100 |
| Production (single node) | 200 | 500 |
| Production (cluster) | 100 per node | 500-1000 |

### Memory

WebSocket connections use ~13-20KB each. A node with 8GB RAM can sustain
~100,000 connections from memory alone. The practical limit is CPU (message
processing) not memory.

## Running benchmarks

```bash
# HTTP load test (default 100 players)
ASOBI_LOAD_N=500 rebar3 ct --suite=asobi_load_bench

# WebSocket benchmark
# Phase 1: Register players (cached after first run)
# Phase 2: Connect and blast heartbeats
ASOBI_BENCH_PLAYERS=5000 \
ASOBI_WS_N=5000 \
ASOBI_WS_MSGS=2000 \
ASOBI_WS_WAVE=200 \
rebar3 ct --suite=asobi_ws_bench
```

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ASOBI_LOAD_N` | 100 | HTTP benchmark: concurrent players |
| `ASOBI_BENCH_PLAYERS` | 1000 | WS benchmark: players to register |
| `ASOBI_BENCH_BATCH` | 50 | WS benchmark: registration batch size |
| `ASOBI_WS_N` | 500 | WS benchmark: concurrent connections |
| `ASOBI_WS_MSGS` | 200 | WS benchmark: messages per connection |
| `ASOBI_WS_WAVE` | 200 | WS benchmark: connections per wave |
