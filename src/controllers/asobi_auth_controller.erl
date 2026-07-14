-module(asobi_auth_controller).

-export([register/1, login/1, refresh/1, logout/1]).

-include_lib("kura/include/kura.hrl").

%% kura's default message for a unique-index violation (asobi_player:indexes/0).
%% The 409 contract keys off it; pin it here so the coupling is visible.
-define(UNIQUE_MSG, ~"has already been taken").

-spec register(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
register(
    #{json := #{~"username" := Username, ~"password" := Password} = Params} = _Req
) when is_binary(Username), is_binary(Password) ->
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
            init_player_stats(maps:get(id, Player)),
            asobi_auth_tokens:issue(Player, 200, #{username => maps:get(username, Player)});
        {error, #kura_changeset{} = CS} ->
            registration_error(kura_changeset:traverse_errors(CS, fun(_F, M) -> M end))
    end;
register(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

%% A duplicate username is a conflict with the current server state, so it
%% returns 409 with a stable reason atom - the same shape as every other
%% conflict endpoint. kura maps the username unique index (declared in
%% asobi_player:indexes/0) to this changeset error. Any other changeset failure
%% is malformed input: 422 with per-field detail for form UIs.
registration_error(#{username := Msgs} = Fields) when is_list(Msgs) ->
    case lists:member(?UNIQUE_MSG, Msgs) of
        true -> {json, 409, #{}, #{error => ~"username_taken"}};
        false -> validation_failed(Fields)
    end;
registration_error(Fields) ->
    validation_failed(Fields).

validation_failed(Fields) ->
    {json, 422, #{}, #{error => ~"validation_failed", fields => Fields}}.

-spec login(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
login(#{json := #{~"username" := Username, ~"password" := Password}} = _Req) when
    is_binary(Username), is_binary(Password)
->
    case nova_auth_accounts:authenticate(asobi_auth, Username, Password) of
        {ok, Player} ->
            asobi_auth_tokens:issue(Player, 200, #{username => maps:get(username, Player)});
        {error, invalid_credentials} ->
            {json, 401, #{}, #{error => ~"invalid_credentials"}}
    end;
login(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

-spec refresh(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
refresh(#{json := #{~"refresh_token" := RefreshToken}} = _Req) when is_binary(RefreshToken) ->
    case nova_auth_refresh:refresh(asobi_auth, RefreshToken) of
        {ok, #{access_token := Access, refresh_token := Refresh}} ->
            {json, 200, #{}, #{access_token => Access, refresh_token => Refresh}};
        {error, _} ->
            {json, 401, #{}, #{error => ~"invalid_token"}}
    end;
refresh(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

-spec logout(cowboy_req:req()) -> {json, integer(), map(), map()}.
logout(#{json := #{~"refresh_token" := RefreshToken}} = Req) when is_binary(RefreshToken) ->
    ok = nova_auth_refresh:revoke_family(asobi_auth, RefreshToken),
    ok = asobi_auth_tokens:revoke_access(Req),
    {json, 200, #{}, #{success => true}};
logout(Req) ->
    ok = asobi_auth_tokens:revoke_access(Req),
    {json, 200, #{}, #{success => true}}.

%% --- Internal ---

-spec init_player_stats(binary()) -> ok.
init_player_stats(PlayerId) ->
    CS = kura_changeset:cast(asobi_player_stats, #{}, #{player_id => PlayerId}, [player_id]),
    %% F-25: previously errors were swallowed silently which left players
    %% registered without a stats row. Log so we notice the regression
    %% without blocking the registration flow.
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
