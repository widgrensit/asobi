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
        {"declared global channel names are the union across modes", fun global_union/0}
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
        ~"quiet" => #{type => world, module => some_game}
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
    lists:foreach(
        fun(Kind) -> ok = asobi_game_modes:unregister_game_mode(Kind) end,
        [lua_world, lua_match, lua_match_shared]
    ),
    cleanup(Prev).

lua_without_provider() ->
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
