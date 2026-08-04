# Self-hosting asobi_lua

This guide covers running asobi_lua in production on infrastructure you
control. It is opinionated about how Lua game scripts get onto disk and
when they reload, because that is the question every operator hits in
the first week.

If you are evaluating asobi_lua locally, follow the
[quickstart](../README.md#try-it-in-60-seconds) first — this guide assumes you
have something working and now want it deployed.

## What ships in the container

`ghcr.io/widgrensit/asobi_lua` is a Debian-trixie-slim runtime image
built on top of Erlang/OTP 28.x. It expects:

- A Postgres 17+ database it can read and write (sessions, world
  snapshots, leaderboards, IAP receipts).
- A directory mounted at `/app/game/` containing your Lua scripts.
- TCP `:8084` reachable by your matchmaker / game clients.

That's it. No sidecars, no message bus, no Redis. The container is
stateless apart from `/app/game/`; restarting it loses no game state
beyond what was kept only in memory.

## Where Lua scripts live

`/app/game/` is the search path for `require()` and the source of every
Lua callback the runtime invokes (match handlers, world tick, bots).
The runtime calls `filelib:last_modified/1` on these files between game
ticks; if the mtime moves, it re-executes the script body against the
existing Luerl state. See `asobi_lua_reload` for the primitive.

You have four ways to put scripts there in production. Pick the one
that matches how you ship code.

### Pattern 1 — Bake into the image (immutable)

**When:** you treat game-script changes as deploys. Each release of
your game is a new container image, rolled out via your existing
container orchestrator (Kubernetes, Nomad, Fly, plain `docker compose
up -d`).

**How:** extend the asobi_lua image and `COPY` your scripts into
`/app/game/`:

```Dockerfile
FROM ghcr.io/widgrensit/asobi_lua:latest
COPY game/ /app/game/
```

Build, push to your registry, and deploy as you would any service.
mtime never changes inside a running container, so the per-tick
`stat()` cost is essentially free, but no live reload happens —
you ship code by shipping a container.

This is the safest model and the one we recommend by default. If you
are not sure which pattern you want, start here.

### Pattern 2 — Volume mount + atomic rename (live updates)

**When:** you want to update scripts without rolling the runtime —
e.g. during a live event, or because your design team iterates on
balance numbers faster than your release train moves.

**How:** mount a host directory (or a network volume your CI can
write to) at `/app/game/`:

```yaml
services:
  asobi_lua:
    image: ghcr.io/widgrensit/asobi_lua:latest
    volumes:
      - /srv/asobi/game:/app/game:ro
```

When you ship new code, **always write the file under a temp name and
`mv` it into place**. POSIX `rename(2)` is atomic; an editor's "save"
that truncates and re-writes the file is not, and the runtime can
observe a half-written file and crash the load.

```bash
# Wrong — runtime may stat() while the file is empty
cp build/match.lua /srv/asobi/game/match.lua

# Right — atomic swap, runtime never sees a partial file
cp build/match.lua /srv/asobi/game/match.lua.tmp
mv /srv/asobi/game/match.lua.tmp /srv/asobi/game/match.lua
```

The next match/world tick picks up the new mtime and reloads. In-flight
match state survives the reload because the script body re-declares
globals and functions in place; existing locals and table fields are
not touched unless the script explicitly re-runs `init()`.

For world zones, a reload that adds or changes `spawn_templates` also
takes effect immediately: an already-running zone re-fetches its spawn
template set on the tick right after the reload, so new templates
become spawnable without restarting the zone. If the reloaded
`spawn_templates` itself fails, the zone's existing templates are left
untouched rather than cleared.

If a new script has a syntax error, the runtime keeps running the old
code, logs a warning, and remembers the new mtime so it does not retry
the same broken file every tick. Fix the file, save again, and the
next tick reloads. The same per-script rate limiting applies to any
callback that starts failing on every tick (not just syntax errors) —
the failure is logged at most a few times per window, not once per
tick forever.

### Pattern 3 — Signal-driven reload (planned)

A future `ASOBI_LUA_RELOAD=signal` mode and admin RPC will let you skip
the per-tick `stat()` entirely and reload only when explicitly
triggered (e.g. by your CI/CD pipeline, after the file is in place).
This is the right model for very-high-zone-count deployments where the
mtime-poll overhead becomes measurable. Tracked in
[#TBD]; until it ships, use pattern 2.

### Pattern 4 — Custom script source (planned)

If your scripts live somewhere other than a filesystem — Postgres, S3,
git tags, a CMS — you will eventually want the planned
`asobi_lua_source` behaviour, which dispatches to either the
filesystem implementation or a custom loader. Until that lands, the
practical workaround is a small sidecar that pulls from your source
and writes to `/app/game/` using pattern 2. Tracked in [#TBD].

## A minimal production compose

```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: asobi
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
      POSTGRES_DB: asobi
    volumes:
      - pgdata:/var/lib/postgresql/data
    secrets: [db_password]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U asobi"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  asobi_lua:
    image: ghcr.io/widgrensit/asobi_lua:latest
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: asobi
      ASOBI_DB_USER: asobi
      ASOBI_DB_PASSWORD_FILE: /run/secrets/db_password
      ASOBI_NODE_HOST: 0.0.0.0
    volumes:
      - /srv/asobi/game:/app/game:ro
    secrets: [db_password]
    ports:
      - "8084:8084"
    restart: unless-stopped

secrets:
  db_password:
    file: ./db_password.txt

volumes:
  pgdata:
```

Put this behind a TLS-terminating reverse proxy (Caddy, nginx,
Traefik) — asobi_lua speaks plain HTTP/WebSocket and expects the proxy
to handle certificates.

## Tuning knobs

These are read at start time from your `sys.config`.

| Key | Default | What it does |
|---|---|---|
| `asobi_lua.max_heap_words` | `5_000_000` | Per-eval heap cap (in Erlang words) for every Lua callback the runtime invokes. If a single eval allocates past this, the eval process is killed by the VM and the runtime returns `{error, heap_exhausted}`. Persistent state held by the gen_server is not touched — only the runaway eval. Raise only if a single tick legitimately constructs a very large local structure; long-lived tables belong in the persistent Luerl state and cost nothing per eval. |
| `asobi_lua.max_reductions_per_ms` | `50_000` | Per-eval CPU cap, as BEAM reductions allowed per millisecond of that callback's own wall-clock budget — so `tick` (500 ms) gets 25,000,000 and a bot's `think` (50 ms) gets 2,500,000. The timeout bounds latency but not work: without this, a script that spins is killed at its deadline and does it again next tick, holding a scheduler indefinitely. Overrun returns `{error, reductions_exhausted}`; the callback's result is discarded and the previous Lua state kept, exactly as for a timeout, so the match or zone survives. Sampled every 10 ms, so overshoot is bounded by one interval. Set to `0` to disable. |
| `asobi_lua.reload_mode` (or env `ASOBI_LUA_RELOAD`) | `auto` | `auto` mtime-polls the script on every tick. `off` skips the poll entirely — appropriate for sealed-bundle prod where new code is a container restart, not a file change. Anything we don't recognise falls back to `auto` so a typo doesn't silently disable reload. |

```erlang
%% sys.config
[
  {asobi_lua, [
    {max_heap_words, 10_000_000},
    {max_reductions_per_ms, 50_000},
    {reload_mode, off}
  ]}
].
```

Or, in a Docker deploy, just set `ASOBI_LUA_RELOAD=off` in the container env.

## Validating Lua scripts in CI

Before deploying a new `match.lua` or `world.lua`, run it through the
loader in CI to catch syntax errors and sandbox violations without
booting a full runtime:

```bash
docker run --rm -v "$PWD/lua:/g" ghcr.io/widgrensit/asobi_lua \
  bin/asobi_lua eval 'asobi_lua_validate:cli(["/g/match.lua"]).'
```

Exits 0 on a clean script, 1 with the loader's error reason on stderr
otherwise. Pass multiple paths to validate them sequentially; the run
exits on the first failure.

## Operating notes

- **Database backups.** Postgres holds session tokens, world
  snapshots, and leaderboards. Use `pg_dump` or `pg_basebackup` on
  whatever cadence your data loss tolerance requires; nothing in
  asobi_lua is recoverable from the runtime alone.
- **Logs.** asobi_lua emits structured JSON via `nova_jsonlogger`.
  Ingest them as JSON lines from container stdout.
- **Crash dumps.** Erlang writes `erl_crash.dump` to the working
  directory on a VM crash. In a container that means it is lost on
  restart unless you mount a writable volume — we recommend leaving
  it ephemeral; if you need post-mortem capability, mount a
  short-retention volume at `/app`.
- **Restarts are cheap.** The container takes single-digit seconds to
  boot. In-flight matches are not preserved across restarts (they
  rely on in-memory state); design clients to reconnect.
- **The operator console.** Set `console` and `ops_secret` and the node
  serves a browser console at `/console` (see
  [Configuration](configuration.md#operator-console)). It shares the game
  port, because Nova starts one listener, so treat `/console` and
  `/api/v1/ops` as one thing when you decide what the internet can reach.
  Both are off until configured. Console sessions are in memory and end with
  the restart above.

## What this guide does not cover

- Multi-tenant hosting. The asobi managed cloud (and the private
  `asobi_engine` image behind it) handles tenant isolation; the public
  `asobi_lua` image is single-tenant.
- Horizontal scaling beyond one node. Asobi clusters via standard
  Erlang distribution; multi-node ops is its own topic and lives in
  the `asobi` library docs.
- Stripe / IAP / payments. Those are part of the managed cloud; the
  open-source runtime ships only the IAP-receipt-validation primitive.
