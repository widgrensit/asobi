-module(asobi_saas_key_plugin_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    passthrough_when_unconfigured/1,
    skips_non_api_paths/1,
    rejects_missing_key/1,
    rejects_invalid_key/1,
    rejects_env_mismatch/1,
    allows_valid_key/1,
    caches_valid_key/1,
    unavailable_saas_returns_503/1
]).

%% Mock saas handler
-export([init/2]).

-define(SAAS_URL, <<"http://localhost:4099">>).

all() ->
    [
        passthrough_when_unconfigured,
        skips_non_api_paths,
        rejects_missing_key,
        rejects_invalid_key,
        rejects_env_mismatch,
        allows_valid_key,
        caches_valid_key,
        unavailable_saas_returns_503
    ].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    Dispatch = cowboy_router:compile([
        {'_', [{"/internal/validate", ?MODULE, []}]}
    ]),
    {ok, _} = cowboy:start_clear(
        saas_mock_listener,
        [{port, 4099}],
        #{env => #{dispatch => Dispatch}}
    ),
    Config.

end_per_suite(_Config) ->
    cowboy:stop_listener(saas_mock_listener),
    ok.

init_per_testcase(_Case, Config) ->
    meck:new(cowboy_req, [unstick, passthrough]),
    meck:expect(cowboy_req, reply, fun
        (Status, Headers, Body, #{fake := true} = Req) ->
            Req#{reply => {Status, Headers, Body}};
        (Status, Headers, Body, Req) ->
            meck:passthrough([Status, Headers, Body, Req])
    end),
    meck:expect(cowboy_req, header, fun
        (Name, #{fake := true} = Req) ->
            maps:get(Name, maps:get(headers, Req, #{}), undefined);
        (Name, Req) ->
            meck:passthrough([Name, Req])
    end),
    meck:expect(cowboy_req, path, fun
        (#{fake := true} = Req) -> maps:get(path, Req, ~"/");
        (Req) -> meck:passthrough([Req])
    end),
    reset_env(),
    clear_cache(),
    set_mock_response({ok, 200, valid_body(~"dev")}),
    Config.

end_per_testcase(_Case, _Config) ->
    meck:unload(cowboy_req),
    reset_env(),
    clear_cache(),
    ok.

%% --- Tests ---

passthrough_when_unconfigured(_) ->
    Req = req(~"/api/v1/players/abc", #{~"x-asobi-key" => ~"ak_whatever"}),
    Result = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state),
    ?assertMatch({ok, _, state}, Result),
    {ok, Req1, state} = Result,
    ?assertEqual(Req, Req1).

skips_non_api_paths(_) ->
    set_url(),
    Req = req(~"/ws", #{}),
    {ok, _, state} = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state).

rejects_missing_key(_) ->
    set_url(),
    Req = req(~"/api/v1/players/abc", #{}),
    {break, Req1, state} = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state),
    ?assertMatch({401, _, _}, maps:get(reply, Req1)).

rejects_invalid_key(_) ->
    set_url(),
    set_mock_response({ok, 401, #{~"error" => ~"invalid_key"}}),
    Req = req(~"/api/v1/players/abc", #{~"x-asobi-key" => ~"ak_bad"}),
    {break, Req1, state} = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state),
    ?assertMatch({401, _, _}, maps:get(reply, Req1)).

rejects_env_mismatch(_) ->
    set_url(),
    set_env_name(~"live"),
    set_mock_response({ok, 200, valid_body(~"dev")}),
    Req = req(~"/api/v1/players/abc", #{~"x-asobi-key" => ~"ak_devkey"}),
    {break, Req1, state} = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state),
    ?assertMatch({403, _, _}, maps:get(reply, Req1)).

allows_valid_key(_) ->
    set_url(),
    set_env_name(~"dev"),
    set_mock_response({ok, 200, valid_body(~"dev")}),
    Req = req(~"/api/v1/players/abc", #{~"x-asobi-key" => ~"ak_devkey"}),
    {ok, Req1, state} = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state),
    Ctx = maps:get(asobi_tenant, Req1),
    ?assertMatch(#{tenant_id := _, game_id := _, environment_id := _}, Ctx),
    ?assertEqual(~"dev", maps:get(env_name, Ctx)).

caches_valid_key(_) ->
    set_url(),
    set_env_name(~"dev"),
    set_mock_response({ok, 200, valid_body(~"dev")}),
    Req = req(~"/api/v1/players/abc", #{~"x-asobi-key" => ~"ak_cached"}),
    {ok, _, state} = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state),
    %% Break saas — subsequent call should use cache
    set_mock_response({ok, 503, #{~"error" => ~"down"}}),
    {ok, _, state} = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state).

unavailable_saas_returns_503(_) ->
    application:set_env(asobi, saas_internal_url, <<"http://localhost:1">>),
    Req = req(~"/api/v1/players/abc", #{~"x-asobi-key" => ~"ak_any"}),
    {break, Req1, state} = asobi_saas_key_plugin:pre_request(Req, #{}, #{}, state),
    ?assertMatch({503, _, _}, maps:get(reply, Req1)).

%% --- Mock saas cowboy handler ---

init(Req0, State) ->
    {Status, BodyJson} =
        case application:get_env(asobi, test_saas_response, undefined) of
            {S, B} when is_integer(S), is_binary(B) -> {S, B};
            _ -> {500, <<"{}">>}
        end,
    Resp = cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        BodyJson,
        Req0
    ),
    {ok, Resp, State}.

%% --- Helpers ---

req(Path, Headers) ->
    #{fake => true, path => Path, headers => Headers}.

valid_body(EnvName) ->
    #{
        ~"tenant_id" => ~"tenant-1",
        ~"game_id" => ~"game-1",
        ~"environment_id" => ~"env-1",
        ~"env_name" => EnvName,
        ~"plan" => ~"free",
        ~"scopes" => [~"game"]
    }.

set_url() ->
    application:set_env(asobi, saas_internal_url, ?SAAS_URL).

set_env_name(Name) ->
    application:set_env(asobi, environment_name, Name).

set_mock_response({ok, Status, Body}) ->
    Json = iolist_to_binary(json:encode(Body)),
    application:set_env(asobi, test_saas_response, {Status, Json}).

reset_env() ->
    application:unset_env(asobi, saas_internal_url),
    application:unset_env(asobi, environment_name),
    application:unset_env(asobi, saas_internal_token),
    application:unset_env(asobi, test_saas_response).

clear_cache() ->
    case ets:whereis(asobi_saas_key_cache) of
        undefined -> ok;
        _ -> ets:delete_all_objects(asobi_saas_key_cache)
    end.
