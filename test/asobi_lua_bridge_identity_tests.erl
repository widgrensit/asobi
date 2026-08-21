-module(asobi_lua_bridge_identity_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#536: `[asobi, lua, state]` is emitted once per bridge process, so
%% without an identity every zone in a world reports under one label set and
%% the series reads as a single flapping gauge. The identity is stamped at
%% three call sites and each of them reads a differently-shaped config map -
%% which is exactly how the world one shipped reading a key that is never
%% there. Assert the stamping, not the reporting.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    Dir =
        case code:lib_dir(asobi) of
            {error, bad_name} -> error(asobi_not_loaded);
            D -> D
        end,
    filename:absname(filename:join([Dir, "test", "fixtures", "lua", Name])).

bridge_identity_test_() ->
    [
        {"a world bridge stamps its world id", fun world_identity/0},
        {"a match bridge stamps its match id", fun match_identity/0},
        {"a zone bridge stamps its world id and coords", fun zone_identity/0}
    ].

%% Exactly the map asobi_world_server:init/1 builds: the game config with
%% match_id injected. There is no nested game_config key.
world_identity() ->
    Config = #{lua_script => fixture("gc_zone.lua"), match_id => ~"world-42"},
    {ok, State} = asobi_lua_world:init(Config),
    ?assertEqual(#{kind => world, world_id => ~"world-42"}, maps:get(lua_bridge, State)).

%% Same shape from asobi_match_server:init/1.
match_identity() ->
    Config = #{lua_script => fixture("test_match.lua"), match_id => ~"match-7"},
    {ok, State} = asobi_lua_match:init(Config),
    ?assertEqual(#{kind => match, match_id => ~"match-7"}, maps:get(lua_bridge, State)).

%% The zone one *does* nest game_config - see asobi_zone's init_zone_state
%% continue clause.
zone_identity() ->
    ZoneConfig = #{
        world_id => ~"w1",
        coords => {2, 3},
        game_module => asobi_lua_world,
        game_config => #{lua_script => fixture("gc_zone.lua")}
    },
    ZoneState = asobi_lua_world:init_zone_state(ZoneConfig, #{}),
    ?assertEqual(
        #{kind => zone, world_id => ~"w1", coords => {2, 3}},
        maps:get(lua_bridge, ZoneState)
    ).
