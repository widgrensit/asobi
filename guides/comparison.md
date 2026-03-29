# Comparison

How Asobi compares to other open-source game backend platforms.

## Feature Matrix

| Feature | Asobi | Nakama | Colyseus | PlayFab |
|---------|:-----:|:------:|:--------:|:-------:|
| **Runtime** | BEAM (Erlang/OTP) | Go | Node.js | Cloud |
| **Authentication** | Built-in | Built-in | Plugin | Built-in |
| **Player Management** | Built-in | Built-in | Manual | Built-in |
| **Real-Time Multiplayer** | WebSocket | WebSocket | WebSocket | WebSocket |
| **Server-Authoritative Game Loop** | Built-in (tick-based) | Lua scripting | Room-based | CloudScript |
| **Matchmaking** | Query-based | Query-based | Manual | Built-in |
| **Leaderboards** | ETS + PostgreSQL | Built-in | Manual | Built-in |
| **Virtual Economy** | Wallets, store, inventory | IAP validation | Manual | Built-in |
| **Friends / Groups** | Built-in | Built-in | Manual | Built-in |
| **Chat** | Built-in (channels) | Built-in | Manual | Manual |
| **Tournaments** | Built-in | Built-in | Manual | Manual |
| **Cloud Saves** | Built-in | Storage API | Manual | Built-in |
| **Notifications** | Built-in | Built-in | Manual | Built-in |
| **Background Jobs** | Shigoto (built-in) | Manual | Manual | Scheduled tasks |
| **Admin Dashboard** | Arizona LiveView | Built-in | Monitor | Portal |
| **Database** | PostgreSQL (Kura ORM) | CockroachDB | MongoDB / custom | Managed |
| **Self-Hosted** | Yes | Yes | Yes | No |

## Runtime Characteristics

| Concern | Asobi (BEAM) | Nakama (Go) | Colyseus (Node.js) |
|---------|-------------|-------------|-------------------|
| **Garbage Collection** | Per-process -- isolated per match | Stop-the-world -- affects all matches | Stop-the-world -- affects all rooms |
| **Fault Tolerance** | OTP supervision -- crashed matches restart | Panic recovery -- manual | Process crash -- manual |
| **Hot Code Upgrade** | Native -- zero-downtime deploys | Restart required | Restart required |
| **Pub/Sub** | `pg` module -- cluster-native | Built-in + optional Redis | Built-in (single node) |
| **In-Memory State** | ETS -- zero serialization | In-process maps | In-process objects |
| **Clustering** | Distributed Erlang -- built in | etcd / Consul | Redis (presence only) |
| **Scheduling** | Preemptive -- fair across all processes | Cooperative goroutines | Single-threaded event loop |
| **Connection Density** | ~500K+ per node | ~100K per node | ~10K per node |

## When to Choose Asobi

- You want a **single deployable** with auth, matchmaking, economy, social, and real-time multiplayer
- You need **fault-tolerant game sessions** that survive crashes without losing state
- You want **zero-downtime deploys** for game logic updates
- You're building for **high concurrency** (many simultaneous matches/rooms)
- You prefer **self-hosted** over managed cloud services
- You want a **PostgreSQL-backed** system with a proper ORM

## When to Choose Something Else

- You need a **managed cloud service** with no infrastructure to maintain (PlayFab, GameSparks)
- Your team has **no Erlang/OTP experience** and prefers Go or JavaScript
- You need **Unity/Unreal SDK** out of the box (Nakama has official SDKs)
- You're building a **single-player** game that only needs analytics and IAP
