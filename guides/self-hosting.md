# Self-hosting asobi

asobi is one Erlang/OTP node containing the game backend, the Lua runtime and
the operator console. Run the image and write Lua, or depend on the Hex package
and write Erlang: same node, two surfaces. This guide covers running it in
production on infrastructure you control.

It is opinionated about how Lua scripts get onto disk and when they reload,
because that is the question every operator hits in the first week.

**On asobi Cloud none of this applies.** A managed environment has no
`/app/game` to mount, no `sys.config` you can write and no image you choose:
scripts arrive as a bundle the `asobi` CLI uploads and the engine fetches at
boot. Read [Cloud](cloud.md) instead, which also lists what a managed
environment cannot configure and when to come back here.

## Requirements

- **Erlang/OTP 29.** The image is built on `erlang:29.0.4-slim`, and 29 is the
  only entry in the CI test matrix (`.github/workflows/ci.yml`). Nothing older
  is tested.
- **PostgreSQL 17.** Every compose file in this repository runs `postgres:17`.
- **linux/amd64.** The publish workflow declares no `platforms`, so the image
  is built for the runner's architecture only. There is no arm64 image; on
  Apple silicon it runs under emulation.
- **One TCP port**, `8084` by default. Game clients, the REST API, the
  WebSocket and the console all answer on it.

Other guides link here rather than restating a floor.

## What ships in the container

`ghcr.io/widgrensit/asobi` is a Debian-trixie-slim runtime image. It expects:

- A Postgres 17 database it can read and write.
- A directory mounted at `/app/game/` containing your Lua scripts.
- TCP `:8084` reachable by your clients.

No sidecars, no message bus, no Redis. The container is stateless apart from
`/app/game/`.

It runs as the unprivileged user `asobi` (uid 999), so the mounted game
directory and any secret file you mount have to be readable by that user. A
secret mounted `0600` owned by root produces `ops_secret_file_unreadable` and a
console that stays off.

The script directory is the `game_dir` key, `/app/game` in the image. Mount
somewhere else and set it in a `sys.config`; nothing reads it from the
environment.

The image fixes the Postgres port at `5432` (`config/prod_sys.config.src`). A
database on a different port means supplying your own `sys.config`.

## Where Lua scripts live

`/app/game/` is the search path for `require()` and the source of every Lua
callback the runtime invokes (match handlers, world tick, bots). Between game
ticks the runtime calls `filelib:last_modified/1` on the script; if the mtime
moves, it re-executes the script body against the existing Luerl state. See
`asobi_lua_reload` for the primitive.

You have four ways to put scripts there. Two of them exist. All four are
self-hosting patterns: a cloud environment gets its scripts from
[a bundle](cloud.md#how-lua-reaches-an-environment) and none of the four is
available there.

### Pattern 1: bake into the image (immutable)

You treat game-script changes as deploys. Each release of your game is a new
container image, rolled out by whatever already rolls out your services.

```Dockerfile
FROM ghcr.io/widgrensit/asobi:latest
COPY game/ /app/game/
```

mtime never changes inside a running container, so the per-tick `stat()` costs
nothing and no live reload happens: you ship code by shipping a container.

This is the safest model and the default recommendation. If you are not sure
which pattern you want, start here.

### Pattern 2: volume mount plus atomic rename (live updates)

You want to update scripts without rolling the node, during a live event or
because balance numbers move faster than your release train.

```yaml
services:
  asobi:
    image: ghcr.io/widgrensit/asobi:latest
    volumes:
      - /srv/asobi/game:/app/game:ro
```

Always write the file under a temp name and `mv` it into place. POSIX
`rename(2)` is atomic; an editor's save that truncates and rewrites is not, and
the runtime can observe a half-written file.

```bash
# Wrong: the runtime may stat() while the file is empty
cp build/match.lua /srv/asobi/game/match.lua

# Right: atomic swap, the runtime never sees a partial file
cp build/match.lua /srv/asobi/game/match.lua.tmp
mv /srv/asobi/game/match.lua.tmp /srv/asobi/game/match.lua
```

The next match or world tick picks up the new mtime and reloads. In-flight
state survives, because the script body re-declares globals and functions in
place; existing locals and table fields are untouched unless the script
explicitly re-runs `init()`.

For world zones, a reload that changes `spawn_templates` also takes effect
immediately: a running zone re-fetches its template set on the reload tick
itself, so new templates become spawnable without restarting the zone. If the
reloaded `spawn_templates` itself fails, the zone keeps the templates it had
rather than clearing them.

A new script with a syntax error leaves the old code running, logs a warning,
and records the new mtime so the same broken file is not retried every tick.
Fix it, save again, and the next tick reloads. A callback that fails on every
tick is logged under the `script_log` limiter, 3 lines per 10 seconds per
script and callback, so a broken script does not drown the log.

### Pattern 3: signal-driven reload (planned, not shipped)

A `ASOBI_LUA_RELOAD=signal` mode that skips the per-tick `stat()` and reloads
only when explicitly triggered does not exist. Until it does, use pattern 2 or
turn reload off entirely.

### Pattern 4: custom script source (planned, not shipped)

If your scripts live in Postgres, S3, git tags or a CMS, the eventual answer is
an `asobi_lua_source` behaviour dispatching to a custom loader. It does not
exist. The workaround is a sidecar that pulls from your source and writes into
`/app/game/` using pattern 2.

## Mode-shape changes reload separately

Hot reload re-executes a script body inside servers that already exist, so it
cannot change how a match is *formed*. `match_size`, `strategy`, `max_players`
and the `config.lua` mode manifest are read at formation time.

A second poller handles those. `asobi_lua_config_watcher` stats `config.lua`,
`match.lua` and every registered mode's script every 1500 ms and re-runs the
config loader when an mtime moves, so new matches pick up the change. Running
matches keep the values they formed with.

`config_watch_interval` changes the interval. The watcher shares the hot-reload
dial: with reload off it never scans at all. A failed reload keeps the
last-good mode set and adopts the new mtimes anyway, so a broken file waits for
your next edit rather than being retried forever.

## A minimal production compose

Two files sit next to it, neither of which belongs in git:

```bash
{
  echo "ASOBI_DB_PASSWORD=$(openssl rand -hex 24)"
  echo "ERLANG_COOKIE=$(openssl rand -hex 24)"
} > .env
openssl rand -hex 32 > ops_secret.txt
printf '.env\nops_secret.txt\n' >> .gitignore
```

`.env` is read by compose automatically and is the single source for the
database password, so Postgres and asobi cannot drift apart. `ops_secret.txt`
is mounted as a file rather than passed as a variable, which keeps it out of
`docker inspect` and out of the process environment.

The image was renamed from `ghcr.io/widgrensit/asobi_lua`. That name is no
longer rebuilt - tags already published keep working and are not going away,
but they will not get fixes - so change your compose file.

```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: asobi
      POSTGRES_PASSWORD: ${ASOBI_DB_PASSWORD:?set ASOBI_DB_PASSWORD in .env}
      POSTGRES_DB: asobi
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U asobi"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  asobi:
    image: ghcr.io/widgrensit/asobi:latest
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: asobi
      ASOBI_DB_USER: asobi
      # Compose reads a sibling `.env` automatically, so the password lives
      # there rather than in this file. There is no ASOBI_DB_PASSWORD_FILE:
      # the password is substituted into sys.config before the VM starts, so
      # unlike the ops secret below it cannot be read from a file.
      ASOBI_DB_PASSWORD: ${ASOBI_DB_PASSWORD:?set ASOBI_DB_PASSWORD in .env}
      # No default. Unset renders an empty Access-Control-Allow-Origin, which
      # no browser accepts, so put this deployment's real origin here.
      ASOBI_CORS_ORIGINS: https://play.yourgame.com
      # Distribution cookie. The image default is the literal `asobi`.
      ERLANG_COOKIE: ${ERLANG_COOKIE:?set ERLANG_COOKIE in .env}
      # The operator console, on the game port. Drop these two lines to run
      # without it.
      ASOBI_CONSOLE: "true"
      ASOBI_OPS_SECRET_FILE: /run/secrets/ops_secret
    volumes:
      - /srv/asobi/game:/app/game:ro
    secrets: [ops_secret]
    healthcheck:
      test: ["CMD", "bin/asobi", "ping"]
      interval: 10s
      timeout: 5s
      retries: 6
    ports:
      - "8084:8084"
    restart: unless-stopped

secrets:
  ops_secret:
    file: ./ops_secret.txt

volumes:
  pgdata:
```

Put this behind a TLS-terminating reverse proxy (Caddy, nginx, Traefik). asobi
speaks plain HTTP and WebSocket and expects the proxy to handle certificates.

`ASOBI_NODE_HOST` is not in that compose on purpose. It names the Erlang node
(`-name asobi@${ASOBI_NODE_HOST}` in `config/vm.args.src`), not a bind address;
the port asobi listens on is `ASOBI_PORT`. The image default `127.0.0.1` is
what you want for a single-node deploy.

For a single node, also close distribution off. The shipped `vm.args` carries
the line commented out:

```
-kernel inet_dist_use_interface "{127,0,0,1}"
```

Uncomment it in your own `vm.args` and the distribution port stops listening on
anything but loopback, which is what makes a leaked cookie a local problem
rather than a lateral-movement one. [Clustering](clustering.md) covers the
multi-node case, where you need distribution and every node needs the same
cookie.

### Health endpoints

The node serves three, unauthenticated, on the game port:

| Path | Answers |
| --- | --- |
| `/live` | `200 {"status":"alive"}` as long as the VM responds. Liveness probe |
| `/ready` | `200 {"status":"ready"}` once the critical database dependency has passed a health check, `503 {"status":"not_ready"}` before that. Readiness probe |
| `/health` | The full report: dependency status, circuit-breaker and bulkhead state, and VM gauges |

`/ready` is the one an orchestrator should gate traffic on. Kubernetes reads it
with an `httpGet` probe.

The compose healthcheck above uses `bin/asobi ping` instead, because the image
carries no HTTP client: there is no `curl` and no `wget` in it.

### The operator console

A stock node serves neither: `/console` needs `console` to be true, and the ops
routes reject everything until an `ops_secret` is configured. The two lines in
the compose above set both. [Operator console](console.md) covers signing in,
what the screens show, what the plane cannot do, and the cluster caveats.

The plane is read-only apart from extension actions, so it is not where you ban
a player or refund a purchase.

Both share the game port, so anyone who can reach your game can reach
`/console`. Restrict it at the proxy.

## Tuning knobs

All four go under `{asobi, [...]}`; an existing `{asobi_lua, [...]}` block also
still works, see
[Which application key](configuration.md#which-application-key).

| Key | Default | What it does |
| --- | --- | --- |
| `max_heap_words` | `5_000_000` | Per-eval heap cap, in Erlang words, for every Lua callback. An eval that allocates past it is killed by the VM and the runtime returns `{error, heap_exhausted}`; persistent state held by the gen_server is untouched. Raise it only if a single tick legitimately builds a very large local structure. Long-lived tables belong in the persistent Luerl state and cost nothing per eval |
| `max_reductions_per_ms` | `50_000` | Per-eval CPU cap, as BEAM reductions per millisecond of that callback's own budget, so `tick` (500 ms) gets 25,000,000 and a bot's `think` (50 ms) gets 2,500,000. A timeout bounds latency but not work: without this, a script that spins is killed at its deadline and does it again next tick. Overrun returns `{error, reductions_exhausted}`, the result is discarded and the previous Lua state kept, so the match or zone survives. Sampled every 10 ms. `0` disables it |
| `reload_mode` (or `ASOBI_LUA_RELOAD`) | `auto` | `auto` mtime-polls the script on every tick. `off` skips the poll entirely, which is right for a sealed bundle where new code is a container restart. Anything unrecognised falls back to `auto`, so a typo cannot silently disable reload |
| `config_watch_interval` | `1500` | Milliseconds between mode-shape scans (above) |

```erlang
%% sys.config
[
  {asobi, [
    {max_heap_words, 10_000_000},
    {max_reductions_per_ms, 50_000},
    {reload_mode, off}
  ]}
].
```

The first three are read per call, not at boot, so changing one through
`application:set_env/3` takes effect without a restart.
`config_watch_interval` is read once, when the watcher starts. In a Docker
deploy, `ASOBI_LUA_RELOAD=off` in the container environment is the usual route.

## Validating Lua scripts in CI

Load a script through the loader to catch syntax errors and sandbox violations
without a database or a running node:

```bash
docker run --rm -v "$PWD/lua:/g" ghcr.io/widgrensit/asobi sh -c \
  'erts-*/bin/erl -noshell -boot no_dot_erlang -pa lib/*/ebin \
     -eval "asobi_lua_validate:cli([\"/g/match.lua\"])."'
```

Exits 0 on a clean script, 1 with the loader's error reason on stderr
otherwise. Pass more paths to validate them in sequence; it stops at the first
failure.

This runs a throwaway VM inside the image. Do not reach for `bin/asobi eval`:
that evaluates on a *running* node, and `asobi_lua_validate:cli/1` ends in
`halt/1`, which would stop your server.

## Before you go to production

- **The console is off** unless you turned it on. Leave it off if nobody needs
  it; if you turn it on, put it behind the proxy restriction above.
- **Guest auth is off** until the game declares `guest_auth = true` in its Lua
  *and* the operator configures a pepper of at least 32 bytes. Both halves are
  required (ADR 0004), and the operator half currently needs a `sys.config`:
  `ASOBI_GUEST_VERIFIER_PEPPER` is declared in the image but never substituted,
  so setting it alone does nothing.
- **Hot reload is on** unless `ASOBI_LUA_RELOAD=off`. On a sealed image that is
  a wasted `stat()` per tick; on a mounted volume it is the feature.
- **Rate limits are per node.** A 5/s bucket is 5 x N across a cluster. The
  development config loosens `auth`, `register`, `iap` and `api` to 1000/s for
  the test suite; the production config does not.
- **CORS is empty by default.** Set `ASOBI_CORS_ORIGINS` to your real origin or
  every browser client fails preflight.
- **`ERLANG_COOKIE` defaults to the literal `asobi`.** Change it, in every
  node, before you expose distribution to anything.
- **The database port is fixed at 5432** in the image. A different port needs
  your own `sys.config`.

## Upgrading

### Which tag to run

Every compose file in these guides says `:latest`, which is right for trying
asobi and wrong for running it. `latest` follows the default branch, so a
`docker compose pull` can move you across a schema change you did not choose.

Pin a digest. It is the only tag on this image that cannot move under you:

```yaml
image: ghcr.io/widgrensit/asobi@sha256:<digest>
```

`docker pull ghcr.io/widgrensit/asobi:latest` prints the digest it resolved, and
that is the value to paste. Move it when you have decided to upgrade, with a
backup taken.

Do not pin a version number on this image yet. `ghcr.io/widgrensit/asobi`
carries a `0.13`-`0.23` semver series left over from an earlier publishing
workflow: those are real but from April 2026, and they predate the Lua merge and
the console. Version tags resume from the next release; until one exists, the
only current tags are `latest`, `main` and the long commit SHA.

### Rolling a new version

Migrations run at boot, from `asobi_app:start/2`. A failure logs
`migration_failed` and the node **starts anyway**, so a bad roll leaves a
running node serving an old schema and answering requests. Extension routes
answer `503 not_ready` in that state; core does not.

Back up before you roll, and grep the boot log for `migrations_applied` after
you do.

## Operating notes

- **Database backups.** Postgres holds players, tokens, cloud saves,
  leaderboards, economy, chat history, tournaments and IAP transactions.
  `pg_dump` or `pg_basebackup` on whatever cadence your loss tolerance needs;
  nothing in asobi is recoverable from the runtime alone.
- **Logs.** Structured JSON via `nova_jsonlogger`, on container stdout. Ingest
  them as JSON lines.
- **Crash dumps.** Erlang writes `erl_crash.dump` to the working directory on a
  VM crash, which in a container means it is lost on restart unless you mount a
  writable volume. Leaving it ephemeral is fine; if you want post-mortems,
  mount a short-retention volume at `/app`.
- **Restarts.** In-flight matches and worlds live in memory and are not
  preserved. Design clients to reconnect.

## What this guide does not cover

- Multi-node operation. See [Clustering](clustering.md), which also holds the
  complete list of what is per node.
- Multi-tenant hosting. This image is single-tenant.
- Payments. asobi ships the IAP receipt-validation primitive and nothing else.
- Managed hosting. See [Cloud](cloud.md), where the deployment model is a CLI
  bundle rather than anything on this page.
