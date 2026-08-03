-module(asobi_game_config_tests).

-include_lib("eunit/include/eunit.hrl").

game_config_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a mode dropped from the script set disappears", fun removed_script_mode_disappears/0},
        {"an operator mode survives a script reload", fun operator_mode_survives_reload/0},
        {"an operator mode wins a name clash, reload after reload", fun operator_mode_wins_clash/0},
        {"a term without modes leaves the registry alone", fun modes_key_absent_is_a_no_op/0},
        {"a term without guest_auth leaves the posture alone",
            fun guest_auth_key_absent_is_a_no_op/0},
        {"a declared guest_auth replaces the flag", fun guest_auth_declared_replaces_flag/0},
        {"a non-map operator env is ignored, not crashed on", fun non_map_operator_env_ignored/0},
        {"script modes resolve through asobi_game_modes", fun script_mode_resolves/0}
    ]}.

setup() ->
    Saved = [{Key, application:get_env(asobi, Key)} || Key <- keys()],
    [application:unset_env(asobi, Key) || Key <- keys()],
    %% Same registration asobi_app:start/2 performs. asobi_game_modes resolves
    %% {lua, _} modes through a provider registry, so without it every script
    %% mode here is lua_runtime_unavailable.
    ok = asobi_lua_sup:register_game_modes(),
    Saved.

cleanup(Saved) ->
    [
        asobi_game_modes:unregister_game_mode(K)
     || K <- [lua_match, lua_match_shared, lua_world]
    ],
    [restore(Key, Value) || {Key, Value} <- Saved],
    ok.

keys() ->
    [game_modes, script_game_modes, guest_auth].

restore(Key, {ok, Value}) -> application:set_env(asobi, Key, Value);
restore(Key, undefined) -> application:unset_env(asobi, Key).

%% The registry used to be `maps:merge(Existing, New)` against a single key, so
%% a mode the game no longer declares was matchable forever.
removed_script_mode_disappears() ->
    ok = asobi_game_config:apply_config(#{
        modes => #{~"arena" => #{match_size => 4}, ~"ctf" => #{match_size => 8}}
    }),
    ?assertEqual([~"arena", ~"ctf"], lists:sort(maps:keys(asobi_game_config:modes()))),

    ok = asobi_game_config:apply_config(#{modes => #{~"arena" => #{match_size => 4}}}),
    ?assertEqual([~"arena"], maps:keys(asobi_game_config:modes())),
    ?assertEqual(#{}, asobi_game_modes:mode_config(~"ctf")),
    ?assertEqual({error, not_found}, asobi_game_modes:resolve_game_module(~"ctf")).

operator_mode_survives_reload() ->
    application:set_env(asobi, game_modes, #{~"ranked" => #{module => op_game, match_size => 2}}),
    ok = asobi_game_config:apply_config(#{modes => #{~"arena" => #{match_size => 4}}}),
    ?assertEqual([~"arena", ~"ranked"], lists:sort(maps:keys(asobi_game_config:modes()))),

    ok = asobi_game_config:apply_config(#{modes => #{}}),
    ?assertEqual(
        #{module => op_game, match_size => 2},
        asobi_game_modes:mode_config(~"ranked")
    ).

operator_mode_wins_clash() ->
    Operator = #{module => op_game, match_size => 2},
    Script = #{module => {lua, "arena/match.lua"}, match_size => 99},
    application:set_env(asobi, game_modes, #{~"arena" => Operator}),
    ok = asobi_game_config:apply_config(#{modes => #{~"arena" => Script}}),
    ?assertEqual(Operator, asobi_game_modes:mode_config(~"arena")),

    ok = asobi_game_config:apply_config(#{modes => #{~"arena" => Script}}),
    ?assertEqual(Operator, asobi_game_modes:mode_config(~"arena")).

modes_key_absent_is_a_no_op() ->
    ok = asobi_game_config:apply_config(#{modes => #{~"arena" => #{match_size => 4}}}),
    ok = asobi_game_config:apply_config(#{guest_auth => true}),
    ?assertEqual([~"arena"], maps:keys(asobi_game_config:modes())).

%% What keeps a live mode-shape reload from flipping auth posture (ADR 0004).
guest_auth_key_absent_is_a_no_op() ->
    application:set_env(asobi, guest_auth, true),
    ok = asobi_game_config:apply_config(#{modes => #{~"arena" => #{match_size => 4}}}),
    ?assertEqual({ok, true}, application:get_env(asobi, guest_auth)).

guest_auth_declared_replaces_flag() ->
    application:set_env(asobi, guest_auth, true),
    ok = asobi_game_config:apply_config(#{guest_auth => false, modes => #{}}),
    ?assertEqual({ok, false}, application:get_env(asobi, guest_auth)),

    ok = asobi_game_config:apply_config(#{guest_auth => true, modes => #{}}),
    ?assertEqual({ok, true}, application:get_env(asobi, guest_auth)).

non_map_operator_env_ignored() ->
    application:set_env(asobi, game_modes, not_a_map),
    ok = asobi_game_config:apply_config(#{modes => #{~"arena" => #{match_size => 4}}}),
    ?assertEqual([~"arena"], maps:keys(asobi_game_config:modes())).

script_mode_resolves() ->
    ok = asobi_game_config:apply_config(#{
        modes => #{~"arena" => #{module => {lua, "arena/match.lua"}, match_size => 4}}
    }),
    ?assertEqual(
        {ok, asobi_lua_match, #{lua_script => "arena/match.lua"}},
        asobi_game_modes:resolve_game_module(~"arena")
    ).
