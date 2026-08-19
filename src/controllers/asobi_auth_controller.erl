-module(asobi_auth_controller).

-export([register/1, login/1, refresh/1, logout/1]).

-include_lib("kura/include/kura.hrl").

-type response() ::
    {json, map()}
    | {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.

%% kura's default message for a unique-index violation (asobi_player:indexes/0).
%% The 409 contract keys off it; pin it here so the coupling is visible.
-define(UNIQUE_MSG, ~"has already been taken").

-spec register(cowboy_req:req()) -> response().
register(
    #{json := #{~"username" := Username, ~"password" := Password} = Params} = _Req
) when is_binary(Username), is_binary(Password) ->
    case asobi_registration:check(password) of
        {deny, Reason} ->
            asobi_auth_error:registration_denied(Reason);
        ok ->
            register_player(Username, Password, Params)
    end;
register(_Req) ->
    {asobi_error, ~"missing_field"}.

-spec register_player(binary(), binary(), map()) -> response().
register_player(Username, Password, Params) ->
    RegParams = #{
        username => Username,
        password => Password,
        display_name => maps:get(~"display_name", Params, Username)
    },
    case
        nova_auth_accounts:register(
            asobi_auth, fun asobi_player:registration_changeset/2, RegParams
        )
    of
        {ok, Player} ->
            asobi_player_stats:init(maps:get(id, Player)),
            asobi_auth_tokens:issue(Player, 200, #{username => maps:get(username, Player)});
        {error, #kura_changeset{} = CS} ->
            registration_error(kura_changeset:traverse_errors(CS, fun(_F, M) -> M end))
    end.

%% A duplicate username is a conflict with the current server state, so it
%% returns 409 with a stable reason atom - the same shape as every other
%% conflict endpoint. kura maps the username unique index (declared in
%% asobi_player:indexes/0) to this changeset error. Any other changeset failure
%% is malformed input: 422 with per-field detail for form UIs.
registration_error(#{username := Msgs} = Fields) when is_list(Msgs) ->
    case lists:member(?UNIQUE_MSG, Msgs) of
        true -> {asobi_error, ~"auth.username_taken"};
        false -> asobi_auth_error:validation_failed(Fields)
    end;
registration_error(Fields) ->
    asobi_auth_error:validation_failed(Fields).

-spec login(cowboy_req:req()) -> response().
login(#{json := #{~"username" := Username, ~"password" := Password}} = _Req) when
    is_binary(Username), is_binary(Password)
->
    case nova_auth_accounts:authenticate(asobi_auth, Username, Password) of
        {ok, Player} ->
            asobi_auth_tokens:issue(Player, 200, #{username => maps:get(username, Player)});
        {error, invalid_credentials} ->
            {asobi_error, ~"auth.invalid_credentials"}
    end;
login(_Req) ->
    {asobi_error, ~"missing_field"}.

-spec refresh(cowboy_req:req()) -> response().
refresh(#{json := #{~"refresh_token" := RefreshToken}} = _Req) when is_binary(RefreshToken) ->
    case nova_auth_refresh:refresh(asobi_auth, RefreshToken) of
        {ok, #{access_token := Access, refresh_token := Refresh}} ->
            {json, 200, #{}, #{access_token => Access, refresh_token => Refresh}};
        {error, _} ->
            {asobi_error, ~"unauthenticated"}
    end;
refresh(_Req) ->
    {asobi_error, ~"missing_field"}.

-spec logout(cowboy_req:req()) -> {json, integer(), map(), map()}.
logout(#{json := #{~"refresh_token" := RefreshToken}} = Req) when is_binary(RefreshToken) ->
    ok = nova_auth_refresh:revoke_family(asobi_auth, RefreshToken),
    ok = asobi_auth_tokens:revoke_access(Req),
    {json, 200, #{}, #{success => true}};
logout(Req) ->
    ok = asobi_auth_tokens:revoke_access(Req),
    {json, 200, #{}, #{success => true}}.
