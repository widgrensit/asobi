-module(asobi_sup_lua_children_tests).
-include_lib("eunit/include/eunit.hrl").

%% The asobi_lua merge folded asobi_lua_app:start/2 into asobi_app and
%% asobi_sup. The order it used to produce came from the two applications:
%% asobi's children were all up before asobi_lua loaded the game config and
%% started its own children. asobi_guest_reaper reads `guest_auth` in
%% start_link/0, so moving the config load in front of the core children would
%% change what the core sees at boot.
%% Pin the tail order so that stays a deliberate decision, not a refactor
%% accident.

child_ids(Mod) ->
    {ok, {_Flags, Children}} = Mod:init([]),
    [maps:get(id, Spec) || Spec <- Children].

lua_children_are_supervised_test() ->
    Ids = child_ids(asobi_sup),
    ?assert(lists:member(asobi_lua_config, Ids)),
    ?assert(lists:member(asobi_lua_sup, Ids)).

lua_children_start_last_test() ->
    Ids = child_ids(asobi_sup),
    ?assertEqual([asobi_lua_config, asobi_lua_sup], lists:nthtail(length(Ids) - 2, Ids)).

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
