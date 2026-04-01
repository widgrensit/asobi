-module(asobi_oauth_controller).

-export([authenticate/1, link/1, unlink/1]).

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
                    create_player_with_identity(Provider, Claims)
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
            try nova_auth_oidc_jwt:validate_token(asobi_oidc_config, ProviderAtom, Token) of
                {ok, Actor} ->
                    ActorClaims = maps:get(claims, Actor, Actor),
                    case ActorClaims of
                        Claims when is_map(Claims) -> {ok, normalize_claims(Provider, Claims)};
                        _ -> {error, ~"invalid_claims"}
                    end;
                {error, _Reason} ->
                    {error, ~"invalid_token"}
            catch
                _:_ -> {error, ~"invalid_token"}
            end
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
            {ok, Token} = nova_auth_session:generate_session_token(asobi_auth, Player),
            {json, 200, #{}, #{
                player_id => PlayerId,
                session_token => Token,
                username => maps:get(username, Player)
            }};
        {error, _} ->
            {json, 500, #{}, #{error => ~"player_not_found"}}
    end.

-spec create_player_with_identity(binary(), map()) -> {json, integer(), map(), map()}.
create_player_with_identity(Provider, Claims) ->
    ProviderUid = maps:get(provider_uid, Claims),
    DisplayName = maps:get(provider_display_name, Claims, undefined),
    Username = generate_username(Provider, ProviderUid),
    PlayerParams = #{
        username => Username,
        display_name => maybe_value(DisplayName, Username)
    },
    CS = kura_changeset:cast(asobi_player, #{}, PlayerParams, [username, display_name]),
    CS1 = kura_changeset:validate_required(CS, [username]),
    case asobi_repo:insert(CS1) of
        {ok, Player} ->
            PlayerId = maps:get(id, Player),
            _ = init_player_stats(PlayerId),
            _ = insert_identity(PlayerId, Provider, Claims),
            {ok, Token} = nova_auth_session:generate_session_token(asobi_auth, Player),
            {json, 200, #{}, #{
                player_id => PlayerId,
                session_token => Token,
                username => Username,
                created => true
            }};
        {error, _CS} ->
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
    Short = binary:part(ProviderUid, 0, min(8, byte_size(ProviderUid))),
    Rand = integer_to_binary(rand:uniform(9999)),
    <<Provider/binary, "_", Short/binary, "_", Rand/binary>>.

-spec maybe_value(term(), term()) -> term().
maybe_value(undefined, Default) -> Default;
maybe_value(Value, _Default) -> Value.

-spec init_player_stats(binary()) -> ok.
init_player_stats(PlayerId) ->
    CS = kura_changeset:cast(asobi_player_stats, #{}, #{player_id => PlayerId}, [player_id]),
    _ = asobi_repo:insert(CS),
    ok.

-spec provider_to_atom(binary()) -> atom().
provider_to_atom(~"google") -> google;
provider_to_atom(~"apple") -> apple;
provider_to_atom(~"microsoft") -> microsoft;
provider_to_atom(~"discord") -> discord;
provider_to_atom(_) -> unknown.
