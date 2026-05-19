# Asobi security audit - 2026-05-19

Auditor: Claude (Opus 4.7, 1M)
Scope: `~/ai/work/asobi` at `0b5680e` (chore(deps): bump kura to v2.0.4). Library only; single-tenant by design — multi-tenant isolation explicitly out of scope (that is the engine's concern). All file:line citations are against `src/...` paths in HEAD.
Threat model: untrusted authenticated game clients sending crafted HTTP/WS, plus the standard public-library concerns (dep CVEs, body/atom/ETS exhaustion, weak crypto, repo hygiene).

## Summary
Totals: 0 Critical / 4 High / 7 Medium / 6 Low / 4 Informational

Top-line conclusion: No critical bugs. The big gap is **WebSocket chat has no membership check** — any authenticated player can join and read any DM channel between any two other players, and send to it. After that the surface is mostly DoS/hardening: an unbounded HTTP body, an unbounded matchmaker-ticket map, fan-out amplification on `world.list`, and a vulnerable cowlib 2.16.0 pin. Cryptography on the I/O paths I read (Apple JWS, Google service-account JWT, password hashing) is solid.

## High

### H1 — WS `chat.join`/`chat.send` skip channel ACL — any player can read/write any DM
`src/ws/asobi_ws_handler.erl:247-269` (`chat.join`) only validates the channel-id *prefix* via `validate_channel_id/1` (lines 619-629). It accepts any binary starting with `dm:`, `world:`, `zone:`, `prox:`, or `room:`. Nothing checks that the joining player is actually a participant in the channel. `chat.send` at lines 219-231 is even more permissive — it forwards to `asobi_chat_channel:send_message/3` with no check at all. The HTTP `/api/v1/chat/:channel_id/history` controller does enforce membership (`src/controllers/asobi_chat_controller.erl:46-54`'s `authorized/2`) — so the auth model is well-understood, just unenforced on the WS path.

A malicious authenticated player can:
1. Send `{"type":"chat.join","payload":{"channel_id":"dm:<alice>:<bob>"}}` — the WS hander accepts it (prefix check passes), `asobi_chat_channel:join/2` joins them into the pg group `{chat, "dm:alice:bob"}` (`src/social/asobi_chat_channel.erl:18-22`), and every subsequent message Alice or Bob sends in that DM is delivered to the attacker via `{chat_message, ChannelId, Msg}` (line 88-91).
2. Send `{"type":"chat.send","payload":{"channel_id":"dm:<alice>:<bob>","content":"impersonated"}}` — appears in the channel as if from the attacker (sender_id is honest), but it is delivered to Alice and Bob, persisted to `asobi_chat_message`, and shows up in their history. This is annoying spam at minimum, social-engineering vector at worst.
3. Same trick for `world:`, `zone:`, `prox:`, and arbitrary `room:` IDs.

**Fix:** Mirror `asobi_chat_controller:authorized/2` on the WS path. Add `authorized(ChannelId, PlayerId)` to both `chat.join` and `chat.send` clauses, returning an error reply when the check fails. The check is read-only (a `pg:get_members` for world/zone, a DB query for groups) so latency cost is small; consider caching per-connection.

### H2 — Unbounded HTTP body size on every JSON endpoint
`config/{dev,prod}_sys.config.src` configures `nova_request_plugin` with `decode_json_body => true`. That plugin reads the body via `cowboy_req:read_body/1` with default options and accumulates `more` chunks indefinitely (`_build/default/lib/nova/src/plugins/nova_request_plugin.erl:108-111`). Cowboy's default per-chunk cap is ~8 MB but the loop never bounds the total. There is **no `max_body_length` anywhere in `src/` or `config/`** (`grep -rn max_length\|read_body src/` returns nothing).

Affected endpoints include every POST/PUT route in `src/asobi_router.erl` — `/auth/register`, `/auth/login`, `/iap/apple|google`, `/players/:id`, `/storage/:collection/:key`, `/saves/:slot`, `/dm`, `/groups`, etc. `storage_controller:put_save/1` has a 256 KB `MAX_SAVE_DATA_BYTES` check (`src/controllers/asobi_storage_controller.erl:8,214-219`), but that check only runs **after** the entire body has already been read into memory.

**Impact:** Any authenticated client (or unauthenticated, on `/auth/*`) can POST a 2 GB JSON body and the BEAM will buffer it before any handler sees it. With `cowboy_req:read_body/1`'s default `period=15s` and `length=8MB`, you can shovel ~5 GB/min/connection. With auth rate-limited to 5/sec/IP this is throttled per IP, but `api`'s 300/sec keying on player_id when authenticated means a single token attacker bursts a multi-GB OOM.
**Fix:** Add a default cap (e.g. `{max_length, 1_048_576}` per chunk plus a total-body accumulator in a wrapper) at the plugin layer, and per-route overrides on the few endpoints that legitimately accept larger bodies (none today).

### H3 — `world.list` fan-out: one WS message triggers up to 1000 synchronous `gen_server:call`s
`asobi_world_lobby:list_worlds/1` (`src/world/asobi_world_lobby.erl:20-41`) enumerates every pg group prefixed `asobi_world_server` and calls `asobi_world_server:get_info(Pid)` on each — a synchronous `gen_statem:call`. With the global cap `world_max=1000` (line 11), one WS message produces up to 1000 round-trips per call. The WS handler accepts `world.list` at up to 60 msgs/sec/conn (`src/ws/asobi_ws_handler.erl:6-7`). 60 × 1000 = 60k synchronous calls per second per attacking connection.

Each `get_info` blocks on the world's mailbox. With many worlds busy ticking, an attacker bursting `world.list` stalls every world's mainloop. With a single attacker holding ~10 connections this kills game responsiveness on a node hosting ~100 worlds.

**Impact:** Asymmetric DoS. Trivially mounted by any authenticated client.
**Fix:** Cache the `list_worlds` result in `asobi_world_lobby_server` with a short TTL (e.g. 500ms — one tick). Or call `get_info` async via a fanout helper that batches and applies a global rate limit per connection.

### H4 — `cowlib 2.16.0` is in scope of a known advisory; `rebar3 audit` reports 3 vulnerabilities total
`rebar.lock:` pins `cowlib 2.16.0`, `cowboy 2.13.0`. `rebar3 audit` against the GitHub Advisory DB reports `3 vulnerabilities found in 21 dependencies` with cowlib 2.16.0 flagged at HIGH severity (the auditor's printer then crashes on a unicode glyph before printing the others — `rebar3.crashdump` shows the partial output). cowlib 2.16.0 is in the affected range for HTTP/2/header-handling CVEs published in 2025 (GHSA-2g5p-...); upgrading to ≥ 2.16.1 is the recommended remediation.

**Impact:** Public-facing HTTP/WS server pinned to a vulnerable transport library. For an OSS lib consumed by third parties, shipping with a known-bad cowlib is a reputational risk in addition to the technical one.
**Fix:** Bump `cowboy` (which pulls cowlib transitively) to the latest 2.x. Re-run `rebar3 audit` until it reports 0 vulns. Pin via PR so Dependabot keeps pace.

## Medium

### M1 — `auth_cache_tab` stores raw session tokens as ETS keys in a `public` table
`src/auth/asobi_auth_cache.erl:116-123` creates `asobi_auth_cache_tab` as `public, set, named_table` with `read_concurrency`/`write_concurrency`. Entries are `{RawToken, {ok|error, _}, ExpiresAt}` — the raw token is the ETS key. Any process on the BEAM can `ets:tab2list(asobi_auth_cache_tab)` and dump every cached session token (default TTL 60s, line 40).

asobi is single-tenant by design so there is no untrusted Lua here. But the table contents are still attractive to (a) anyone with a BEAM debugger / observer / hot-code-load access, (b) anyone who triggers a crash dump (raw tokens land in the dump — see L1 / `rebar3.crashdump` in repo), and (c) any future feature that introduces user-defined extensions.

**Fix:** Key by `crypto:hash(sha256, Token)` the same way `nova_auth_session` already does for DB storage (`_build/default/lib/nova_auth/src/nova_auth_session.erl:24`). The token only needs to round-trip through the cache as an opaque hash. This is a one-function change in `resolve_token/1`, `put_positive/2`, `put_negative/1`, `invalidate/1`.

### M2 — No body-size / atom-pressure protection on matchmaker properties
`src/ws/asobi_ws_handler.erl:283-289` accepts `matchmaker.add` payloads with `properties => maps:get(~"properties", Payload, #{})` — any client-supplied map, stored verbatim into the matchmaker ticket state (`src/matches/asobi_matchmaker.erl:87-95`). The ticket map lives in the singleton matchmaker gen_server until matched or `max_wait_seconds` (default 60s).

WS rate limit is 60 msgs/sec/conn (`asobi_ws_handler.erl:6`). With a 60s wait window that's 3600 live tickets per attacker connection, each carrying an arbitrary properties map. A single attacker can pin ~10s of MB of matchmaker state per connection. There is no per-player ticket cap and no size limit on `properties`.

**Fix:** Cap `properties` byte-size after `json:encode` (e.g. 1 KB), and add a per-player live-ticket cap (e.g. 5). Reject `matchmaker.add` over the cap with `too_many_tickets`.

### M3 — `metadata` jsonb field on players accepts unbounded blobs
`src/players/asobi_player.erl:21` declares `metadata` as `jsonb, default => #{}`. `update_changeset/2` (lines 73-76) casts it without any size validation. Any authenticated player can `PUT /api/v1/players/:id` with a 2 GB metadata blob (subject to H2's larger problem) and persist that to Postgres. Even with H2 fixed the per-row blob is unbounded.

**Fix:** Validate `metadata` size (e.g. JSON-encoded ≤ 4 KB) inside `update_changeset/2`. Similarly cap the `display_name`/`avatar_url` fields (display_name already has max 64; `avatar_url` has no max).

### M4 — `banned_at` column exists in the player schema but is never read anywhere
`src/players/asobi_player.erl:22` defines `banned_at`. `grep -rn banned src/` shows the field declared in two places and read **zero**. The auth plugin (`src/plugins/asobi_auth_plugin.erl:6-19`), session resolver (`src/auth/asobi_auth_cache.erl:148-158`), and OAuth login (`src/controllers/asobi_oauth_controller.erl:133-146`) all happily mint sessions for banned players.

**Impact:** Operators have no working ban primitive. Setting `banned_at` in the DB does nothing; the field exists, lulling operators into a false sense.
**Fix:** Either implement the ban check (`asobi_auth_plugin` is the right chokepoint: deny when `banned_at /= undefined`), or remove the column from the schema until it's actually wired. Both are valid; document which one is the intent.

### M5 — No body-size cap on cloud-save / generic-storage data
`src/controllers/asobi_storage_controller.erl:38-42,108-114` derives a `Data`/`Value` map from the parsed JSON body. The save path checks `iolist_size(json:encode(Data)) =< 256 KB` (lines 213-219) — but the value-side `put_storage` path has **no size check** at all (line 109: `Value = maps:get(~"value", Params, #{})`). A player can write 100 MB into a single storage row.

**Fix:** Mirror the save-data limit on `put_storage` and `put_save`. Move the check upstream of body parsing (see H2).

### M6 — No cert pinning / explicit TLS options on outbound `httpc` calls
`src/auth/asobi_steam.erl:67-78` and `src/auth/asobi_iap.erl:264-285,378-393` use `httpc:request/4` with no `ssl` options, which means the default CA trust store and no hostname/SPKI pinning. A compromised CA can MITM Steam/Apple/Google validation responses and forge `result=OK` purchases. These are infrequent endpoints but the impact of a successful MITM is "free IAP purchases", which directly hits revenue.

**Fix:** Pass `[{ssl, [{verify, verify_peer}, {versions, [tlsv1.3]}, {server_name_indication, "api.steampowered.com"}, ...]}]`. Pin the SPKI of `api.steampowered.com`, `androidpublisher.googleapis.com`, `oauth2.googleapis.com`. Better: move to `jhn_shttpc` (already a transitive dep via `jhn_stdlib`) and configure once.

### M7 — `iap.erl` `bundle_id` check via direct pattern match (not constant-time)
`src/auth/asobi_iap.erl:62-63` compares the Apple-signed payload's `bundleId` against the expected operator value via Erlang pattern matching. Apple's JWS payload is integrity-protected (the signature is verified above), so a mismatch means a stolen-from-other-app receipt is being replayed, not a tampered receipt. Timing-distinguishability between `bundleId` mismatch and other failure paths is therefore weak — the only useful side-channel would be to recover the configured bundle_id, which is public anyway. Listed as Medium only because the *pattern* (`=:=` on secret-like material) appears elsewhere too; flag and move on. **Fix:** replace with `crypto:hash_equals/2` as a default style for any equality check that touches signed/authn data; it has no downside.

## Low

### L1 — `rebar3.crashdump` is in the repo root (5 KB)
The local working tree has `rebar3.crashdump` (dated 2026-04-30) sitting at the root. `git ls-files rebar3.crashdump` confirms it is **not tracked**, and it IS in `.gitignore`. Low risk in the current state, but easy to forget — crashdumps include heap/binary contents which can leak DB passwords from `dev_sys.config.src` evaluation, raw tokens from the auth cache (see M1), etc. **Fix:** delete from the working tree; consider a pre-commit hook that errors on `*.crashdump` and `erl_crash.dump`.

### L2 — `dev_sys.config.src` has DB password `postgres` and CORS `*`
`config/dev_sys.config.src:36-49` ships with `{password, "postgres"}` and `{allow_origins, ~"*"}`. The dev file is referenced by `rebar.config:48` for CT tests too, so it's also the "tests harness" config — fine for that purpose, but every new contributor cloning the repo runs Postgres with the trivial password. **Fix:** dev defaults are fine; document in README that this file is dev-only and require `.env` for any real deployment. Prod sys config is already env-driven.

### L3 — `prod_sys.config.src:32` interpolates CORS via raw `<<"${ASOBI_CORS_ORIGINS}">>` with no default fallback
If the operator forgets to set `ASOBI_CORS_ORIGINS`, the value becomes `<<"">>`, an empty binary that nova_cors_plugin treats as "no allowed origins" — which is fail-closed (good) but produces a silent prod outage rather than a startup failure. **Fix:** add a startup assertion in `asobi_app:start/2` that errors if `ASOBI_CORS_ORIGINS` is unset in prod.

### L4 — `asobi_cluster:discover_dns` calls `list_to_atom/1` on DNS responses
`src/asobi_cluster.erl:64,82` builds node names with `list_to_atom(BaseName ++ "@" ++ Addr)`. `Addr` comes from `inet:getaddrs/2` on a config-supplied hostname — operator-controlled, not attacker-controlled. The comment already calls out the bound. Low because the input source is trusted, but worth a paranoia bound (`length(Addr) =< 64`) so a poisoned DNS resolver can't blow the atom table. **Fix:** add a length sanity check before `list_to_atom`.

### L5 — `presence:disconnect` and `revoke_session` differ subtly
`src/social/asobi_presence.erl:47-52` (`revoke_session/2`) enqueues a shigoto job; `disconnect/2` (lines 55-58) sends directly. Callers can confuse which to use. Not a vuln, but the asymmetry invites mistakes where "revoke" is wired to the synchronous helper and never persisted, or vice versa. **Fix:** consolidate or comment the contract.

### L6 — `idle_auth_timeout_ms` from `application:get_env` without ceiling
`src/ws/asobi_ws_handler.erl:54-58` accepts any `is_integer(Ms) andalso Ms > 0` for the idle-auth timeout. An operator misconfiguring this to e.g. `3600000` (1 hour) effectively disables the F-28 defence. **Fix:** clamp the upper bound to a sane value (`min(Ms, 60_000)`).

## Informational

### I1 — `dependabot.yml` covers GitHub Actions + Docker but not Hex/rebar3 deps
`.github/dependabot.yml` lists `github-actions` and `docker` ecosystems only. There is no `hex` ecosystem entry, so cowlib/cowboy/jose/jhn_stdlib pin updates have to be done manually. (H4 above demonstrates the cost.) Dependabot doesn't have first-class `rebar3` support, but `mix` works for the Hex subset and there is community tooling. As long as rebar3_audit runs in CI (which it does — `.github/workflows/ci.yml:14` `enable-audit: true`) you'll see vulns; you just need to actually act on them.

### I2 — `dev_sys.config.src` allows rate limits of 1000/sec for auth — easy to copy into prod by accident
Lines 70-74. Documented as test-only with a "production callers should override" comment. Worth promoting that comment into a CI test that fails if the prod_sys.config exposes those values.

### I3 — `SECURITY.md`, `LICENSE`, `.github/dependabot.yml` are all present and well-structured
This is "already strong" but worth surfacing in this section: the project is doing the public-OSS table-stakes correctly. The SECURITY.md mentions GitHub Security Advisory + a security@ email, has SLA targets, and points to threat-model docs. Three workflows (`ci.yml`, `nightly.yml`, `release.yml`) and dependabot are wired.

### I4 — `guides/security-known-limitations.md` exists — make sure DM-eavesdropping (H1) goes in there until fixed
The known-limitations doc is the right place to disclose H1 while a fix is in flight, so external consumers know not to ship WS chat to untrusted users without a patch.

## Already strong

- **Apple StoreKit 2 JWS verification is correct**: alg pinned to ES256 (`asobi_iap.erl:9,113`), x5c parsed but the embedded root is **dropped** in favour of an operator-configured root (lines 121-129), chain validation via `public_key:pkix_path_validation/3` (line 149), signature via `public_key:verify/4` (line 160). The `none`/HS256 substitution attack is closed.
- **Google service-account JWT is signed via `public_key:sign/3` with RS256**, OAuth token exchanged at runtime, never cached longer than its TTL (`asobi_iap.erl:340-393`).
- **Password hashing via `nova_auth_password:hash`** with `pbkdf2_iterations: 100000` (`config/dev_sys.config.src:17`). Session tokens stored as hashes in DB (`nova_auth_session.erl:24`).
- **WS payload cap (64 KB) and per-connection rate limit (60 msg/sec) with sliding window**, idle-auth timeout (10s), per-IP connect limiter via seki (`asobi_ws_handler.erl:6-17,28-58`).
- **`safe_handle_message/2` wraps every WS handler in a try-catch** that maps known badmatch/badkey/function_clause/case_clause to user-friendly errors and only logs an `internal_error` on unexpected crashes (lines 507-527). Importantly, the handler does **not** echo the client-supplied `type` back into error logs (F-26 comment line 494) — kills the log-injection vector.
- **`asobi_qs:integer/5` clamps query-string integers** to `[Min, Max]` and returns the default on parse failure (`src/asobi_qs.erl:30-40`). Used everywhere — no `binary_to_integer` shrapnel in the controllers.
- **Matchmaker party sanitisation** in `sanitise_party/2` (`src/matches/asobi_matchmaker.erl:459-467`) — the requester is the only player allowed in their own party until a real invite/accept flow exists. F-7 explicitly closes the cross-player-pull vector.
- **Storage controller has ACL** (`get_storage`/`put_storage`/`delete_storage` keyed on `read_perm/write_perm` `public|owner` whitelisted; `valid_perm/1` rejects anything else — `src/controllers/asobi_storage_controller.erl:13,114-117`).
- **Spatial input dispatch is owner-keyed** in WS `match.input`/`world.input` — the `PlayerId` is read from the server-side session state, not the client payload (`asobi_ws_handler.erl:188-201,477-485`). Clients cannot spoof input as another player.
- **F-29 typed filter validation** on `world.list` (`asobi_ws_handler.erl:633-655`) — bad filter types reject instead of silently returning unfiltered worlds.
- **F-30 distribution hardening notes in `vm.args.src`** — single-node design, EPMD off, instructions for clustered mode with TLS-distribution and bounded port range.
- **`atomize_keys` uses `binary_to_existing_atom`** (`src/controllers/asobi_social_controller.erl:332`), not `binary_to_atom`. No atom-table growth from client input.
- **Idempotent friendship insert + self-add rejection** (F-23 in `social_controller`).
- **Per-route limiter selection** (`asobi_rate_limit_plugin:select_limiter/1`) with separate `auth` (5/s), `iap` (10/s), `api` (300/s), `ws_connect` (60/s) buckets — sensible defaults.
- **Rate-limit key prefers authenticated player_id** over IP (`asobi_rate_limit_plugin:rate_limit_key/1`), so carrier-NAT users share a rate-limit bucket only when unauthenticated.
- **SECURITY.md and LICENSE present**, dependabot enabled, CI runs `rebar3 audit`. Public-repo hygiene is in place.

## How to apply

1. **Land H1** first. The WS chat ACL is a confidentiality break for DMs and is a one-function addition (`authorized/2` already exists in `asobi_chat_controller`; lift it to a shared module and call from both `chat.join` and `chat.send` clauses). Add a regression test that asserts a third player cannot join `dm:A:B`.
2. **Bump cowboy/cowlib** (H4) and re-run `rebar3 audit` until 0 advisories. Add a CI gate so future regressions show up in PRs.
3. **Cap HTTP body size** (H2). Either configure `nova_request_plugin` with a `max_body_length` option (add upstream if missing) or wrap `read_body` locally. 1 MB is a safe default for everything except `put_save`/`put_storage` (already capped at 256 KB) and `iap` (small).
4. **Cache `world.list`** (H3) in `asobi_world_lobby_server` with a ~500 ms TTL.
5. **Hash the auth-cache key** (M1) — one-line change, high payoff.
6. **Decide on the ban story** (M4): either implement the check in the auth plugin or remove the column.
7. **Tighten the smaller M/L items** as a single hardening PR: matchmaker properties cap, metadata cap, `put_storage` size cap, httpc TLS options, `list_to_atom` length bound, idle-auth ceiling.
8. **Document H1 in `guides/security-known-limitations.md`** until the fix ships, so external consumers don't get surprised.

**Residual risk after the above**: low. The codebase is well-structured, has good defence-in-depth on the WS path (rate limits, payload caps, idle-auth, try/catch envelope), and the cryptography I read (Apple JWS, Google JWT, password hashing, session tokens) is implemented correctly. The remaining surface is operator-facing config and dependency hygiene, both of which CI can keep honest if H4's audit gate is enforced.
