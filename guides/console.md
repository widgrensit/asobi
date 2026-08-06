# Operator console and the ops API

asobi serves an operator console at `/console` and a game-operations HTTP API
at `/api/v1/ops/*`. One node, one listener: both answer on the same port the
game does - `8084` in the image - and ship in the same release.

Neither is on by default, and they are gated separately.

`/console` is served only when `console` is true. Every console route answers
404 otherwise.

`/api/v1/ops/*` is always mounted and admits nobody until an ops secret is
configured, so on a stock deployment every request to it answers 403. Turning
the console off does not close the ops plane; unsetting the secret does. (A
managed environment has a second credential - see
[Minted tokens](configuration.md#minted-tokens-managed-environments) - which
needs `ops_token_secret` and `env_id`, neither set by default.)

The two look coupled because enabling the console with neither credential
configured turns the console back off, below.

This plane is reads plus account lifecycle - erasing and exporting one player.
If you came here for moderation actions, skip to
[What it cannot do](#what-it-cannot-do) first.

## Turning it on

Two settings. The console flag, and a credential for it to check.

In the image, both come from the environment:

| Variable | Sets |
| --- | --- |
| `ASOBI_CONSOLE` | Serve `/console`. `1`, `true`, `yes` or `on` enable it; anything else, including a typo, leaves it off |
| `ASOBI_OPS_SECRET_FILE` | The ops secret, read from a file. Preferred |
| `ASOBI_OPS_SECRET` | The ops secret, read from the variable itself |
| `ASOBI_CONSOLE_LABEL` | Names this deployment in the tab title and the console header |
| `ASOBI_CONSOLE_PRODUCTION` | Marks a deployment to be careful in. The console colours its label |

A file beats the variable, and it never falls back to it. A named file that is
missing, unreadable or empty logs `ops_secret_file_unreadable` or
`ops_secret_file_empty` and leaves the secret unset - a deployment that mounted
a secret and got the path wrong must not come up quietly using something else.
A trailing newline is stripped, so `openssl rand -hex 32 > ops_secret.txt`
works as written.

Enabling the console with nothing that can sign in leaves the console **off**,
logs `console_disabled_without_credential` at error level, and starts the node
anyway. The game is the product; a misconfigured operator surface must not take
players offline. On success the node logs `console_enabled`.

"Nothing that can sign in" means neither credential. A managed environment
configures no `ops_secret` on purpose and passes this check on
`ops_token_secret` + `env_id` instead - see [Cloud](cloud.md#the-console).

The compose fragment, matching the production compose in
[Self-hosting](self-hosting.md):

```yaml
services:
  asobi:
    image: ghcr.io/widgrensit/asobi:latest
    environment:
      ASOBI_CONSOLE: "true"
      ASOBI_OPS_SECRET_FILE: /run/secrets/ops_secret
      ASOBI_CONSOLE_LABEL: prod
      ASOBI_CONSOLE_PRODUCTION: "true"
    secrets: [ops_secret]

secrets:
  ops_secret:
    file: ./ops_secret.txt
```

The container runs as the unprivileged user `asobi`, so whatever mounts the
secret has to leave it readable by that user. A file mode that only the owner
can read, mounted with a different owner, produces
`ops_secret_file_unreadable` and a console that stays off.

Not using the image? The same two settings in a `sys.config`:

```erlang
{asobi, [
    {console, true},
    {ops_secret, ~"a-32-byte-or-longer-random-secret"}
]}
```

An OS variable overrides `sys.config` only when it is set, so the two forms
coexist. [Configuration](configuration.md#operator-console) has the full key
table, including the three keys that have no environment variable.

## Signing in

Browsing to `/console` on a node that has it enabled gives a sign-in screen
with two fields: **Operator secret**, which is the `ops_secret` value, and an
optional name that defaults to `operator` and becomes the label on the session.
The page posts the secret once and does not keep it.

Underneath, `POST /console/session` exchanges a credential for a session. Two
are accepted:

```json
{"secret": "...", "label": "your name"}
```

for the operator secret, and

```json
{"token": "..."}
```

for a short-lived token minted by a control plane. The managed path also
accepts the token as a form POST, and answers that with a redirect to
`/console` - which is how a dashboard hands a browser over without the token
ever entering a URL, a referrer or an access log.

Either way the response sets two cookies: an `HttpOnly` session cookie the page
cannot read, and a script-readable CSRF cookie it can. Every later ops read
needs **both** the session cookie and the value of the CSRF cookie sent back as
an `x-csrf-token` header. A cookie on its own is not a credential here, which
is what makes a cross-site request that arrives with the browser's cookies
attached answer 403 rather than data.

`GET /console/session` reports the current actor - display name, source,
capability classes, and whether the identity behind it is attested. `DELETE
/console/session` ends the session and clears both cookies; logging out twice
is not an error.

Sessions last 12 hours by default. `console_session_ttl` changes that and is
clamped to 60-86400 seconds. Expiry is absolute: reading does not extend it.

The session store and the secret the CSRF token is derived from are per node
and per boot. Restarting a node signs everyone out of it, and that is the
correct coupling rather than a gap - it is also the only revocation a session
has apart from logging out.

## What the console shows

Nine screens, all of them reads:

- **Overview** - online players, node version, queue depth, installed
  extensions, and the runtime panel from `/api/v1/ops/stats`, polled every two
  seconds.
- **Players** - the player list, searchable across username and display name.
- **Matches** - the recorded match history, with the game-authored result on
  the detail page. Core writes one row per match when it finishes, so every row
  reads `finished` whatever the status filter offers.
- **Matchmaker** - one row per mode, deepest queue first, refreshed every three
  seconds.
- **Leaderboards** - boards rather than scores, then one board's persisted
  entries.
- **Economy** - the item catalogue and the store listings, side by side.
- **Chat** - the channels running on this node, then one channel's persisted
  history, searchable by message content.
- **Tournaments** - the tournament rows, with a `live` column that says whether
  a process is actually behind an `active` row.
- **Notifications** - the send history, filterable by read state.

What a reader arriving from another console will look for and not find:

- No worlds screen, no votes screen, no IAP screen.
- No wallets and no inventory. Both exist in the product; neither is on this
  plane.
- The players screen shows the ops projection only: `id`, `username`,
  `display_name`, `avatar_url`, `metadata`, `inserted_at`, `updated_at`. No
  linked providers, no guest status, no device verifiers.
- The matches screen is the **finished-match record**. Live matches are visible
  only through the player-facing `GET /api/v1/matches/live`.

## What it cannot do

Core's ops routes are reads apart from two account-lifecycle routes:

```
GET  /api/v1/ops/players/:id/export     Everything held about one player
POST /api/v1/ops/players/:id/erase      Delete one player. Irreversible.
```

Both are covered in
[Erasing and exporting a player](rest-api.md#erasing-and-exporting-a-player).
They exist because an operator must be able to answer a deletion or access
request without a database shell, and because an Apache-2 self-hoster
otherwise inherits an obligation the library gives them no way to discharge.

Everything else is still absent: no ban, no grant, no refund, no broadcast, no
ticket cancel and no match end. If you arrived expecting Nakama Console,
PlayFab Game Manager or the Hathora console, that expectation gap is real and
this is where it is.

The third mutating route takes its method, its handler and its capability class
from an installed extension's manifest. The console cannot invoke it today;
that surface is HTTP only. See [Extensions](extensions.md) for how an extension
declares one.

## Capability classes

Four: `read`, `player_data`, `config` and `erasure`. Every route on the plane
carries exactly one, and membership of that class in the caller's capabilities
is the only authorisation decision anywhere in the plane. A route with no class
is denied, so an untagged or mis-mounted route is closed rather than open.

Core tags `read` on every route but two: the player export is `player_data`,
because it returns everything about one identified person rather than a list
view, and the player erasure is `erasure`. `config` exists for extension
actions and for the classes a minted token can carry.

`erasure` is a class of its own for one reason, and it is not sensitivity:
it is the only one whose actions cannot be undone by a later call. A ban can
be lifted and a grant can be clawed back; an erased account is gone.

What proves what:

- The **operator secret** proves all four over a bearer header. One secret is
  one privilege level: whoever holds it holds `config`.
- A **minted token** proves only the classes it carries, and its lifetime is
  capped at 900 seconds by the node that verifies it, not by whatever minted it.
- A **console session** inherits its credential's classes and expires no later
  than that credential does. A fifteen-minute token cannot buy a twelve-hour
  session with wider capabilities.
- A console session opened with the **operator secret** gets every class
  **except** `erasure`. The secret proves it; the transport is what differs.
  A bearer secret in a config file is a script an operator wrote; a session
  cookie is a browser that can be XSS'd or clickjacked into posting once. Set
  `console_erasure` to `true` to allow it anyway.

Every rejection is `403` carrying the shared error object, whatever the cause:

```json
{"error": {"code": "forbidden", "message": "The caller may not perform this action.", "details": {}}}
```

Nothing configured, wrong secret and wrong capability class are deliberately
indistinguishable to a caller guessing. Player bearer tokens never reach this
plane at all - it never consults the player token store.

## Calling the ops API directly

The same routes answer a bearer token, which is what CI, a CLI or a script
uses:

```bash
curl -sS -H "Authorization: Bearer $ASOBI_OPS_SECRET" \
  "https://game.example.com/api/v1/ops/players?limit=20&sort=inserted_at&order=desc"
```

[REST API](rest-api.md#ops) has the per-route reference: the shared list
parameters, the sortable fields per endpoint, and the lookup shapes.
[Ops authentication](rest-api.md#ops-authentication) covers `x-asobi-operator`,
the attribution label a shared secret cannot supply on its own.

One route belongs here rather than there, because it is the one an operator
reaches for first:

```bash
curl -sS -H "Authorization: Bearer $ASOBI_OPS_SECRET" \
  https://game.example.com/api/v1/ops/stats
```

```json
{
  "data": {
    "node": "asobi@10.0.0.4",
    "online_players": 412,
    "process_count": 5183,
    "process_limit": 1048576,
    "run_queue": 0,
    "scheduler_count": 8,
    "memory_total": 184549376,
    "memory_processes": 92274688,
    "memory_ets": 12582912,
    "memory_binary": 25165824,
    "uptime_ms": 864000000
  }
}
```

It touches no database, so it still answers when Postgres is the thing that is
unwell - which is when you are most likely to be asking. `online_players` is
`null` rather than an error if presence is briefly unavailable; every other
field is a VM read that cannot fail.

## Behind more than one node

The session store and the CSRF secret are per node, so behind a round-robin
proxy roughly `(N-1)/N` of console requests answer 403 and drop the operator
back to the sign-in screen. Give `/console` and `/api/v1/ops` a sticky route,
or point the console at one node directly.

Every node needs the **same** ops secret. If they differ, which node answers
decides whether signing in works at all.

`/api/v1/ops/features`, `/matchmaker` and `/chat/channels` read node-local
state; everything else on the plane reads Postgres and is cluster-consistent. A
chat channel running on another node is simply absent from the list, though the
member count beside a channel that is present is fleet-wide.
`/stats` reports `node` for exactly this reason - the numbers are that node's,
apart from `online_players`, which is fleet-wide because presence is a
cluster-wide process group. Summing it across nodes multiplies your concurrency
figure by `N`.

[Clustering](clustering.md) holds the complete list of what is per node.

## Production notes

The console shares the game port. Anyone who can reach your game can reach
`/console`, so put it behind TLS and restrict who reaches it - allowlist at the
proxy, or require another layer in front of `/console` and `/api/v1/ops`.

`Secure` is set on both cookies when the request is HTTPS or arrives with
`x-forwarded-proto: https`. Behind a terminator that sends neither, set
`console_secure_cookie`. They are `SameSite=Lax` rather than `Strict`, because
the managed hand-off arrives as a cross-site POST and a `Strict` cookie would
not be sent on the redirect that follows it. `Lax` still refuses to send them
on a cross-site POST or an XHR, and the `x-csrf-token` header is the defence
doing the work.

`console_secure_cookie`, `console_api_base` and `console_session_ttl` have no
environment variable and need a `sys.config`.

`POST /console/session` shares the 5/s auth rate limiter, which is the bucket
that resists credential guessing. `/api/v1/ops/*` falls through to the 300/s
API limiter. Both are counted per node.

## Troubleshooting

**`/console` returns 404.** The console is not enabled on the node that
answered. Every console route answers the same 404 an unknown asset gets, so a
deployment with the console switched off is indistinguishable from one that has
it on and was asked for a file that does not exist.

**`/console` returns 503.** The console bundle is missing from the release.
This is a build problem, not a configuration one.

**The node is up but the console is off.** Grep the boot log for
`console_disabled_without_credential`, `ops_secret_file_unreadable` and
`ops_secret_file_empty`. The line that says it worked is `console_enabled`.

**Every ops call answers 403.** One of three things: no secret is configured,
the presented secret is wrong, or the credential does not carry the class the
route needs. The body is identical in all three cases, deliberately. Check the
node log for `ops request rejected: no ops_secret configured`, which is emitted
for the first case only.

**Sign-in works, then everything 403s a moment later.** A round-robin proxy in
front of more than one node. Make the route sticky.

## Next

- [REST API](rest-api.md#ops) - the per-route ops reference.
- [Configuration](configuration.md#operator-console) - every console key.
- [Self-hosting](self-hosting.md) - the production compose this fits into.
- [Cloud](cloud.md#the-console) - how a managed environment reaches this
  without an operator secret.
- [Clustering](clustering.md) - what is per node.
- [Extensions](extensions.md) - declaring an operator action.
