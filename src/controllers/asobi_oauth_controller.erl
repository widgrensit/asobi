-module(asobi_oauth_controller).

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-export([authenticate/1, link/1, unlink/1]).

-ifdef(TEST).
-export([create_player_with_identity/2, validate_oidc_token/2]).
-endif.

-define(MAX_USERNAME_ATTEMPTS, 3).

%% POST /api/v1/auth/oauth
%% Body: {"provider": "google", "token": "<id_token>"}
-spec authenticate(cowboy_req:req()) -> {json, integer(), map(), map()}.
authenticate(#{json := #{~"provider" := Provider, ~"token" := Token}} = _Req) when
    is_binary(Provider), is_binary(Token)
->
    case validate_provider_token(Provider, Token) of
        {ok, Claims} ->
            ProviderUid = maps:get(provider_uid, Claims),
            case find_identity(Provider, ProviderUid) of
                {ok, Identity} ->
                    login_existing_player(Identity);
                {error, not_found} ->
                    case asobi_registration:check(oauth) of
                        {deny, Reason} -> {json, 403, #{}, #{error => Reason}};
                        ok -> create_player_with_identity(Provider, Claims)
                    end
            end;
        {error, Reason} ->
            {json, 401, #{}, #{error => Reason}}
    end;
authenticate(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

%% POST /api/v1/auth/link
%% Body: {"provider": "discord", "token": "<id_token>"}
-spec link(cowboy_req:req()) -> {json, integer(), map(), map()}.
link(
    #{json := #{~"provider" := Provider, ~"token" := Token}, auth_data := #{player_id := PlayerId}} =
        _Req
) when is_binary(Provider), is_binary(Token), is_binary(PlayerId) ->
    case validate_provider_token(Provider, Token) of
        {ok, Claims} ->
            ProviderUid = maps:get(provider_uid, Claims),
            case find_identity(Provider, ProviderUid) of
                {ok, _} ->
                    {json, 409, #{}, #{error => ~"provider_already_linked"}};
                {error, not_found} ->
                    create_identity(PlayerId, Provider, Claims)
            end;
        {error, Reason} ->
            {json, 401, #{}, #{error => Reason}}
    end;
link(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

%% DELETE /api/v1/auth/unlink?provider=discord
-spec unlink(cowboy_req:req()) -> {json, integer(), map(), map()}.
unlink(
    #{parsed_qs := #{~"provider" := Provider}, auth_data := #{player_id := PlayerId}} = _Req
) when is_binary(Provider), is_binary(PlayerId) ->
    case find_player_identity(PlayerId, Provider) of
        {ok, Identity} ->
            case has_other_auth(PlayerId, Provider) of
                true ->
                    _ = asobi_repo:delete(asobi_player_identity, Identity),
                    {json, 200, #{}, #{success => true}};
                false ->
                    {json, 422, #{}, #{error => ~"cannot_remove_last_auth_method"}}
            end;
        {error, not_found} ->
            {json, 404, #{}, #{error => ~"identity_not_found"}}
    end;
unlink(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

%% --- Internal ---

-spec validate_provider_token(binary(), binary()) -> {ok, map()} | {error, binary()}.
validate_provider_token(~"steam", Ticket) ->
    asobi_steam:validate_ticket(Ticket);
validate_provider_token(Provider, Token) ->
    case provider_to_atom(Provider) of
        unknown ->
            {error, ~"unsupported_provider"};
        ProviderAtom ->
            case validate_oidc_token(ProviderAtom, Token) of
                {ok, Actor} when is_map(Actor) ->
                    ActorClaims = maps:get(claims, Actor, Actor),
                    case ActorClaims of
                        Claims when is_map(Claims) -> {ok, normalize_claims(Provider, Claims)};
                        _ -> {error, ~"invalid_claims"}
                    end;
                {error, _Reason} ->
                    {error, ~"invalid_token"}
            end
    end.

-spec validate_oidc_token(atom(), binary()) -> {ok, map()} | {error, term()}.
validate_oidc_token(ProviderAtom, Token) ->
    %% This route is unauthenticated (POST /api/v1/auth/oauth, security
    %% => false), so a dependency crash on a malformed or malicious token
    %% must never reach cowboy uncaught - that would be an unbounded
    %% 500/log-write generator with no rate limit on this route. Only
    %% class/reason are logged, never the stacktrace: its arg list can
    %% include the raw token, which - unlike an opaque session token -
    %% embeds the signing input an attacker (or a curious operator
    %% reading logs) could use to reconstruct a still-valid credential.
    %% The case lives INSIDE the try's protected body, not in a `try ... of`
    %% clause list: a value that matches none of the `of` clauses raises
    %% try_clause OUTSIDE the scope the accompanying catch covers (verified -
    %% it is not caught by the same try/catch), which would silently
    %% reopen exactly the crash-to-cowboy gap this fix exists to close.
    %% Inside the body, nova_auth_oidc_jwt:validate_token/3 returning
    %% anything outside its own declared {ok, actor()} | {error, term()}
    %% contract raises case_clause, which the catch below does cover -
    %% no explicit catch-all needed (dialyzer proves the dependency's
    %% current behavior never produces one; a future contract-breaking
    %% change would still be a safe catch, not a crash).
    try
        case nova_auth_oidc_jwt:validate_token(asobi_oidc_config, ProviderAtom, Token) of
            {ok, Result} when is_map(Result) -> {ok, Result};
            {error, _} = Err -> Err
        end
    catch
        Class:Reason ->
            ?LOG_ERROR(#{
                msg => ~"oidc token validation crashed",
                provider => ProviderAtom,
                class => Class,
                reason => Reason
            }),
            {error, validation_failed}
    end.

-spec normalize_claims(binary(), map()) -> map().
normalize_claims(_Provider, Claims) ->
    #{
        provider_uid => maps:get(provider_uid, Claims, maps:get(~"sub", Claims, undefined)),
        provider_email => maps:get(provider_email, Claims, maps:get(~"email", Claims, undefined)),
        provider_display_name =>
            maps:get(
                provider_display_name, Claims, maps:get(~"name", Claims, undefined)
            )
    }.

-spec find_identity(binary(), binary()) -> {ok, map()} | {error, not_found}.
find_identity(Provider, ProviderUid) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {provider, Provider}),
        {provider_uid, ProviderUid}
    ),
    case asobi_repo:all(Q) of
        {ok, [Identity]} -> {ok, Identity};
        _ -> {error, not_found}
    end.

-spec find_player_identity(binary(), binary()) -> {ok, map()} | {error, not_found}.
find_player_identity(PlayerId, Provider) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
        {provider, Provider}
    ),
    case asobi_repo:all(Q) of
        {ok, [Identity]} -> {ok, Identity};
        _ -> {error, not_found}
    end.

-spec login_existing_player(map()) -> {json, integer(), map(), map()}.
login_existing_player(Identity) ->
    PlayerId = maps:get(player_id, Identity),
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} ->
            asobi_auth_tokens:issue(Player, 200, #{username => maps:get(username, Player)});
        {error, _} ->
            {json, 500, #{}, #{error => ~"player_not_found"}}
    end.

-spec create_player_with_identity(binary(), map()) -> {json, integer(), map(), map()}.
create_player_with_identity(Provider, Claims) ->
    create_player_with_identity(Provider, Claims, 1).

-spec create_player_with_identity(binary(), map(), pos_integer()) ->
    {json, integer(), map(), map()}.
create_player_with_identity(Provider, Claims, Attempt) ->
    ProviderUid = maps:get(provider_uid, Claims),
    DisplayName = maps:get(provider_display_name, Claims, undefined),
    Username = generate_username(Provider, ProviderUid),
    PlayerParams = #{
        username => Username,
        display_name => maybe_value(DisplayName, Username)
    },
    CS = kura_changeset:cast(asobi_player, #{}, PlayerParams, [username, display_name]),
    CS1 = kura_changeset:validate_required(CS, [username]),
    %% Player insert and identity insert happen in one transaction: on
    %% identity-insert failure (concurrent first-sign-in for the same
    %% {provider, provider_uid} won the race), the DB itself rolls the player
    %% row back instead of a separate compensating delete that could fail
    %% silently and leave exactly the orphan this is closing (found in
    %% security review of the delete-based version).
    Result =
        try
            asobi_repo:transaction(fun() ->
                case asobi_repo:insert(CS1) of
                    {ok, Player} ->
                        PlayerId = maps:get(id, Player),
                        case insert_identity(PlayerId, Provider, Claims) of
                            {ok, _Identity} ->
                                _ = init_player_stats(PlayerId),
                                {ok, Player};
                            {error, _} = IErr ->
                                throw({rollback, identity, IErr})
                        end;
                    {error, _} = PErr ->
                        throw({rollback, player, PErr})
                end
            end)
        catch
            throw:{rollback, identity, CaughtIErr} -> {error, identity, CaughtIErr};
            throw:{rollback, player, CaughtPErr} -> {error, player, CaughtPErr}
        end,
    case Result of
        {ok, Player} when is_map(Player) ->
            asobi_auth_tokens:issue(Player, 200, #{username => Username, created => true});
        {error, identity, {error, #kura_changeset{errors = IErrors}}} ->
            case asobi_auth_error:provider_uid_taken(IErrors) of
                true ->
                    {json, 409, #{}, #{error => ~"already_registering"}};
                false ->
                    %% A real failure (e.g. a provider claim over a column
                    %% limit), not the identity race - do not log Claims,
                    %% which can carry provider_email.
                    ?LOG_ERROR(#{
                        event => oauth_identity_insert_failed,
                        provider => Provider,
                        errors => IErrors
                    }),
                    {json, 500, #{}, #{error => ~"registration_failed"}}
            end;
        {error, identity, IErr} ->
            ?LOG_ERROR(#{
                event => oauth_identity_insert_failed, provider => Provider, reason => IErr
            }),
            {json, 500, #{}, #{error => ~"registration_failed"}};
        {error, player, {error, #kura_changeset{errors = Errors}}} when
            Attempt < ?MAX_USERNAME_ATTEMPTS
        ->
            case asobi_auth_error:username_taken(Errors) of
                true ->
                    ?LOG_WARNING(#{
                        event => oauth_username_collision, provider => Provider, attempt => Attempt
                    }),
                    create_player_with_identity(Provider, Claims, Attempt + 1);
                false ->
                    {json, 500, #{}, #{error => ~"registration_failed"}}
            end;
        {error, player, _} ->
            {json, 500, #{}, #{error => ~"registration_failed"}}
    end.

-spec create_identity(binary(), binary(), map()) -> {json, integer(), map(), map()}.
create_identity(PlayerId, Provider, Claims) ->
    case insert_identity(PlayerId, Provider, Claims) of
        {ok, Identity} ->
            {json, 200, #{}, #{
                provider => Provider,
                provider_uid => maps:get(provider_uid, Identity),
                linked => true
            }};
        {error, _} ->
            {json, 500, #{}, #{error => ~"link_failed"}}
    end.

-spec insert_identity(binary(), binary(), map()) -> {ok, map()} | {error, term()}.
insert_identity(PlayerId, Provider, Claims) ->
    Params = #{
        player_id => PlayerId,
        provider => Provider,
        provider_uid => maps:get(provider_uid, Claims),
        provider_email => maps:get(provider_email, Claims, undefined),
        provider_display_name => maps:get(provider_display_name, Claims, undefined)
    },
    CS = asobi_player_identity:changeset(#{}, Params),
    asobi_repo:insert(CS).

-spec has_other_auth(binary(), binary()) -> boolean().
has_other_auth(PlayerId, ExcludeProvider) ->
    HasPassword =
        case asobi_repo:get(asobi_player, PlayerId) of
            {ok, Player} -> maps:get(hashed_password, Player, undefined) =/= undefined;
            _ -> false
        end,
    Q = kura_query:where(kura_query:from(asobi_player_identity), {player_id, PlayerId}),
    OtherProviders =
        case asobi_repo:all(Q) of
            {ok, Identities} ->
                [I || I <- Identities, maps:get(provider, I) =/= ExcludeProvider];
            _ ->
                []
        end,
    HasPassword orelse length(OtherProviders) > 0.

-spec generate_username(binary(), binary()) -> binary().
generate_username(Provider, ProviderUid) ->
    %% NOT rand:uniform/1: non-crypto and only ~13 bits of entropy.
    Short = binary:part(ProviderUid, 0, min(8, byte_size(ProviderUid))),
    Rand = asobi_id:rand_suffix(4),
    <<Provider/binary, "_", Short/binary, "_", Rand/binary>>.

-spec maybe_value(term(), term()) -> term().
maybe_value(undefined, Default) -> Default;
maybe_value(Value, _Default) -> Value.

-spec init_player_stats(binary()) -> ok.
init_player_stats(PlayerId) ->
    CS = kura_changeset:cast(asobi_player_stats, #{}, #{player_id => PlayerId}, [player_id]),
    %% F-25: log insert errors instead of silently dropping them.
    case asobi_repo:insert(CS) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logger:warning(#{
                msg => ~"player_stats_init_failed",
                player_id => PlayerId,
                reason => Reason
            }),
            ok
    end.

-spec provider_to_atom(binary()) -> atom().
provider_to_atom(~"google") -> google;
provider_to_atom(~"apple") -> apple;
provider_to_atom(~"microsoft") -> microsoft;
provider_to_atom(~"discord") -> discord;
provider_to_atom(_) -> unknown.
