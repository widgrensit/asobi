-module(asobi_terrain_test_game).
-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2, terrain_provider/1]).

init(_Config) -> {ok, #{players => #{}, tick_count => 0}}.
join(PlayerId, #{players := P} = S) -> {ok, S#{players => P#{PlayerId => #{}}}}.
leave(PlayerId, #{players := P} = S) -> {ok, S#{players => maps:remove(PlayerId, P)}}.
spawn_position(_PlayerId, _State) -> {ok, {50.0, 50.0}}.
zone_tick(E, Z) -> {E, Z}.
handle_input(_P, _I, E) -> {ok, E}.
post_tick(T, S) -> {ok, S#{tick_count => T}}.
terrain_provider(_Config) -> {asobi_terrain_test_provider, #{seed => 99}}.
