-module(asobi_sup_lua_children_tests).
-include_lib("eunit/include/eunit.hrl").

%% The asobi_lua merge folded asobi_lua_app:start/2 into asobi_app and
%% asobi_sup. The order it used to produce came from the two applications:
%% asobi's children were all up before asobi_lua loaded the game config and
%% started its own children. asobi_lua_config_watcher reads the mode registry
%% in its own init/1, so the load has to stay ahead of asobi_lua_sup, and a
%% failed load aborts the boot (asobi_sup:load_lua_game_config/0) - moving it in
%% front of the core children would change both what starts and what a broken
%% bundle takes down with it.
%% Pin the tail order so that stays a deliberate decision, not a refactor
%% accident.

child_ids(Mod) ->
    {ok, {_Flags, Children}} = Mod:init([]),
    [maps:get(id, Spec) || Spec <- Children].

lua_children_are_supervised_test() ->
    Ids = child_ids(asobi_sup),
    ?assert(lists:member(asobi_lua_config, Ids)),
    ?assert(lists:member(asobi_lua_sup, Ids)).

%% Extensions come after the Lua runtime, and the Lua runtime after every core
%% child. An extension may call anything core provides, including Lua.
lua_children_start_after_core_and_before_extensions_test() ->
    Ids = child_ids(asobi_sup),
    Tail = [asobi_lua_config, asobi_lua_sup, asobi_extension_sup],
    ?assertEqual((Ids -- Tail) ++ Tail, Ids).

%% The reaper is the last core child, so this pins the "core before the config
%% load" boundary in one assertion. Not a data dependency: it reads the guest
%% flag at sweep time (asobi#327), not in start_link/0.
guest_reaper_starts_before_game_config_test() ->
    Ids = child_ids(asobi_sup),
    ?assert(index_of(asobi_guest_reaper, Ids) < index_of(asobi_lua_config, Ids)).

lua_sup_keeps_its_own_children_test() ->
    Ids = child_ids(asobi_lua_sup),
    ?assertEqual(
        [asobi_lua_rate_limits, asobi_bot_sup, asobi_bot_spawner, asobi_lua_config_watcher],
        Ids
    ).

lua_sup_is_a_supervisor_child_test() ->
    {ok, {_Flags, Children}} = asobi_sup:init([]),
    [Spec] = [S || S <- Children, maps:get(id, S) =:= asobi_lua_sup],
    ?assertEqual(supervisor, maps:get(type, Spec)),
    ?assertEqual({asobi_lua_sup, start_link, []}, maps:get(start, Spec)).

index_of(Id, Ids) ->
    length(lists:takewhile(fun(X) -> X =/= Id end, Ids)).
