-module(asobi_guest_controller).

%% Anonymous/guest auth, modelled as a "guest" provider identity parallel to
%% the OAuth providers (asobi_oauth_controller). A client presents a
%% device-generated {device_id, device_secret}; the server creates a player on
%% first presentation and resumes the SAME player on later presentations. The
%% secret is verified against a salted+peppered HMAC stored in the identity's
%% provider_metadata (see provider=guest metadata: salt/key_id/verifier/revoked,
%% base64) - the secret itself is never stored or logged.
%%
%% Opt-in: disabled unless `guest_auth` is true AND a `guest_verifier_pepper`
%% is configured; both missing/false fail closed. Upgrade to a real account:
%% POST /auth/guest/upgrade (username+password, revokes the device verifier) or
%% the existing /auth/link path (OAuth). Guardian + beam-security-reviewer gate.
%%
%% Deleting a guest is not here: it is `DELETE /api/v1/players/me`
%% (`asobi_player_controller:erase_self/1`), because a player erasing their own
%% account is not a guest-shaped problem. A guest is just the case with no
%% credential to re-confirm (asobi#419).

-export([authenticate/1, upgrade/1]).

-ifdef(TEST).
-export([make_verifier/1, verify/2, decode_secret/1, valid_device_id/1, create/2, cap_gate/2]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-type response() ::
    {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.

-define(PROVIDER, ~"guest").
-define(MIN_SECRET_BYTES, 32).
%% Upper bounds on unauthenticated input: cap the HMAC work per request and keep
%% the device id within the VARCHAR(255) column. Without these a client can send
%% a multi-megabyte secret that is base64-decoded and HMAC'd on every call.
-define(MAX_SECRET_BYTES, 128).
-define(MAX_SECRET_B64_BYTES, 1024).
-define(MAX_DEVICE_ID_BYTES, 255).
-define(MAX_USERNAME_ATTEMPTS, 3).
-define(DEFAULT_UNLINKED_CAP, 100000).
-define(RATE_LIMITED_HINT_SECONDS, 5).

-spec authenticate(cowboy_req:req()) -> response().
authenticate(#{json := #{~"device_id" := DeviceId, ~"device_secret" := Secret}} = _Req) when
    is_binary(DeviceId), is_binary(Secret)
->
    case guest_enabled() of
        false ->
            {asobi_error, ~"guest.disabled"};
        true ->
            case decode_secret(Secret) of
                {ok, SecretBin} ->
                    case valid_device_id(DeviceId) of
                        true -> resolve(DeviceId, SecretBin);
                        false -> {asobi_error, ~"guest.invalid_device_id"}
                    end;
                error ->
                    {asobi_error, ~"guest.weak_device_secret"}
            end
    end;
authenticate(_Req) ->
    {asobi_error, ~"missing_field"}.

%% POST /api/v1/auth/guest/upgrade - claim a guest account with real
%% credentials. Authenticated as the guest (auth_data from the resumed token,
%% so it can only upgrade the caller's own player); revokes the device verifier
%% so the device secret can no longer log into the now-claimed account.
-spec upgrade(cowboy_req:req()) -> response().
upgrade(
    #{
        json := #{~"username" := Username, ~"password" := Password},
        auth_data := #{player_id := PlayerId}
    } = _Req
) when is_binary(Username), is_binary(Password), is_binary(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} ->
            %% Only an unclaimed guest may claim an account here. This endpoint
            %% casts `username` (which the normal self-service update excludes),
            %% so gate on the real invariant: the caller must own a `guest`
            %% identity AND have no password. Gating on password-absence alone
            %% would let a passwordless OAuth-only account use this path to set a
            %% password and rename itself - a side door around update_changeset.
            case is_unclaimed_guest(Player, PlayerId) of
                true -> do_upgrade(Player, PlayerId, Username, Password);
                false -> {asobi_error, ~"guest.not_unclaimed"}
            end;
        {error, _} ->
            {asobi_error, ~"player.not_found"}
    end;
upgrade(_Req) ->
    {asobi_error, ~"missing_field"}.

-spec do_upgrade(map(), binary(), binary(), binary()) -> response().
do_upgrade(Player, PlayerId, Username, Password) ->
    CS = asobi_player:registration_changeset(Player, #{
        username => Username,
        password => Password,
        display_name => maps:get(display_name, Player, Username)
    }),
    case asobi_repo:update(CS) of
        {ok, Updated} ->
            _ = delete_guest_identity(PlayerId),
            %% Revoke every token issued to this player before the claim: a
            %% stolen device secret has already minted an access+refresh pair,
            %% and upgrade is exactly the "my device was compromised" moment.
            %% Killing the whole family first, then issuing a fresh pair below,
            %% means the old (possibly attacker-held) tokens stop working -
            %% but revoke_all/2 only deletes the DB rows, and asobi_auth_cache
            %% serves a cached positive for up to auth_cache_ttl_ms after a
            %% token's DB row is gone (asobi#215). Evict this player's cache
            %% entries too so this mass revoke actually takes effect
            %% immediately, not up to 60s later - a stale cache entry is
            %% exactly the case this comment's security intent depends on not
            %% existing. revoke_player/1, not clear/0: this endpoint is
            %% reachable by any authenticated guest, and a full-table clear
            %% would let repeated upgrades evict every other player's cached
            %% session node-wide.
            _ = nova_auth_refresh:revoke_all(asobi_auth, PlayerId),
            _ = asobi_auth_cache:revoke_player(PlayerId),
            asobi_auth_tokens:issue(Updated, 200, #{username => Username, upgraded => true});
        {error, #kura_changeset{} = ECS} ->
            asobi_auth_error:from_changeset_fields(
                kura_changeset:traverse_errors(ECS, fun(_F, M) -> M end)
            )
    end.

%% On upgrade the account is claimed, so remove the guest identity entirely: the
%% device secret can no longer map to any player, and the account stops counting
%% against the unlinked-guest cap. The resume path's claimed-account check is the
%% belt-and-suspenders guarantee if this delete ever fails.
-spec delete_guest_identity(binary()) -> ok.
delete_guest_identity(PlayerId) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        {provider, ?PROVIDER}
    ),
    case asobi_repo:all(Q) of
        {ok, [Identity]} ->
            _ = asobi_repo:delete(asobi_player_identity, Identity),
            ok;
        _ ->
            ok
    end.

%% A player may be upgraded here only if it is an actual guest: no password set
%% and it owns a `guest` provider identity. Both conditions matter - a
%% passwordless OAuth account satisfies the first but not the second.
-spec is_unclaimed_guest(map(), binary()) -> boolean().
is_unclaimed_guest(Player, PlayerId) ->
    maps:get(hashed_password, Player, undefined) =:= undefined andalso
        has_guest_identity(PlayerId).

-spec has_guest_identity(binary()) -> boolean().
has_guest_identity(PlayerId) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        {provider, ?PROVIDER}
    ),
    case asobi_repo:all(Q) of
        {ok, [_ | _]} -> true;
        _ -> false
    end.

%% --- Create-or-resume (fail closed) ---

-spec resolve(binary(), binary()) -> response().
resolve(DeviceId, SecretBin) ->
    case find_identity(DeviceId) of
        {ok, Identity} ->
            resume(Identity, SecretBin);
        {error, not_found} ->
            create(DeviceId, SecretBin)
    end.

-spec resume(map(), binary()) -> response().
resume(Identity, SecretBin) ->
    Meta = maps:get(provider_metadata, Identity, #{}),
    case maps:get(~"revoked", Meta, false) of
        true ->
            {asobi_error, ~"guest.revoked"};
        _ ->
            case verify(SecretBin, Meta) of
                true ->
                    touch(Identity),
                    issue_for_player(maps:get(player_id, Identity));
                false ->
                    %% Wrong secret for a known device: reject. Never create a
                    %% second player, never overwrite the stored verifier.
                    {asobi_error, ~"guest.invalid_device_secret"}
            end
    end.

%% Record that this device was seen. `asobi_guest_reaper` keys retention on the
%% identity's `updated_at`, so without this a guest who plays every day still
%% looks exactly as stale as one that vanished after the first launch, and an
%% operator who sets `guest_reap_after` erases their active players.
%%
%% A bare `update_all` SET rather than a changeset update: it writes the one
%% column by id and so cannot round-trip - or clobber - the verifier in
%% `provider_metadata`. Failure is logged and ignored; a write that only
%% extends retention must never cost a player their login. The cost is one
%% single-row UPDATE per resume, which happens at session start, not per tick.
-spec touch(map()) -> ok.
touch(Identity) ->
    Q = kura_query:where(kura_query:from(asobi_player_identity), {id, maps:get(id, Identity)}),
    case asobi_repo:update_all(Q, #{updated_at => calendar:universal_time()}) of
        {ok, _} ->
            ok;
        Other ->
            ?LOG_WARNING(#{
                event => guest_touch_failed,
                player_id => maps:get(player_id, Identity, undefined),
                result => Other
            }),
            ok
    end.

-spec create(binary(), binary()) -> response().
create(DeviceId, SecretBin) ->
    %% Row-spam defence (asobi#157): a global throughput bound (caps total
    %% guest-creates regardless of source IP - the per-IP auth limiter can't),
    %% plus a soft ceiling on total unlinked guests. Both fail closed.
    %%
    %% The global limiter is one shared window: it stops a botnet a per-IP limit
    %% can't, but a single abuser can saturate it and deny guest signup to
    %% everyone. That is an availability tradeoff, so log capacity events - a
    %% sustained stream is the signal to distinguish an attack from real growth.
    case asobi_registration:check(guest) of
        {deny, Reason} ->
            asobi_auth_error:registration_denied(Reason);
        ok ->
            case create_gate() of
                allow ->
                    insert_player_and_identity(DeviceId, SecretBin);
                {deny, Report} ->
                    ?LOG_WARNING(Report#{event => guest_create_denied}),
                    denial(Report)
            end
    end.

%% The gate decides *why*; this is the only place a why becomes a code, so
%% every code is still a literal at its return site (asobi_error_contract_tests
%% enforces that, and it is the rule that keeps a computed string from ever
%% becoming one). The report that goes to the log and the object that goes to
%% the client are the same decision, so they cannot drift.
-spec denial(map()) -> response().
denial(#{reason := global_rate_limited}) ->
    %% Shaped like `m:asobi_rate_limit_plugin`'s own 429 - a `retry-after`
    %% header and a top-level `retry_after` beside the object's `details`, so an
    %% SDK backing off on the standard header backs off here too.
    %%
    %% A fixed hint, NOT the limiter's real remaining window. This bucket is
    %% keyed on one constant, so it is the whole node's guest-signup budget: the
    %% true figure would tell an unauthenticated caller exactly how long to
    %% sleep between single requests to hold it shut against every real player,
    %% which is the cheapest possible lockout and has been measured on this
    %% stack before (asobi_saas#249). The precise number stays in the
    %% `guest_create_denied` log line, where the operator needs it and an
    %% attacker cannot read it. The per-IP limiter may publish its real value
    %% because the attacker already owns that bucket; this one is shared.
    {json, 429, #{~"retry-after" => integer_to_binary(?RATE_LIMITED_HINT_SECONDS)},
        asobi_error:legacy_body(~"guest.rate_limited", #{
            ~"retry_after" => ?RATE_LIMITED_HINT_SECONDS
        })};
denial(#{reason := unlinked_cap_reached}) ->
    {asobi_error, ~"guest.capacity_reached"};
denial(#{reason := unlinked_count_unavailable}) ->
    {asobi_error, ~"guest.unavailable"}.

%% No catch-all clause, on purpose. Dialyzer proves this mapping total over
%% everything `create_gate/0` returns, so a fourth reason added later fails the
%% build rather than reaching production - a stronger backstop than a
%% fail-closed clause, which dialyzer would then report as unreachable anyway.

%% Three unrelated conditions refuse a create, and each is a different
%% operator problem. They used to share one code and one reason-less warning
%% (asobi#419), so a field report of "capacity reached" could not be diagnosed
%% from the node at all - and the most likely cause, a repo error while
%% counting, was reported as a deployment that is full when it was nowhere
%% near the cap. Fail closed either way, but say which one and log the numbers.
-spec create_gate() -> allow | {deny, map()}.
create_gate() ->
    case seki:check(asobi_guest_global_limiter, ~"global") of
        {allow, _} ->
            cap_gate(asobi_guest_reaper:cached_unlinked_count(), cap());
        {deny, #{retry_after := RetryAfterMs}} ->
            {deny, #{reason => global_rate_limited, retry_after_ms => RetryAfterMs}}
    end.

%% Finite by default (fail-closed): the ceiling must not be off by default.
%% Operators raise it or set `infinity` deliberately. The count is read from a
%% short-TTL cache (asobi_guest_reaper) rather than COUNT-ing the whole guest
%% table on every unauthenticated create, so the cap is advisory - a soft
%% ceiling that can overshoot by up to (TTL x create-rate), not exact.
%%
%% Split from the config and count reads so every branch - including the one
%% that only happens when the database is unreachable - is reachable from a
%% unit test.
-spec cap_gate(non_neg_integer() | unknown, non_neg_integer() | infinity) ->
    allow | {deny, map()}.
cap_gate(_Count, infinity) ->
    allow;
cap_gate(Count, Cap) when is_integer(Count), Count < Cap ->
    allow;
cap_gate(Count, Cap) when is_integer(Count) ->
    {deny, #{reason => unlinked_cap_reached, count => Count, cap => Cap}};
cap_gate(unknown, Cap) ->
    %% The count query failed. Still fail closed - an unbounded create path is
    %% the thing the cap exists to prevent - but this is "the node could not
    %% find out", not "the node is full", and an operator told the second goes
    %% looking for a ceiling that is nowhere near reached.
    {deny, #{reason => unlinked_count_unavailable, cap => Cap}}.

%% An unrecognised value used to fall through the `case` and crash every guest
%% create with a `case_clause`, which reads as a server fault rather than the
%% typo it is. Fall back to the default and say so.
-spec cap() -> non_neg_integer() | infinity.
cap() ->
    case application:get_env(asobi, guest_unlinked_cap, ?DEFAULT_UNLINKED_CAP) of
        infinity ->
            infinity;
        Cap when is_integer(Cap), Cap >= 0 ->
            Cap;
        Other ->
            ?LOG_WARNING(#{
                event => invalid_guest_unlinked_cap,
                value => Other,
                using => ?DEFAULT_UNLINKED_CAP
            }),
            ?DEFAULT_UNLINKED_CAP
    end.

-spec insert_player_and_identity(binary(), binary()) -> response().
insert_player_and_identity(DeviceId, SecretBin) ->
    insert_player_and_identity(DeviceId, SecretBin, 1).

-spec insert_player_and_identity(binary(), binary(), pos_integer()) -> response().
insert_player_and_identity(DeviceId, SecretBin, Attempt) ->
    Username = generate_username(),
    PlayerCS = kura_changeset:validate_required(
        kura_changeset:cast(asobi_player, #{}, #{username => Username}, [username]),
        [username]
    ),
    case asobi_repo:insert(PlayerCS) of
        {ok, Player} ->
            PlayerId = maps:get(id, Player),
            case insert_identity(PlayerId, DeviceId, SecretBin) of
                {ok, _Identity} ->
                    _ = asobi_player_stats:init(PlayerId),
                    asobi_auth_tokens:issue(Player, 200, #{
                        username => Username, created => true, guest => true
                    });
                {error, _} ->
                    %% Lost the unique {provider, device_id} race. Delete the
                    %% just-created player so a concurrent create can't leave an
                    %% orphan row.
                    _ = asobi_repo:delete(asobi_player, Player),
                    {asobi_error, ~"guest.device_already_registered"}
            end;
        {error, #kura_changeset{errors = Errors}} when Attempt < ?MAX_USERNAME_ATTEMPTS ->
            case asobi_auth_error:username_taken(Errors) of
                true ->
                    ?LOG_WARNING(#{
                        event => guest_username_collision, attempt => Attempt
                    }),
                    insert_player_and_identity(DeviceId, SecretBin, Attempt + 1);
                false ->
                    {asobi_error, ~"guest.create_failed"}
            end;
        {error, _} ->
            {asobi_error, ~"guest.create_failed"}
    end.

-spec issue_for_player(binary()) -> response().
issue_for_player(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} ->
            %% If the account was claimed (a password was set), the device
            %% secret must not resume it - independent of whether the verifier
            %% revoke persisted. Log in with the real credentials instead.
            case maps:get(hashed_password, Player, undefined) of
                undefined ->
                    asobi_auth_tokens:issue(Player, 200, #{
                        username => maps:get(username, Player), guest => true
                    });
                _ ->
                    {asobi_error, ~"guest.already_upgraded"}
            end;
        {error, _} ->
            {asobi_error, ~"internal"}
    end.

%% --- Verifier (salted + peppered keyed HMAC; secret never stored) ---

-spec make_verifier(binary()) -> map().
make_verifier(SecretBin) ->
    Salt = crypto:strong_rand_bytes(16),
    KeyId = current_key_id(),
    Pepper =
        case pepper(KeyId) of
            Key when is_binary(Key) -> Key;
            undefined -> error(guest_verifier_pepper_missing)
        end,
    Mac = crypto:mac(hmac, sha256, Pepper, <<Salt/binary, SecretBin/binary>>),
    #{
        ~"salt" => base64:encode(Salt),
        ~"key_id" => KeyId,
        ~"verifier" => base64:encode(Mac),
        ~"revoked" => false
    }.

-spec verify(binary(), map()) -> boolean().
verify(SecretBin, #{~"salt" := SaltB64, ~"key_id" := KeyId, ~"verifier" := VerB64}) ->
    case pepper(KeyId) of
        undefined ->
            false;
        Key ->
            Salt = base64:decode(SaltB64),
            Expected = crypto:mac(hmac, sha256, Key, <<Salt/binary, SecretBin/binary>>),
            crypto:hash_equals(Expected, base64:decode(VerB64))
    end;
verify(_SecretBin, _) ->
    false.

%% --- Identity persistence (reuses asobi_player_identity) ---

-spec find_identity(binary()) -> {ok, map()} | {error, not_found}.
find_identity(DeviceId) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {provider, ?PROVIDER}),
        {provider_uid, DeviceId}
    ),
    case asobi_repo:all(Q) of
        {ok, [Identity]} -> {ok, Identity};
        _ -> {error, not_found}
    end.

-spec insert_identity(binary(), binary(), binary()) -> {ok, map()} | {error, term()}.
insert_identity(PlayerId, DeviceId, SecretBin) ->
    Params = #{
        player_id => PlayerId,
        provider => ?PROVIDER,
        provider_uid => DeviceId,
        provider_metadata => make_verifier(SecretBin)
    },
    asobi_repo:insert(asobi_player_identity:changeset(#{}, Params)).

%% --- Config (opt-in, fail closed and loud) ---

-spec guest_enabled() -> boolean().
guest_enabled() ->
    case application:get_env(asobi, guest_auth, false) of
        true ->
            case pepper(current_key_id()) of
                undefined ->
                    ?LOG_WARNING(#{
                        event => guest_auth_misconfigured,
                        reason => missing_guest_verifier_pepper
                    }),
                    false;
                _ ->
                    true
            end;
        _ ->
            false
    end.

-spec current_key_id() -> binary().
current_key_id() ->
    case application:get_env(asobi, guest_verifier_key_id, ~"v1") of
        KeyId when is_binary(KeyId) -> KeyId;
        _ -> ~"v1"
    end.

-spec pepper(binary()) -> binary() | undefined.
pepper(KeyId) ->
    case application:get_env(asobi, guest_verifier_pepper, undefined) of
        Peppers when is_map(Peppers) ->
            case maps:get(KeyId, Peppers, undefined) of
                Bin when is_binary(Bin), byte_size(Bin) >= 32 -> Bin;
                _ -> undefined
            end;
        Bin when is_binary(Bin), byte_size(Bin) >= 32 -> Bin;
        _ ->
            undefined
    end.

%% --- Helpers ---

-spec valid_device_id(binary()) -> boolean().
valid_device_id(DeviceId) ->
    byte_size(DeviceId) > 0 andalso byte_size(DeviceId) =< ?MAX_DEVICE_ID_BYTES.

-spec decode_secret(binary()) -> {ok, binary()} | error.
decode_secret(B64) when byte_size(B64) =< ?MAX_SECRET_B64_BYTES ->
    try base64:decode(B64) of
        Bin when byte_size(Bin) >= ?MIN_SECRET_BYTES, byte_size(Bin) =< ?MAX_SECRET_BYTES ->
            {ok, Bin};
        _ ->
            error
    catch
        _:_ -> error
    end;
decode_secret(_B64) ->
    error.

-spec generate_username() -> binary().
generate_username() ->
    Suffix = asobi_id:rand_suffix(8),
    <<"guest_", Suffix/binary>>.
