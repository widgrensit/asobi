-module(asobi_extension_lua_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QUESTS, asobi_fixture_quests).

%% Every assertion here runs Lua source through a real Luerl state. An
%% extension's `lua/0` was validated and installed by nothing, so "the
%% declaration is well-formed" and "a script can call it" were different
%% facts; these only pass if the second one holds.

extension_lua_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun a_declared_binding_is_callable_from_lua/0,
        fun the_namespace_table_is_pre_created/0,
        fun arguments_arrive_decoded_to_their_declared_types/0,
        fun a_whole_lua_number_satisfies_an_integer_argument/0,
        fun a_wrong_argument_type_is_a_legible_error/0,
        fun a_missing_argument_is_a_legible_error/0,
        fun a_binding_error_reaches_lua_as_an_error_result/0,
        fun a_raising_binding_does_not_kill_the_vm/0,
        fun a_binding_outside_the_contract_is_an_error_result/0,
        fun a_write_binding_is_inert_in_a_probe_vm/0,
        fun a_read_binding_still_runs_in_a_probe_vm/0,
        fun a_binding_is_absent_from_a_vm_it_does_not_declare/0,
        fun nothing_is_installed_when_no_extension_is/0
    ]}.

setup() ->
    asobi_extensions:reset(),
    asobi_fixture_quests_lua:reset(),
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []),
    _ = asobi_extensions:resolve(),
    ok.

cleanup(_) ->
    asobi_fixture_app:uninstall(?QUESTS),
    asobi_extensions:reset(),
    asobi_fixture_quests_lua:reset(),
    ok.

%% --- The gap this closes ---

a_declared_binding_is_callable_from_lua() ->
    St = install(match),
    {ok, [Result | _], St1} = eval("return game.quests.progress('p-1', 3)", St),
    ?assertEqual(#{~"ok" => 3}, decode(Result, St1)),
    ?assertEqual([{~"p-1", 3}], asobi_fixture_quests_lua:calls()).

%% `set_table_keys` does not auto-vivify, so without the pre-created table the
%% install itself would raise rather than the call failing later.
the_namespace_table_is_pre_created() ->
    St = install(match),
    {ok, [Type | _], _} = eval("return type(game.quests)", St),
    ?assertEqual(~"table", Type).

arguments_arrive_decoded_to_their_declared_types() ->
    St = install(match),
    {ok, [Result | _], St1} = eval("return game.quests.status('p-7')", St),
    ?assertEqual(
        #{~"ok" => #{~"player_id" => ~"p-7", ~"completed" => 3}},
        decode(Result, St1)
    ).

%% Lua has one number type, so a script writing `1` may hand over 1.0 and an
%% `integer` binding must still be callable.
a_whole_lua_number_satisfies_an_integer_argument() ->
    St = install(match),
    {ok, [Result | _], St1} = eval("return game.quests.progress('p-2', 2.0)", St),
    ?assertEqual(#{~"ok" => 2}, decode(Result, St1)),
    ?assertEqual([{~"p-2", 2}], asobi_fixture_quests_lua:calls()).

a_wrong_argument_type_is_a_legible_error() ->
    St = install(match),
    {ok, [Result | _], St1} = eval("return game.quests.progress('p-1', 'three')", St),
    ?assertEqual(#{~"error" => ~"argument 2 must be a integer"}, decode(Result, St1)),
    ?assertEqual([], asobi_fixture_quests_lua:calls()).

a_missing_argument_is_a_legible_error() ->
    St = install(match),
    {ok, [Result | _], St1} = eval("return game.quests.progress('p-1')", St),
    ?assertEqual(
        #{~"error" => ~"argument 2 is missing; expected a integer"},
        decode(Result, St1)
    ),
    ?assertEqual([], asobi_fixture_quests_lua:calls()).

a_binding_error_reaches_lua_as_an_error_result() ->
    St = install(match),
    {ok, [Result | _], St1} = eval("return game.quests.progress('p-1', -1)", St),
    ?assertEqual(#{~"error" => ~"amount must not be negative"}, decode(Result, St1)).

%% A binding is extension code running inside the game's VM. A raise must be
%% that call's error, not the death of the match.
a_raising_binding_does_not_kill_the_vm() ->
    St = install(match),
    {ok, [Result | _], St1} = eval("return game.quests.status('boom')", St),
    ?assertEqual(#{~"error" => ~"binding failed"}, decode(Result, St1)),
    {ok, [Alive | _], _} = eval("return 1 + 1", St1),
    ?assertEqual(2, Alive).

a_binding_outside_the_contract_is_an_error_result() ->
    St = install(match),
    {ok, [Result | _], St1} = eval("return game.quests.status('wrong')", St),
    ?assertEqual(#{~"error" => ~"binding returned an unexpected value"}, decode(Result, St1)).

%% --- Effects ---
%%
%% A probe VM re-runs the whole script body to ask it a question, so an
%% effectful binding declared `write` must be swapped for the same inert stub
%% core's own writes get. Without it a top-level `game.quests.progress(...)`
%% fires twice on every match creation.

a_write_binding_is_inert_in_a_probe_vm() ->
    St = install(match, #{probe => true}),
    {ok, [Result | _], _} = eval("return game.quests.progress('p-1', 5)", St),
    ?assertEqual(false, Result),
    ?assertEqual([], asobi_fixture_quests_lua:calls()).

a_read_binding_still_runs_in_a_probe_vm() ->
    St = install(match, #{probe => true}),
    {ok, [Result | _], St1} = eval("return game.quests.status('p-9')", St),
    ?assertMatch(#{~"ok" := #{~"player_id" := ~"p-9"}}, decode(Result, St1)).

%% --- VM kinds ---

%% `quests.progress` declares `vms => [match, world]`. A zone VM must not see
%% it, and the namespace it would have hung off must not be created for the
%% only binding left (`status`, which does declare no zone either).
a_binding_is_absent_from_a_vm_it_does_not_declare() ->
    St = install(zone),
    {ok, [Type | _], _} = eval("return type(game.quests)", St),
    ?assertEqual(~"nil", Type).

nothing_is_installed_when_no_extension_is() ->
    asobi_fixture_app:uninstall(?QUESTS),
    asobi_extensions:reset(),
    _ = asobi_extensions:resolve(),
    St = install(match),
    {ok, [Type | _], _} = eval("return type(game.quests)", St),
    ?assertEqual(~"nil", Type).

%% --- helpers ---

install(Vm) ->
    install(Vm, #{}).

install(Vm, Extra) ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = maps:merge(#{vm => Vm, match_id => ~"m-1", match_pid => self()}, Extra),
    asobi_lua_api:install(Ctx, St0).

eval(Code, St) ->
    luerl:do(Code, St).

decode(Result, St) ->
    asobi_lua_api:deep_decode(luerl:decode(Result, St)).

fixture(Name) ->
    filename:absname(
        filename:join([code:lib_dir(asobi), "test", "fixtures", "lua", Name])
    ).
