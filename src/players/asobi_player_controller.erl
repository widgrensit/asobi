-module(asobi_player_controller).

-export([show/1, update/1, erase_self/1]).

-include_lib("kernel/include/logger.hrl").

-spec show(cowboy_req:req()) -> {json, map()} | {asobi_error, asobi_error:code()}.
show(#{bindings := #{~"id" := PlayerId}} = _Req) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} ->
            {json, sanitize(Player)};
        {error, not_found} ->
            {asobi_error, ~"player.not_found"}
    end.

-spec update(cowboy_req:req()) ->
    {json, map()} | {json, integer(), map(), map()} | {asobi_error, asobi_error:code()}.
update(
    #{bindings := #{~"id" := PlayerId}, json := Params, auth_data := #{player_id := AuthId}} = _Req
) when is_map(Params) ->
    case PlayerId =:= AuthId of
        false ->
            {asobi_error, ~"forbidden"};
        true ->
            case asobi_repo:get(asobi_player, PlayerId) of
                {ok, Player} ->
                    CS = asobi_player:update_changeset(Player, Params),
                    case asobi_repo:update(CS) of
                        {ok, Updated} ->
                            {json, sanitize(Updated)};
                        {error, CS1} ->
                            %% `errors` keeps its top-level place for form UIs
                            %% and doubles as the object's `details`.
                            asobi_error:legacy(~"validation_failed", #{
                                errors => format_errors(CS1)
                            })
                    end;
                {error, not_found} ->
                    {asobi_error, ~"player.not_found"}
            end
    end.

%% POST /api/v1/players/me/erase - the caller erases their own account.
%%
%% Apple's App Store review guideline 5.1.1(v) has required in-app account
%% deletion from any app that offers account creation since June 2022, Google
%% Play asks the same, and GDPR Art. 17 is the second leg. A game backend that
%% can only delete an account through an operator secret cannot ship to a phone,
%% so this is a shipping gate rather than a convenience - which is also why it
%% is not a guest-only route. A guest is simply the case with no credential to
%% confirm (asobi#419).
%%
%% The subject is always the caller: the id comes from `auth_data` and from
%% nowhere else, so there is no id to tamper with. Erasing somebody else stays
%% behind the ops plane's `erasure` capability, which is the real asymmetry
%% between the two routes.
-spec erase_self(cowboy_req:req()) ->
    {json, integer(), map(), map()} | {asobi_error, asobi_error:code()}.
erase_self(#{auth_data := #{player_id := PlayerId}} = Req) when is_binary(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} ->
            Hash = maps:get(hashed_password, Player, undefined),
            %% Each code is a literal at its return site, which is what stops a
            %% computed string from ever becoming one - asobi_error_contract_tests
            %% enforces it.
            case confirmed(Hash, Req) of
                ok -> erase(PlayerId, Hash);
                wrong_password -> {asobi_error, ~"auth.invalid_credentials"};
                no_password_given -> {asobi_error, ~"missing_field"}
            end;
        {error, not_found} ->
            {asobi_error, ~"player.not_found"};
        {error, _} ->
            {asobi_error, ~"internal"}
    end;
erase_self(_Req) ->
    {asobi_error, ~"unauthenticated"}.

%% Re-authentication, because a session token is a weaker thing to destroy an
%% account with than the password that made it. An account with no password has
%% nothing to echo - a guest authenticates with a device secret, a provider-only
%% account with an id token, and neither is something the client can re-present
%% here - so those pass on the session alone. That is the same bar their sign-in
%% already clears, not a hole: the credential that could erase them is the one
%% that could impersonate them, which was already true.
-spec confirmed(binary() | undefined, cowboy_req:req()) ->
    ok | wrong_password | no_password_given.
confirmed(undefined, _Req) ->
    ok;
confirmed(Hash, #{json := #{~"password" := Password}}) when is_binary(Password) ->
    case nova_auth_password:verify(Password, Hash) of
        true -> ok;
        false -> wrong_password
    end;
confirmed(_Hash, _Req) ->
    no_password_given.

%% One transaction over the re-check, the delete and the audit row, and the
%% in-memory eviction only once it has committed.
%%
%% `FOR UPDATE` before the re-read, not a plain select: `BEGIN` here is READ
%% COMMITTED and the delete predicates on id, not on the credential, so without
%% the lock a password change (or a guest upgrade) committing between the
%% confirmation and the delete would be erased anyway - handing its caller fresh
%% tokens for a player that no longer exists. Under the lock the writer either
%% goes first, and the hash no longer matches what was confirmed, or waits and
%% finds nothing to change.
-spec erase(binary(), binary() | undefined) ->
    {json, integer(), map(), map()} | {asobi_error, asobi_error:code()}.
erase(PlayerId, ConfirmedHash) ->
    Fun = fun() ->
        case locked_hash(PlayerId) of
            {ok, ConfirmedHash} ->
                ok = asobi_player_erase:steps(PlayerId),
                %% Inside the transaction and strict, the way
                %% `asobi_player_erase:erase_txn/2` writes the operator's row:
                %% the data is gone by definition, so a failed audit insert must
                %% roll the erasure back rather than leave it unrecorded.
                asobi_ops_audit:record_strict(
                    asobi_ops_auth:subject_actor(PlayerId),
                    ~"players.erase",
                    {~"player", PlayerId},
                    {ok, [PlayerId], []}
                );
            {ok, _Changed} ->
                {error, credentials_changed};
            {error, Reason} ->
                {error, {lookup_failed, Reason}}
        end
    end,
    try asobi_repo:transaction(Fun) of
        ok ->
            after_commit(PlayerId),
            ?LOG_INFO(#{event => player_self_erased, player_id => PlayerId}),
            {json, 200, #{}, #{deleted => true}};
        {error, credentials_changed} ->
            {asobi_error, ~"player.credentials_changed"};
        Other ->
            ?LOG_WARNING(#{
                event => player_self_erase_failed, player_id => PlayerId, result => Other
            }),
            {asobi_error, ~"player.erase_failed"}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                event => player_self_erase_rolled_back,
                player_id => PlayerId,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {asobi_error, ~"player.erase_failed"}
    end.

-spec locked_hash(binary()) -> {ok, binary() | undefined} | {error, term()}.
locked_hash(PlayerId) ->
    Q = kura_query:lock(
        kura_query:where(kura_query:from(asobi_player), {id, PlayerId}), ~"FOR UPDATE"
    ),
    case asobi_repo:all(Q) of
        {ok, [Player]} -> {ok, maps:get(hashed_password, Player, undefined)};
        {ok, []} -> {error, not_found};
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

%% The rows are already committed away, so a failure here must be logged and
%% retried by hand, never turned into a 500 that tells the caller nothing
%% happened. It cannot sit in the `try ... of` body either: an exception raised
%% there escapes the `catch` (the trap `asobi_oauth_controller` documents), so a
%% gen_server timeout evicting the auth cache would 500 an erasure that had
%% already committed, and log nothing.
-spec after_commit(binary()) -> ok.
after_commit(PlayerId) ->
    try
        asobi_player_erase:after_commit(PlayerId)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                event => player_self_erase_after_commit_failed,
                player_id => PlayerId,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% Positive whitelist: only fields safe for any authenticated viewer.
%% Never expose `hashed_password` (or any future credential fields).
sanitize(Player) ->
    maps:with(
        [id, username, display_name, avatar_url, metadata, inserted_at, updated_at],
        Player
    ).

format_errors(CS) ->
    kura_changeset:traverse_errors(CS, fun(_Field, Msg) -> Msg end).
