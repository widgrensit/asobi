# erlang-match — asobi, minus Lua

A runnable fork-and-go example showing how to depend on the `asobi` library
from a plain Erlang/OTP application. Two-player click-counter, hot-reloadable
from the `rebar3 shell`, PostgreSQL-backed.

Companion to the [/docs/erlang/getting-started](https://asobi.dev/docs/erlang/getting-started)
guide on asobi.dev. Read that for the walkthrough; clone this for the
starting point.

## Run it

```bash
docker compose up -d      # Postgres 17 on localhost:5432
rebar3 shell              # pulls deps, runs migrations, boots asobi
```

You'll see `Nova application started` once asobi is listening on
`localhost:8080`. Verify:

```bash
curl -s localhost:8080/api/v1/auth/register \
  -H 'content-type: application/json' \
  -d '{"username":"alice","password":"hunter-2026"}' | jq
```

> Passwords must be at least 8 characters; asobi's auth returns a
> structured 422 with the exact reason if validation fails.


Expected:

```json
{
  "username": "alice",
  "player_id": "019de3...",
  "session_token": "wRqvop92/QgNe9immJuUzQrL9jelCYk3D3sB0NK7lmQ="
}
```

> The `session_token` is a base64-encoded random secret (not a JWT). Pass it
> verbatim in `Authorization: Bearer …` on subsequent calls.

Now connect a WebSocket client (`wscat`, Defold, Godot, etc.) and play
the `hello` mode. See the full client protocol in
[guides/websocket-protocol.md](../../guides/websocket-protocol.md).

## Hot reload

Edit `src/hello_game.erl` — say, change the broadcast event from
`update` to `tick`. In the running shell:

```erlang
1> r3:compile().
%% or, for one module after an external `rebar3 compile`:
1> l(hello_game).
```

In-flight matches running the old version continue on the old code;
new matches pick up the new version. No dropped connections, no
restart.

## What's here

- `rebar.config` — depends on `asobi` from Hex, points the shell at
  `config/sys.config`.
- `config/sys.config` — Nova → kura → shigoto → asobi wiring. The
  minimal set of keys you need to boot.
- `src/erlang_match_app.erl` + `src/erlang_match_sup.erl` — standard
  OTP app + empty supervisor. We don't actually run anything under
  our supervisor; asobi's own supervision tree owns all the match
  processes.
- `src/hello_game.erl` — the match module. Six callbacks, no more,
  no less.

## Where next

- [guides/getting-started.md](../../guides/getting-started.md) — library-level walkthrough.
- [guides/matchmaking.md](../../guides/matchmaking.md) — ticket shapes, strategies.
- [guides/voting.md](../../guides/voting.md) — pluggable vote methods.
- [guides/world-server.md](../../guides/world-server.md) — persistent zones instead of short-lived matches.
