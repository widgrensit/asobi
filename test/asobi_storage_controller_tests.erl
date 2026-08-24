-module(asobi_storage_controller_tests).

-include_lib("eunit/include/eunit.hrl").

%% The seven storage routes answer the same 404 an unknown route gets when
%% storage is switched off (asobi_storage:enabled/0), before any auth or body
%% work, and behave normally when it is on. asobi_repo is mocked so the enabled
%% path needs no database.

-define(PID, ~"11111111-1111-1111-1111-111111111111").

controller_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun each_route_answers_its_family_not_found_when_disabled/0,
        fun routes_reach_their_handler_when_enabled/0,
        fun a_malformed_binding_answers_the_same_on_every_handler/0
    ]}.

%% asobi#435 tranche 3 added `when is_binary(Col), is_binary(Key)` to these
%% handlers. guarded/2 checks whether storage is enabled; it does not catch, so
%% a guard without a fallback clause turns a 404 into a 500 - and the first
%% version of that change gave do_get_storage/1 a fallback and do_delete_storage/1
%% only the guard.
a_malformed_binding_answers_the_same_on_every_handler() ->
    application:set_env(asobi, storage, true),
    Req = #{
        bindings => #{~"collection" => 123, ~"key" => ~"theme"},
        json => #{~"value" => #{}},
        qs => ~"",
        auth_data => #{player_id => ?PID}
    },
    Crashed = [
        Name
     || {Name, Result} <- [
            {get, catch asobi_storage_controller:get_storage(Req)},
            {put, catch asobi_storage_controller:put_storage(Req)},
            {delete, catch asobi_storage_controller:delete_storage(Req)}
        ],
        element(1, Result) =:= 'EXIT'
    ],
    ?assertEqual([], Crashed).

setup() ->
    Was = application:get_env(asobi, storage),
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, all, fun(_) -> {ok, []} end),
    meck:expect(asobi_repo, insert, fun(_) -> {ok, row()} end),
    meck:expect(asobi_repo, update, fun(_) -> {ok, row()} end),
    meck:expect(asobi_repo, delete, fun(_, _) -> {ok, row()} end),
    Was.

cleanup(Was) ->
    meck:unload(asobi_repo),
    case Was of
        {ok, Value} -> application:set_env(asobi, storage, Value);
        undefined -> application:unset_env(asobi, storage)
    end.

%% Disabled: each route answers the 404 code it gives for a genuine miss -
%% save.not_found on /saves, storage.not_found on /storage - so the off-state
%% is indistinguishable from an empty deployment per family. Both a full req
%% and a bare req (no auth_data) short-circuit to that code, which locks the
%% guard ahead of the head that would otherwise demand auth_data.
each_route_answers_its_family_not_found_when_disabled() ->
    application:set_env(asobi, storage, false),
    [
        begin
            ?assertEqual({asobi_error, Code}, Fn(Req)),
            ?assertEqual({asobi_error, Code}, Fn(#{}))
        end
     || {Fn, Req, Code} <- disabled_routes()
    ].

disabled_routes() ->
    [
        {fun asobi_storage_controller:list_saves/1, list_saves_req(), ~"save.not_found"},
        {fun asobi_storage_controller:get_save/1, get_save_req(), ~"save.not_found"},
        {fun asobi_storage_controller:put_save/1, put_save_req(), ~"save.not_found"},
        {fun asobi_storage_controller:list_storage/1, list_storage_req(), ~"storage.not_found"},
        {fun asobi_storage_controller:get_storage/1, get_storage_req(), ~"storage.not_found"},
        {fun asobi_storage_controller:put_storage/1, put_storage_req(), ~"storage.not_found"},
        {fun asobi_storage_controller:delete_storage/1, delete_storage_req(), ~"storage.not_found"}
    ].

routes_reach_their_handler_when_enabled() ->
    application:set_env(asobi, storage, true),
    %% Empty DB: the handler runs and lands on its own not-found / empty
    %% result, which is a different code from the disabled 404.
    ?assertMatch({json, _}, asobi_storage_controller:list_saves(list_saves_req())),
    ?assertEqual(
        {asobi_error, ~"save.not_found"}, asobi_storage_controller:get_save(get_save_req())
    ),
    ?assertMatch({json, 200, _, _}, asobi_storage_controller:put_save(put_save_req())),
    ?assertMatch({json, _}, asobi_storage_controller:list_storage(list_storage_req())),
    %% get/delete would themselves answer storage.not_found on an empty DB
    %% (the object is genuinely absent), so seed a public row to prove the
    %% handler ran rather than the guard.
    meck:expect(asobi_repo, all, fun(_) -> {ok, [row()]} end),
    ?assertMatch({json, _}, asobi_storage_controller:get_storage(get_storage_req())),
    ?assertMatch({json, _}, asobi_storage_controller:put_storage(put_storage_req())),
    ?assertMatch({json, _}, asobi_storage_controller:delete_storage(delete_storage_req())).

list_saves_req() ->
    #{auth_data => #{player_id => ?PID}}.

get_save_req() ->
    #{bindings => #{~"slot" => ~"slot1"}, auth_data => #{player_id => ?PID}}.

put_save_req() ->
    #{
        bindings => #{~"slot" => ~"slot1"},
        json => #{~"data" => #{}},
        auth_data => #{player_id => ?PID}
    }.

list_storage_req() ->
    #{bindings => #{~"collection" => ~"settings"}, qs => ~"", auth_data => #{player_id => ?PID}}.

get_storage_req() ->
    #{
        bindings => #{~"collection" => ~"settings", ~"key" => ~"theme"},
        auth_data => #{player_id => ?PID}
    }.

put_storage_req() ->
    #{
        bindings => #{~"collection" => ~"settings", ~"key" => ~"theme"},
        json => #{~"value" => #{}},
        auth_data => #{player_id => ?PID}
    }.

delete_storage_req() ->
    #{
        bindings => #{~"collection" => ~"settings", ~"key" => ~"theme"},
        auth_data => #{player_id => ?PID}
    }.

%% A public row that satisfies the get/put/delete happy paths.
row() ->
    #{
        id => ~"11111111-1111-1111-1111-111111111112",
        slot => ~"slot1",
        collection => ~"settings",
        key => ~"theme",
        player_id => ?PID,
        value => #{},
        version => 1,
        read_perm => ~"public",
        write_perm => ~"public",
        updated_at => {{2024, 1, 1}, {0, 0, 0}}
    }.
