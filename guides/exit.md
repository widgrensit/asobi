# If asobi disappears tomorrow

A runbook for keeping your game alive if Widgrens IT AB, the company behind
asobi, vanishes, pivots, gets acquired or otherwise stops. It exists because
you should not have to trust us.

## What we commit to

1. **Apache-2.0 forever.** [asobi](https://github.com/widgrensit/asobi) is
   published under Apache-2.0, and that includes the Lua runtime and the
   operator console, which are part of the same repository. We will never
   relicense: no BSL, no SSPL, no dual track. If the licence ever has to
   change we will fork our own project under a new name rather than take
   Apache-2.0 away from you.
2. **No closed core.** Every feature in the public repository is the feature
   you run. Our commercial cloud runs the same image you can pull from
   `ghcr.io/widgrensit/asobi:latest`.
3. **Public images mirrored.** Published to GitHub Container Registry under
   `ghcr.io/widgrensit/*`. GHCR is free to pull without authentication, and you
   can mirror to your own registry.
4. **No phone-home and no licence check-in.** The node works indefinitely
   without talking to us.
5. **Git history is the source of truth.** No force-pushes to release tags, no
   rewritten history on `main`.

## If we go quiet, here is what to do

### 1. Pin a known-good version

As soon as you notice us gone quiet - no commits, no releases, nothing for 30
days or more - pin your deployment to a specific image digest:

```yaml
# docker-compose.yml
services:
  asobi:
    image: ghcr.io/widgrensit/asobi@sha256:<digest-of-your-last-known-good>
```

Get the digest from `docker pull` output or from the
[GHCR package page](https://github.com/widgrensit/asobi/pkgs/container/asobi).

### 2. Mirror the image to your own registry

```bash
docker pull ghcr.io/widgrensit/asobi:latest
docker tag ghcr.io/widgrensit/asobi:latest \
           your-registry.example.com/asobi:v-$(date +%Y-%m-%d)
docker push your-registry.example.com/asobi:v-$(date +%Y-%m-%d)
```

Point your compose file or k8s manifest at `your-registry.example.com`. You now
own the runtime.

### 3. Fork the source

One repository. The game backend, the Lua runtime and the operator console are
all in it.

```bash
git clone https://github.com/widgrensit/asobi.git
```

Push it to your own remote. The full history comes with it, and you can build
the image yourself:

```bash
cd asobi
docker build -t myorg/asobi:from-fork .
```

### 4. Export everything

Two things make up a running deployment, and a backup of only the first is not
a backup.

**Your database.** All persistent state lives in the PostgreSQL you host:
players, wallets, transactions, inventories, match records, votes, IAP
transactions, leaderboards, chat history, cloud saves.

```bash
docker compose exec postgres pg_dump -U postgres my_game > backup-$(date +%Y-%m-%d).sql
```

**Your game scripts.** These are not in the database and they are not in the
image. They are the directory you mount at `/app/game` - `match.lua`,
`config.lua`, world scripts, bot scripts, anything they require. That directory
is the game. Keep it in version control and back it up alongside the dump.

```bash
tar czf game-$(date +%Y-%m-%d).tar.gz ./game
```

Restore both onto stock PostgreSQL and the image you mirrored, and you have a
functioning deployment.

#### Do not lose the operator surface

The console and the ops API are configured entirely from the environment, so
they live in your compose file rather than in the database or the game
directory. A custodian who rebuilds from a dump and a script tarball and
forgets them ends up with a working game and no way to look at it.

Carry `ASOBI_CONSOLE` and the ops secret (`ASOBI_OPS_SECRET_FILE`, or
`ASOBI_OPS_SECRET`) across with the rest of your deployment configuration, and
carry the secret file itself. See [Operator console](console.md).

### 5. Update OTP and Postgres yourself

asobi depends on standard, long-lived open-source infrastructure:

- **Erlang/OTP.** Ericsson maintains it and does not disappear.
- **PostgreSQL.** Standard `pg_upgrade` works.
- **Lua 5.3 via [Luerl](https://github.com/rvirding/luerl)**, also Apache-2.0.

The tested combination is in the Requirements section of
[Self-hosting](self-hosting.md#requirements). Older or newer versions may well
work; they are not what CI runs, so verify before you commit to one.

### 6. Join a community fork

If we go dark, someone is likely to pick up maintenance. Watch:

- GitHub forks of `widgrensit/asobi`
- The `#operations` channel on the [Discord](https://discord.gg/vYSfYYyXpu)
- The Erlang Forum (`erlangforums.com`), `#gamedev`

## What is not covered here

This page covers the open-source node. The commercial `asobi.dev` cloud is a
separate layer. If we shut the managed service down, we commit to:

- 60 days' notice minimum, in writing
- an export of your data, your scripts and your PostgreSQL dump in a form you
  can self-host
- best-effort migration help through the shutdown date

The open-source side stays open source regardless.

## Questions

Open an issue, post in the Discord `#operations` channel, or email
`hello@asobi.dev`. If none of those still exist, fork the code, export your
Postgres and your game directory, and you are the custodian now.
