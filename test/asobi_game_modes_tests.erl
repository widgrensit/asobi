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
