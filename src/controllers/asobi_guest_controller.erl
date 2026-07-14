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

-export([authenticate/1, upgrade/1]).

-ifdef(TEST).
-export([make_verifier/1, verify/2, decode_secret/1, valid_device_id/1]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-define(PROVIDER, ~"guest").
-define(MIN_SECRET_BYTES, 32).
%% Upper bounds on unauthenticated input: cap the HMAC work per request and keep
%% the device id within the VARCHAR(255) column. Without these a client can send
%% a multi-megabyte secret that is base64-decoded and HMAC'd on every call.
-define(MAX_SECRET_BYTES, 128).
-define(MAX_SECRET_B64_BYTES, 1024).
-define(MAX_DEVICE_ID_BYTES, 255).

-spec authenticate(cowboy_req:req()) -> {json, integer(), map(), map()}.
authenticate(#{json := #{~"device_id" := DeviceId, ~"device_secret" := Secret}} = _Req) when
    is_binary(DeviceId), is_binary(Secret)
->
    case guest_enabled() of
        false ->
            {json, 404, #{}, #{error => ~"guest_auth_disabled"}};
        true ->
            case decode_secret(Secret) of
                {ok, SecretBin} ->
                    case valid_device_id(DeviceId) of
                        true -> resolve(DeviceId, SecretBin);
                        false -> {json, 400, #{}, #{error => ~"invalid_device_id"}}
                    end;
                error ->
                    {json, 400, #{}, #{error => ~"weak_device_secret"}}
            end
    end;
authenticate(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

%% POST /api/v1/auth/guest/upgrade - claim a guest account with real
%% credentials. Authenticated as the guest (auth_data from the resumed token,
%% so it can only upgrade the caller's own player); revokes the device verifier
%% so the device secret can no longer log into the now-claimed account.
-spec upgrade(cowboy_req:req()) -> {json, integer(), map(), map()}.
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
                false -> {json, 409, #{}, #{error => ~"not_an_unclaimed_guest"}}
            end;
        {error, _} ->
            {json, 404, #{}, #{error => ~"player_not_found"}}
    end;
upgrade(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

-spec do_upgrade(map(), binary(), binary(), binary()) -> {json, integer(), map(), map()}.
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
            %% means the old (possibly attacker-held) tokens stop working.
            _ = nova_auth_refresh:revoke_all(asobi_auth, PlayerId),
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

-spec resolve(binary(), binary()) -> {json, integer(), map(), map()}.
resolve(DeviceId, SecretBin) ->
    case find_identity(DeviceId) of
        {ok, Identity} ->
            resume(Identity, SecretBin);
        {error, not_found} ->
            create(DeviceId, SecretBin)
    end.

-spec resume(map(), binary()) -> {json, integer(), map(), map()}.
resume(Identity, SecretBin) ->
    Meta = maps:get(provider_metadata, Identity, #{}),
    case maps:get(~"revoked", Meta, false) of
        true ->
            {json, 401, #{}, #{error => ~"guest_revoked"}};
        _ ->
            case verify(SecretBin, Meta) of
                true ->
                    issue_for_player(maps:get(player_id, Identity));
                false ->
                    %% Wrong secret for a known device: reject. Never create a
                    %% second player, never overwrite the stored verifier.
                    {json, 401, #{}, #{error => ~"invalid_device_secret"}}
            end
    end.

-spec create(binary(), binary()) -> {json, integer(), map(), map()}.
create(DeviceId, SecretBin) ->
    %% Row-spam defence (asobi#157): a global throughput bound (caps total
    %% guest-creates regardless of source IP - the per-IP auth limiter can't),
    %% plus a soft ceiling on total unlinked guests. Both fail closed.
    %%
    %% The global limiter is one shared window: it stops a botnet a per-IP limit
    %% can't, but a single abuser can saturate it and deny guest signup to
    %% everyone. That is an availability tradeoff, so log capacity events - a
    %% sustained stream is the signal to distinguish an attack from real growth.
    case global_create_allowed() andalso within_unlinked_cap() of
        false ->
            ?LOG_WARNING(#{event => guest_capacity_reached}),
            {json, 503, #{}, #{error => ~"guest_capacity_reached"}};
        true ->
            insert_player_and_identity(DeviceId, SecretBin)
    end.

-spec insert_player_and_identity(binary(), binary()) -> {json, integer(), map(), map()}.
insert_player_and_identity(DeviceId, SecretBin) ->
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
                    {json, 409, #{}, #{error => ~"device_already_registered"}}
            end;
        {error, _} ->
            {json, 500, #{}, #{error => ~"guest_create_failed"}}
    end.

-spec issue_for_player(binary()) -> {json, integer(), map(), map()}.
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
                    {json, 401, #{}, #{error => ~"guest_upgraded"}}
            end;
        {error, _} ->
            {json, 500, #{}, #{error => ~"guest_player_missing"}}
    end.

%% --- Verifier (salted + peppered keyed HMAC; secret never stored) ---

-spec make_verifier(binary()) -> map().
make_verifier(SecretBin) ->
    Salt = crypto:strong_rand_bytes(16),
    KeyId = current_key_id(),
    Mac = crypto:mac(hmac, sha256, pepper(KeyId), <<Salt/binary, SecretBin/binary>>),
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
    application:get_env(asobi, guest_verifier_key_id, ~"v1").

-spec pepper(binary()) -> binary() | undefined.
pepper(KeyId) ->
    case application:get_env(asobi, guest_verifier_pepper, undefined) of
        Peppers when is_map(Peppers) -> maps:get(KeyId, Peppers, undefined);
        Bin when is_binary(Bin), byte_size(Bin) >= 32 -> Bin;
        _ -> undefined
    end.

-spec global_create_allowed() -> boolean().
global_create_allowed() ->
    case seki:check(asobi_guest_global_limiter, ~"global") of
        {allow, _} -> true;
        {deny, _} -> false
    end.

-spec within_unlinked_cap() -> boolean().
within_unlinked_cap() ->
    %% Finite by default (fail-closed): the ceiling must not be off by default.
    %% Operators raise it or set `infinity` deliberately. The count is read from
    %% a short-TTL cache (asobi_guest_reaper) rather than COUNT-ing the whole
    %% guest table on every unauthenticated create, so the cap is advisory - a
    %% soft ceiling that can overshoot by up to (TTL x create-rate), not exact.
    case application:get_env(asobi, guest_unlinked_cap, 100000) of
        infinity ->
            true;
        Cap when is_integer(Cap) ->
            case asobi_guest_reaper:cached_unlinked_count() of
                N when is_integer(N) -> N < Cap;
                unknown -> false
            end
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
    Suffix = binary:part(asobi_id:generate(), 0, 12),
    <<"guest_", Suffix/binary>>.
