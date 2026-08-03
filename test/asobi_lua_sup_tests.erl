-module(asobi_lua_sup_tests).

-include_lib("eunit/include/eunit.hrl").

%% The provider registry (#333) inverted mode resolution so asobi_game_modes
%% never names a Lua module, and the asobi_lua merge (#339) then removed the
%% application whose start callback did the registering. Nothing failed to
%% compile; every {lua, _} mode simply resolved to lua_runtime_unavailable at
%% runtime. This pins the three registrations so the same silent break cannot
%% happen again.

register_game_modes_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun registers_all_three_lua_kinds/0,
        fun is_idempotent/0
    ]}.

setup() ->
    Modes = #{
        ~"arena" => #{module => {lua, "game/match.lua"}},
        ~"raid" => #{module => {lua, "game/raid.lua"}, state_strategy => shared},
        ~"galaxy" => #{type => world, module => {lua, "game/world.lua"}}
    },
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, Modes),
    Prev.

cleanup(Prev) ->
    [asobi_game_modes:unregister_game_mode(K) || K <- [lua_match, lua_match_shared, lua_world]],
    case Prev of
        {ok, Old} -> application:set_env(asobi, game_modes, Old);
        undefined -> application:unset_env(asobi, game_modes)
    end.

registers_all_three_lua_kinds() ->
    [asobi_game_modes:unregister_game_mode(K) || K <- [lua_match, lua_match_shared, lua_world]],
    ?assertEqual({error, lua_runtime_unavailable}, asobi_game_modes:resolve_game_module(~"arena")),
    ok = asobi_lua_sup:register_game_modes(),
    ?assertEqual(
        {ok, asobi_lua_match, #{lua_script => "game/match.lua"}},
        asobi_game_modes:resolve_game_module(~"arena")
    ),
    ?assertEqual(
        {ok, asobi_lua_match_shared, #{lua_script => "game/raid.lua"}},
        asobi_game_modes:resolve_game_module(~"raid")
    ),
    ?assertEqual(
        {ok, asobi_lua_world, #{lua_script => "game/world.lua"}},
        asobi_game_modes:resolve_game_module(~"galaxy")
    ).

%% asobi_app:start/2 runs on every application start, including a restart
%% after a crash, so re-registering must be a no-op rather than an error.
is_idempotent() ->
    ok = asobi_lua_sup:register_game_modes(),
    ok = asobi_lua_sup:register_game_modes(),
    ?assertMatch({ok, asobi_lua_match, _}, asobi_game_modes:resolve_game_module(~"arena")).
