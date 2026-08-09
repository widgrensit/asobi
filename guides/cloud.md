# asobi Cloud

asobi Cloud is the managed version of the node described everywhere else in
these guides. You write the same Lua, your clients speak the same WebSocket and
REST protocol, and the callbacks, error codes and Lua API are identical.

What changes is operations. You do not run a container, you do not mount
`/app/game`, and you do not write a `sys.config`. Environments are created and
fed Lua through the `asobi` CLI, and the operator console is reached from the
dashboard rather than by holding a secret.

This guide is the honest version of that trade: the commands that exist, how a
bundle actually reaches an environment, and the list of things a cloud tenant
cannot do. If the last one rules you out, [self-host](self-hosting.md) - the
node is Apache-2.0 and complete.

## Availability

Invite-only. A new account is created only when the email is on an operator
allowlist, on the signup allowlist, or holds an approved waitlist row.
Everything else is refused at the point the account would be created.

The public front door is the waitlist on
[console.asobi.dev](https://console.asobi.dev): anyone may request access, an
operator approves or declines, and admission is single-use. An approval that
has been redeemed does not admit a second registration.

Joining a studio that already exists is a different path. An invite from a team
owner redeems a single-use token and does not go through the waitlist at all
(ADR 0008). One user belongs to one tenant.

## What "the same core" does and does not mean

The code is the same. The artefact is not.

A cloud environment runs `ghcr.io/widgrensit/asobi_engine`, a release that
wraps the `asobi` library published in this repository. Self-hosting runs
`ghcr.io/widgrensit/asobi`, a release built from the same library plus a Lua
directory contract. Same modules, same behaviour, two release builds with
different boot code: the engine fetches its Lua over HTTP at boot, the image
reads it off a mounted directory.

That difference is the source of nearly everything below.

## The CLI

### Install

```bash
curl -fsSL https://raw.githubusercontent.com/widgrensit/asobi-cli/main/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/widgrensit/asobi-cli/main/install.ps1 | iex
```

The scripts verify a checksum and install to `~/.local/bin` or
`%LOCALAPPDATA%\asobi\bin`; `ASOBI_INSTALL_DIR` overrides the location and
`ASOBI_VERSION` pins a release. `asobi upgrade` self-replaces the binary later,
verifying a signed checksum first, and refuses to when a package manager owns
the install. There is no winget package and no Scoop bucket yet; the release
build is wired for both but publishes neither.

Confirm with `asobi version`.

### Commands

| Command | Flags | What it does |
| --- | --- | --- |
| `asobi login` | `--saas-url`, `--token-name` | Browser device-code flow. Writes `~/.asobi/credentials.json` |
| `asobi logout` | | Deletes the credentials file |
| `asobi whoami` | | Prints the stored context. Local only, no network call |
| `asobi games` | | Lists the tenant's games, marking the active one with `*` |
| `asobi use <slug>` | | Persists the active game |
| `asobi create <name>` | `--size xs\|s\|m\|l`, `--game` | Creates an environment. Default size `xs` |
| `asobi deploy <env> [dir]` | `--game` | Validates, zips and uploads the Lua bundle. `dir` defaults to `.` |
| `asobi envs` | `--game` | NAME, SIZE, STATUS, ENDPOINT for the game's environments |
| `asobi start <name>` | `--game` | Starts a stopped environment |
| `asobi stop <name>` | `--game` | Stops a running environment |
| `asobi resize <name>` | `--size` (required), `--game` | Changes the size. Applies on the **next start** |
| `asobi delete <name>` | `--game` | Destroys the environment and deletes its row |
| `asobi health [env]` | `--game` | `GET /health` against the resolved endpoint |
| `asobi init [dir]` | `--template` | Scaffolds a project |
| `asobi dev` | `--port`, `--dir` | Runs a local backend in Docker. No account needed |
| `asobi config set\|show` | | The manual `url` / `api_key` fallback for self-hosters |
| `asobi upgrade` | | Updates the binary |

`asobi env list` and `asobi destroy <env_id>` are the older tenant-wide
commands. `asobi destroy` takes a UUID rather than a name and is best avoided -
see [Two commands to be careful with](#two-commands-to-be-careful-with).

### How a game is chosen

Every environment belongs to a game and a CLI token is tenant-scoped, so an env
command needs a game. It resolves in this order:

1. `--game <slug>` on the command line.
2. The active game from `asobi use <slug>`.
3. If the tenant has exactly one game, that one.
4. An interactive picker, if stdin is a terminal.
5. Otherwise it is a hard error.

A tenant with two or more games running commands from CI has no terminal for
step 4, so pass `--game` explicitly there.

### TLS is not optional

`asobi login --saas-url` and `asobi config set url` both refuse anything that
is not `https`, except `http` to a loopback host for local development. There
is no `--insecure` flag.

## Getting started

```bash
asobi init mygame --template arena
cd mygame
asobi dev
```

`asobi dev` writes `.asobi/dev-compose.yml`, runs Docker Compose in the
foreground and mounts your Lua directory. It never reads credentials and never
talks to the control plane, so you can evaluate asobi with no account at all.

The genre starters are `arena`, `basic`, `chat`, `turn-based` and `world`, each
scaffolding a runnable `lua/match.lua`. `--template defold`, `godot`, `unity`
or `backend` fetch a full client-plus-backend demo from a pinned repository tag
instead.

When you want it hosted:

```bash
asobi login
asobi games
asobi use mygame
asobi create prod
asobi deploy prod lua
asobi envs
```

The last line is not optional politeness. See below.

## How Lua reaches an environment

The engine pulls; the control plane never pushes. In order:

1. **Collect.** The CLI walks the directory you named and takes **every
   `.lua` file** under it, recursively, keying each by its relative path. Assets,
   JSON and text files are not included - the bundle is Lua and nothing else.
2. **Validate locally.** Before any network call, three gates run:
   - an entry point (`config.lua`, or `match.lua` for single-mode) must sit at
     the **root of the bundle**. This is the "you deployed the parent
     directory" error, and catching it here is the difference between a clear
     message and an environment that boots with no game modes;
   - every `.lua` file must compile;
   - `config.lua` must return a table of `mode_name = "script.lua"`, every named
     script must be present, and `guest_auth` must not be a field of that table.
     The engine reads `guest_auth` as a top-level global, so a table field is
     silently ignored.
3. **Zip.** Deflate, forward-slash entry names, every entry stamped with a fixed
   timestamp so the bundle is byte-reproducible. The path normalisation matters
   on Windows, where a backslash entry name would be extracted as a literal
   file called `lua\match.lua` and nothing would find your entry point.
4. **Upload.** `POST /internal/cli/envs/<name>/deploy?game=<slug>` as
   `application/zip`, authenticated with the access token. A 401 refreshes the
   access token and retries.
5. **Gate.** The control plane resolves your tenant from the token, the game
   from the slug within that tenant, and the environment by name within that
   game. It then refuses with **409 `env_not_deployable`** unless the
   environment is `running`, `deploying` or `degraded`. Every other state
   (`not_provisioned`, `provisioning`, `stopping`, `stopped`, `starting`,
   `scaling`, `destroying`, `destroyed`, `retired`, `failed`) has no engine that
   could take a bundle, so the deploy fails loudly rather than being silently
   dropped.
6. **Store.** The zip is hashed with SHA-256 and stored, and the generation
   counter on the environment is claimed before anything is triggered, so two
   back-to-back deploys cannot collide.
7. **Roll.** The provisioner rewrites the environment's Kubernetes Secret with
   the new bundle URL, hash and generation, stamps the generation into the pod
   template annotations, and re-applies the Deployment. The annotation is what
   makes Kubernetes actually roll: a Secret change on its own would not.
8. **Fetch and verify.** The new engine pod reads the bundle URL from its
   environment, fetches it over the control plane's internal listener
   authenticated with its own per-environment engine key, **verifies the
   SHA-256**, rejects any archive entry that would escape the target directory,
   and extracts to `/tmp/bundle-<generation>`.
9. **Register.** The engine points `game_dir` at the extracted directory and
   runs the same config loader a self-hoster's mounted directory goes through -
   so `guest_auth`, `registration`, the mode manifest and every per-mode global
   behave identically. With no entry point at the root it logs
   `bundle_no_entry_point`, lists where your `.lua` files actually landed, and
   pins `guest_auth` off.

### Two consequences worth stating plainly

**A deploy is a pod replacement, not a hot reload.** The Deployment strategy is
`Recreate`: the old pod terminates before the new one starts. In-flight matches
and worlds live in memory and do not survive. Self-hosting can hot-reload
because the runtime stats a mounted file between ticks; a bundle extracted into
`/tmp` inside a pod never changes for that pod's life, so there is nothing to
stat. Design clients to reconnect, and expect a short gap.

**A 200 from `asobi deploy` does not mean the environment is running your new
bundle.** The CLI prints its success line off the HTTP response, and that
response is sent before the Kubernetes work starts - deliberately, because
provisioning can outlast an HTTP client's timeout and orphaning live resources
against a request that died is worse. The observable outcome is
`provisioning_status` reaching `running`:

```bash
asobi deploy prod lua && asobi envs
```

A `503 provisioner_unavailable` means the bundle was stored but nothing was
rolled. Retry the deploy; the stored bundle is not lost.

## Authentication

### The login flow

`asobi login` runs an ECDH-encrypted device-code flow:

1. The CLI generates an ephemeral P-256 keypair and posts the public key with a
   token name (your hostname by default).
2. The control plane returns a session id, a user code and a verification URL.
   The CLI prints the code and opens a browser.
3. You approve in the dashboard. Approval needs a live dashboard session, so
   the person approving is someone the control plane already authenticated.
4. The control plane mints tokens, encrypts the payload under the shared secret
   and stores it against the session.
5. The CLI polls, decrypts locally and writes `~/.asobi/credentials.json`.

Because the payload is encrypted end to end, an observer on the polling channel
sees nothing usable.

### The tokens

| | Lifetime | Stored |
| --- | --- | --- |
| Access token | 24 hours | Control plane memory only; a restart costs one refresh |
| Refresh token | 30 days | Postgres, as a SHA-256 hash |

The refresh token is bound to a server-issued **device secret**, 32 random
bytes delivered once inside the encrypted payload. Refreshing needs both, and
the comparison is constant-time, so a stolen refresh token on its own is
useless. The `device_fingerprint` in your credentials is a hostname and a
dashboard label; it is explicitly not a security control.

A refresh re-checks current state before minting: your tenant must still be the
tenant recorded at login and that tenant must still be active. A failed check
deletes the row, which is what closes the offboarding window.

Scopes are `deploy` and `manage`, granted together at approval. There is no
scope selection.

### Storage and CI

`~/.asobi/credentials.json`, mode `0600`, in a `0700` directory. On Windows the
blob is additionally DPAPI-encrypted for the current user, because the file
mode creates no ACL there.

`ASOBI_ACCESS_TOKEN` overrides the stored access token. That is the CI hook:

```bash
export ASOBI_ACCESS_TOKEN="$ASOBI_TOKEN"
asobi deploy prod lua --game mygame
```

### Against self-hosting

A self-hoster has no CLI authentication, because there is nothing to
authenticate to. No control plane, no tenant, no device flow, no access token.
Their credentials are the database password, an `ops_secret` if they want the
ops plane at all, and whatever OAuth, Steam or IAP secrets the game itself
uses. They deploy Lua by changing files in a directory.

## The console

The [operator console](console.md) is the same nine screens either way. How you
get in is not.

Self-hosted, there is one long-lived credential: `ops_secret`, set by the
operator, presented as a bearer token, compared in constant time. There is no
default value, so a node that has not configured one rejects every ops request.
Over a bearer header it proves all four capability classes, `erasure` included.
A console session opened with it gets every class except `erasure`, unless
`console_erasure` is set to true.

On cloud, no shared secret ever reaches you:

1. You open the console link on the environment's dashboard page.
2. The control plane runs the same ownership guard every other environment
   action uses, then maps your **team role** onto capability classes:
   `owner` and `admin` get `read`, `player_data` and `config`; `member` gets
   `read` and `player_data`; anything else gets nothing. No role maps to
   `erasure`, so no cloud credential can reach it - see below.
3. It signs a token with `ASOBI_OPS_TOKEN_SECRET`, read out of that
   environment's own Kubernetes Secret at mint time. The control plane keeps no
   copy, so a database compromise does not confer the ability to mint.
4. The token lives **900 seconds**, which is the ceiling the engine enforces.
   Minting a longer one would produce a token that verifies nowhere.
5. The dashboard renders a form that posts the token to your environment's
   `/console/session`. A body rather than a URL, so the credential never
   reaches an access log, a referrer or browser history; a form the operator
   submits rather than script, so it needs no JavaScript and survives a CSP.
6. Your environment verifies the token and opens a session carrying exactly the
   token's capability classes and expiring no later than the token does. A
   fifteen-minute credential must not buy a twelve-hour session.

The claim that identifies you is your control-plane user id, not your email,
because it lands in that environment's audit rows.

| | Self-hosted | Cloud |
| --- | --- | --- |
| Credential | one `ops_secret` you set and keep | a 15-minute token, minted per person per environment |
| Privilege | every class over a bearer header; every class but `erasure` in the console, unless `console_erasure` is set | mapped from your team role; `member` cannot reach `config`, and nobody reaches `erasure` |
| Attribution | the `x-asobi-operator` header, a label with no authority behind it | the `sub` claim, marked attested, from an authenticated user |
| Revocation | change `ops_secret` | rotate the per-environment signing secret, which revokes every outstanding token for it at once |
| Turning it on | `{console, true}` plus a credential; off by default | already on |

There is no non-interactive path to the ops plane on cloud. A minted token
needs a browser session to mint it, so the CI-calls-the-ops-API pattern is a
self-hosting capability.

**Player erasure is not reachable on cloud.** `POST
/api/v1/ops/players/:id/erase` carries the `erasure` class, and the two
credentials that hold it - the `ops_secret` bearer header, and a console
session on a node with `console_erasure` set - are both operator config a cloud
tenant does not have. `GET /api/v1/ops/players/:id/export` is `player_data`, so
exporting one player's record does work from the cloud console; erasing them
does not. If you have to answer deletion requests yourself, that is a reason to
self-host. Ask us in the meantime and we will run it against your environment.

## What a cloud tenant cannot configure

A cloud environment's `sys.config` sets four `asobi` keys, all of them
generated and injected by the provisioner: `ops_token_secret`, `env_id`,
`console` and `guest_verifier_pepper`. There is no route, CLI flag, dashboard
field or environment-variable passthrough that reaches any other key.

That means the following are unavailable, and this is the honest list rather
than a summary:

**Identity providers and receipts.** `oidc_providers`, `base_url`,
`steam_api_key`, `steam_app_id`, `steam_identity`, `apple_bundle_id`,
`apple_root_cert_path`, `apple_root_certs`, `google_package_name`,
`google_service_account_key`. A cloud tenant cannot configure Google or Apple
sign-in, Steam authentication, or Apple and Google IAP receipt verification at
all. This is the largest gap on the list. If your game needs platform sign-in
or store receipt validation today, self-host.

**Guest auth beyond the toggle.** The per-environment pepper is injected for
you, so `guest_auth = true` in your Lua works. `guest_verifier_key_id`,
`guest_unlinked_cap`, `guest_reap_after` and `guest_reap_interval_ms` are not
settable, so unclaimed guests are never reaped and only the default soft cap
applies. Pepper rotation is not yours either. Your client can still shed
accounts one at a time with `POST /api/v1/players/me/erase`
([REST API](rest-api.md#erasing-your-own-account)) - that is the whole of guest
removal on cloud, so a client that mints a throwaway device pair per launch
should erase the account it abandons.

**Ops-plane shape.** `ops_secret`, `console_erasure`, `console_session_ttl`,
`console_secure_cookie`, `console_api_base`, `console_label`,
`console_production`. `ops_secret` and `console_erasure` are the two that
between them put the `erasure` class out of reach.

**Rate limiting and abuse control.** `rate_limits` and all of its buckets,
`client_gate`, `client_gate_timeout`, `client_gate_on_error`,
`trusted_proxies`. You run on the defaults and cannot plug in a CAPTCHA or an
attestation gate.

**WebSocket.** `ws_allowed_origins`, `ws_legacy_game_frames`,
`ws_idle_auth_timeout_ms`. No cross-site WebSocket-hijacking origin allowlist
is available, so the open default stands.

**Game structure at the operator layer.** `game_modes`, `game_dir` (the engine
writes it), `registration` on the operator side, `script_registration`,
`extension_restart`.

**Gameplay bounds.** `matchmaker` tick interval and maximum wait,
`vote_templates`, `world_max`, `world_max_per_player`,
`leaderboard_client_submit`, `leaderboard_max_boards`, `auth_cache_ttl_ms`,
`auth_cache_negative_ttl_ms`.

**Lua runtime dials.** `max_heap_words`, `max_reductions_per_ms`,
`reload_mode`, `config_watch_interval`, `dev_errors`, `terrain_providers`. A
large-world game on cloud is limited to the default terrain provider
allowlist.

**Clustering.** One replica per environment, `Recreate` strategy. Clustering is
not on the table.

**Everything outside the `asobi` application.** Database pool size, background
job queues, CORS origins (set control-plane-wide, not per tenant), logger level
and resilience gates.

### What you can set

Everything reachable from the Lua bundle, which is most of what a game actually
tunes: the `config.lua` mode manifest, the per-mode globals (`match_size`,
`max_players`, `strategy`, `bots`, `game_type`, `state_strategy`), the
world-mode globals (`tick_rate`, `grid_size`, `zone_size`, `view_radius`,
`empty_grace_ms`, `player_ttl_ms`), and the two config-layer globals
`guest_auth` and `registration`.

`registration` works on cloud precisely because the operator layer leaves it
unset - a script value only lands where no operator value exists.
`guest_auth = true` works because the provisioner pre-injects a per-environment
pepper for exactly that purpose: the game half is yours, the secret half is
not (ADR 0004).

[Configuration](configuration.md) marks which layer each key belongs to.

## Extensions do not run on cloud

An [extension](extensions.md) is an OTP application added as a dependency of
your release and listed in its application set. The engine release is built
with a fixed set of applications at image build time, there is no plugin
directory, and the bundle loader only ever registers Lua game modes.

Nor can you point an environment at your own image. The column exists in the
schema, but no tenant-reachable path writes it.

So: **cloud runs the stock engine.** If you need an extension - a custom
matchmaking strategy in Erlang, a hot loop, your own RPC methods, your own
schemas - you need to build a release, and that means self-hosting.

## Environments

`asobi create <name> --size xs|s|m|l` provisions a Deployment, Service, Ingress
and per-environment Secret, plus its own PostgreSQL database and login role.

| Size | vCPU | Memory |
| --- | --- | --- |
| `xs` | 1 | 256 MB |
| `s` | 1 | 512 MB |
| `m` | 2 | 1024 MB |
| `l` | 4 | 2048 MB |

Pricing is flat per environment per month. The current plans are shown in the
dashboard at [console.asobi.dev](https://console.asobi.dev), which is the
authoritative source; [asobi.dev/cloud](https://asobi.dev/cloud) describes the
service but carries no numbers.

Each environment gets a name of the form
`https://<game>-<env>.<tenant>.asobi.dev` with TLS, from a per-tenant wildcard
certificate applied ahead of the pod so issuance overlaps startup.

`asobi resize` updates the row; the new resources apply **on the next start**,
because a Deployment's resources are set at provision time. Stop and start to
take them, or wait for the next deploy.

The secrets an environment needs are generated for you and preserved across
redeploys, so they stay stable: the distribution cookie, the database password,
the guest-auth pepper, the ops-token signing secret and the engine key.

Beyond the CLI, the dashboard carries deletion protection, a retire-then-restore
lifecycle with a purge delay, log viewing, live gauges and time-series charts,
and environment-down alerting. Team roles, invites and one-tenant-per-user are
cloud concepts with no self-hosted equivalent.

### Two commands to be careful with

`asobi delete <name>` does not check deletion protection. The dashboard's
destroy button refuses a protected environment and goes through the retire and
purge lifecycle; the CLI path tears down the provisioned resources and deletes
the row directly. Protection is a dashboard guard, not a CLI one.

`asobi destroy <env_id>` is worse and should be treated as deprecated. It
revokes the environment's API keys and deletes the database row without calling
the provisioner, leaving the Deployment, Service, Ingress, Secret and database
running with nothing pointing at them. Nothing cleans that up on its own: the
control plane's only orphan sweep covers databases, not Kubernetes objects, and
it is off in production. Tell us if you have run it, so we can tear the
leftovers down by hand. Use `asobi delete <name>`.

## When to self-host instead

Choose cloud when the operational work is the part you do not want: TLS, a
database, backups, an ingress, a console you did not have to secure. A game
that authenticates with guests or your own accounts, tunes itself from Lua and
wants a console its team can share fits cleanly.

Self-host when any of these is true. None of them is a hypothetical.

- **You need platform sign-in or store receipt validation.** Google, Apple,
  Steam and IAP verification all need operator config a cloud tenant cannot
  reach. This is the most common reason.
- **You need an extension.** Erlang callbacks, custom matchmaking strategies,
  your own RPC methods or schemas. Cloud runs the stock engine.
- **You need to tune the runtime.** Rate limits, heap and reduction caps,
  matchmaker timing, world caps, terrain providers, WebSocket origin
  allowlists.
- **You need hot reload.** Mount a directory, edit a file, the runtime picks it
  up between ticks and in-flight state survives. Every cloud change is a pod
  replacement.
- **You need more than one node.** Cloud is one replica per environment.
- **You need server-to-server access to the ops plane.** An `ops_secret` works
  from CI; a minted token needs a browser.
- **You have to erase players yourself.** The `erasure` class needs operator
  config a cloud tenant cannot reach, so deletion requests go through us.
  Export works from the cloud console; erasure does not.
- **You need a specific database, version, port or pool size**, or Postgres
  somewhere you already run it.
- **Data residency or procurement says the data stays with you.** You do not
  choose the region an environment runs in; check
  [asobi.dev/cloud](https://asobi.dev/cloud) for where they run today, and
  self-host if that is not an answer you can accept.
- **The economics do not work.** Per-environment pricing against a box you
  already own is a straightforward comparison, and sometimes the box wins.

You are not locked in either way. A bundle deployed to cloud is the same Lua a
self-hosted node reads off a mounted directory, and [Exit](exit.md) covers
getting your data out.

## Next

- [Self-hosting](self-hosting.md) - the production compose and the deployment
  patterns cloud replaces.
- [Configuration](configuration.md) - every key, and which layer owns it.
- [Operator console](console.md) - the screens, the ops API, what it cannot do.
- [Lua scripting](lua-scripting.md) - what goes in the bundle.
- [Exit](exit.md) - what happens if we stop.
