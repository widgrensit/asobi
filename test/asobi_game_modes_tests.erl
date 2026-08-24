-module(asobi_game_modes_tests).
-include_lib("eunit/include/eunit.hrl").

%% #299: `chat` was never forwarded into the world server config, so a mode
%% that declared chat channels got none of them - the world server always
%% read `maps:get(chat, Config, #{})` from a map the lobby had stripped it
%% from.
world_config_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"chat config reaches the world server config", fun chat_forwarded/0},
        {"a mode without chat config forwards no chat key", fun chat_absent/0},
        {"declared global channel names are the union across modes", fun global_union/0},
        {"a match mode is refused, not built into a world (#480)", fun match_mode_refused/0},
        {"a mode with no type is a match, so it is refused too (#480)", fun untyped_mode_refused/0},
        {"an unknown mode is still not_found, not wrong_mode_type (#480)",
            fun unknown_mode_still_not_found/0},
        {"the zone-lifecycle knobs reach the world server config (#543)",
            fun zone_knobs_forwarded/0},
        {"a mode that declares none of them forwards none", fun zone_knobs_absent/0}
    ]}.

setup() ->
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, #{
        ~"galaxy" => #{
            type => world,
            module => some_game,
            chat => #{global => [~"general"], world => true}
        },
        ~"arena" => #{type => world, module => some_game, chat => #{global => [~"trade"]}},
        ~"quiet" => #{type => world, module => some_game},
        ~"tuned" => #{
            type => world,
            module => some_game,
            lazy_zones => true,
            zone_idle_timeout => 20000,
            max_active_zones => 64,
            spatial_grid_cell_size => 32,
            cold_tick_divisor => 20,
            rehome_margin => 0.25,
            border_band => 0.15
        },
        ~"duel" => #{type => match, module => some_game},
        ~"untyped" => #{module => some_game}
    }),
    Prev.

cleanup({ok, Prev}) ->
    application:set_env(asobi, game_modes, Prev);
cleanup(undefined) ->
    application:unset_env(asobi, game_modes).

chat_forwarded() ->
    {ok, Config} = asobi_game_modes:world_config(~"galaxy"),
    ?assertEqual(#{global => [~"general"], world => true}, maps:get(chat, Config)).

chat_absent() ->
    {ok, Config} = asobi_game_modes:world_config(~"quiet"),
    ?assertNot(maps:is_key(chat, Config)).

%% widgrensit/asobi#543: every one of these is read downstream and was
%% silently dropped here, so a world declaring `lazy_zones = true` pre-spawned
%% its whole grid anyway and `cold_tick_divisor` never reached the ticker.
zone_knobs_forwarded() ->
    {ok, Config} = asobi_game_modes:world_config(~"tuned"),
    ?assertEqual(true, maps:get(lazy_zones, Config)),
    ?assertEqual(20000, maps:get(zone_idle_timeout, Config)),
    ?assertEqual(64, maps:get(max_active_zones, Config)),
    ?assertEqual(32, maps:get(spatial_grid_cell_size, Config)),
    ?assertEqual(20, maps:get(cold_tick_divisor, Config)),
    ?assertEqual(0.25, maps:get(rehome_margin, Config)),
    ?assertEqual(0.15, maps:get(border_band, Config)).

zone_knobs_absent() ->
    {ok, Config} = asobi_game_modes:world_config(~"quiet"),
    lists:foreach(
        fun(Key) -> ?assertNot(maps:is_key(Key, Config)) end,
        [
            lazy_zones,
            zone_idle_timeout,
            max_active_zones,
            spatial_grid_cell_size,
            cold_tick_divisor,
            border_band
        ]
    ).

global_union() ->
    ?assertEqual([~"general", ~"trade"], asobi_game_modes:global_chat_channels()).

%% The provider registry: core used to name asobi_lua_world / asobi_lua_match /
%% asobi_lua_match_shared by atom, an inverted dependency (asobi_lua depends on
%% asobi, not the reverse) that also failed obscurely when the runtime wasn't in
%% the release. Resolution now goes through whatever registered a provider, and
%% names the failure when nothing did.
provider_registry_test_() ->
    {setup, fun setup_lua/0, fun cleanup_lua/1, [
        {"a lua mode with no registered provider names the missing runtime",
            fun lua_without_provider/0},
        {"a registered provider resolves the mode", fun lua_with_provider/0},
        {"each kind resolves through its own registration", fun lua_kinds_are_independent/0},
        {"an erlang-module mode resolves with an empty registry", fun erlang_module_unaffected/0},
        {"world_config propagates the named failure", fun world_config_without_provider/0}
    ]}.

setup_lua() ->
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{module => {lua, "game/match.lua"}},
        ~"raid" => #{module => {lua, "game/raid.lua"}, state_strategy => shared},
        ~"galaxy" => #{type => world, module => {lua, "game/world.lua"}},
        ~"native" => #{module => some_game}
    }),
    Prev.

cleanup_lua(Prev) ->
    _ = [
        ok = asobi_game_modes:unregister_game_mode(Kind)
     || Kind <- [lua_world, lua_match, lua_match_shared]
    ],
    cleanup(Prev).

lua_without_provider() ->
    %% Establish the absence this asserts on rather than assuming it: the
    %% registry is a global persistent_term, so any earlier test module that
    %% registers a provider would otherwise decide this one's result.
    ok = asobi_game_modes:unregister_game_mode(lua_match),
    ?assertEqual(
        {error, lua_runtime_unavailable}, asobi_game_modes:resolve_game_module(~"arena")
    ).

lua_with_provider() ->
    ok = asobi_game_modes:register_game_mode(lua_match, fake_lua_match),
    ?assertEqual(
        {ok, fake_lua_match, #{lua_script => "game/match.lua"}},
        asobi_game_modes:resolve_game_module(~"arena")
    ),
    ok = asobi_game_modes:unregister_game_mode(lua_match),
    ?assertEqual(
        {error, lua_runtime_unavailable}, asobi_game_modes:resolve_game_module(~"arena")
    ).

lua_kinds_are_independent() ->
    ok = asobi_game_modes:register_game_mode(lua_world, fake_lua_world),
    ok = asobi_game_modes:register_game_mode(lua_match_shared, fake_lua_shared),
    ?assertEqual(
        {ok, fake_lua_world, #{lua_script => "game/world.lua"}},
        asobi_game_modes:resolve_game_module(~"galaxy")
    ),
    ?assertEqual(
        {ok, fake_lua_shared, #{lua_script => "game/raid.lua"}},
        asobi_game_modes:resolve_game_module(~"raid")
    ),
    %% A world/shared registration says nothing about plain matches.
    ?assertEqual(
        {error, lua_runtime_unavailable}, asobi_game_modes:resolve_game_module(~"arena")
    ),
    ok = asobi_game_modes:unregister_game_mode(lua_world),
    ok = asobi_game_modes:unregister_game_mode(lua_match_shared).

erlang_module_unaffected() ->
    ?assertEqual({ok, some_game, #{}}, asobi_game_modes:resolve_game_module(~"native")),
    ?assertEqual({error, not_found}, asobi_game_modes:resolve_game_module(~"nope")).

world_config_without_provider() ->
    ?assertEqual({error, lua_runtime_unavailable}, asobi_game_modes:world_config(~"galaxy")).

%% asobi#480: resolve_game_module/1 dispatches on `type` in its FIRST clause
%% only, so a match mode fell through to asobi_lua_match and world_config/1
%% built a world config around it. asobi_world_instance_sup then brought up six
%% processes and the first join raised undef on spawn_position/2. Refuse it up
%% front instead.
match_mode_refused() ->
    ?assertEqual({error, wrong_mode_type}, asobi_game_modes:world_config(~"duel")).

%% `match` is the default, so the common way in is forgetting game_type.
untyped_mode_refused() ->
    ?assertEqual({error, wrong_mode_type}, asobi_game_modes:world_config(~"untyped")).

%% The new clause must not swallow the pre-existing not_found case: a mode that
%% is not configured at all is still not_found, so a client asking for a typo'd
%% mode gets the same answer it always did.
unknown_mode_still_not_found() ->
    ?assertEqual({error, not_found}, asobi_game_modes:world_config(~"no_such_mode")).
