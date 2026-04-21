# If asobi disappears tomorrow

This is a one-page runbook for keeping your game alive if Widgrensit AB
(the company behind asobi) vanishes, pivots to AI, gets acquired, or
otherwise ceases to exist. **We wrote it because you shouldn't have to
trust us.**

## What we commit to

1. **Apache-2.0 forever.** The [asobi library](https://github.com/widgrensit/asobi)
   and [asobi_lua runtime](https://github.com/widgrensit/asobi_lua) are
   published under Apache-2.0. **We will never relicense** — no BSL, no
   SSPL, no Business Source dual-track. If we need to change the licence
   we'll fork our own project under a new name rather than take Apache-2
   away from you.
2. **No closed-core.** Every feature in the public repos is the feature you
   run. Our commercial cloud runs the same binary you can pull from
   `ghcr.io/widgrensit/asobi_lua:latest`.
3. **Public Docker images mirrored.** Published to GitHub Container Registry
   under `ghcr.io/widgrensit/*`. GHCR is free to pull without auth; you can
   also mirror to your own registry.
4. **No mandatory phone-home, no licence check-in.** The runtime works
   indefinitely without talking to us.
5. **Git history is the source of truth.** No force-pushes to release tags.
   No rewritten history on `main`.

## If we disappear, here's what to do

### 1. Pin a known-good version

As soon as you see us go quiet (no commits / no Discord / no blog posts for
30+ days), pin your deployment to a specific Docker image digest:

```yaml
# docker-compose.yml
services:
  asobi:
    # Before: ghcr.io/widgrensit/asobi_lua:latest
    # After: pinned by digest
    image: ghcr.io/widgrensit/asobi_lua@sha256:<digest-of-your-last-known-good>
```

Grab the digest from `docker pull` output or the
[GHCR package page](https://github.com/widgrensit/asobi_lua/pkgs/container/asobi_lua).

### 2. Mirror the image to your own registry

```bash
docker pull ghcr.io/widgrensit/asobi_lua:latest
docker tag ghcr.io/widgrensit/asobi_lua:latest \
           your-registry.example.com/asobi_lua:v-$(date +%Y-%m-%d)
docker push your-registry.example.com/asobi_lua:v-$(date +%Y-%m-%d)
```

Point your `docker-compose.yml` / k8s manifest at `your-registry.example.com`.
You now own the runtime.

### 3. Fork the source

```bash
git clone https://github.com/widgrensit/asobi.git
git clone https://github.com/widgrensit/asobi_lua.git
# Push both to your own remote.
```

Both repos include the full history. You can build the Docker image yourself:

```bash
cd asobi_lua
docker build -t myorg/asobi_lua:from-fork .
```

### 4. Export your data

Every piece of state in asobi lives in PostgreSQL (the one you host). There
is **no state outside your database**. To produce a cold-storage backup:

```bash
# Full logical backup
docker compose exec postgres pg_dump -U postgres my_game > backup-$(date +%Y-%m-%d).sql

# Binary backup (faster to restore)
docker compose exec postgres pg_basebackup -U postgres -D /backup -Fp
```

Restoring onto any stock PostgreSQL server (any version within pgo's
supported range) gets you back a functional asobi tenant.

### 5. Update OTP / Postgres yourself

asobi depends on standard, long-lived open-source infrastructure:

- **Erlang/OTP** ≥ 28. Upgrade path: drop in a newer OTP version, run
  `rebar3 compile`. asobi spec-is-clean and tested against recent OTP;
  upstream OTP is Ericsson's responsibility and they don't disappear.
- **PostgreSQL** ≥ 15. Standard `pg_upgrade` works.
- **Lua** 5.3 via [Luerl](https://github.com/rvirding/luerl). Rob Virding
  (the V in BEAM) maintains Luerl in Apache-2 as well.

None of these depend on us being alive.

### 6. Join the community fork

If we go dark, it's likely someone in the Discord — or the closest thing
the Discord becomes — will pick up maintenance. Keep an eye on:

- GitHub forks of `widgrensit/asobi` and `widgrensit/asobi_lua`
- The `#operations` channel on the [Asobi Discord](https://discord.gg/vYSfYYyXpu)
- The Erlang Forum (`erlangforums.com`) and the #gamedev tag

## What isn't here

This guide covers the open-source library + runtime only. The commercial
`asobi.dev` cloud (opens later in 2026) is a separate layer: if we shut down
the managed service, we'll give you:

- 60 days' notice minimum, in writing, before shutdown
- A one-click **"export everything to a Docker bundle"** button that
  produces a runnable self-host package with your data, your scripts, and
  your PostgreSQL dump
- Best-effort migration help through the shutdown date

The open-source side stays open-source regardless.

## Questions?

Open an issue, post in the Discord `#operations` channel, or email
`hello@asobi.dev`. If none of those still exist — fork the code, export
your Postgres, and you're the custodian now.

We'd rather earn your trust by making leaving easy.
