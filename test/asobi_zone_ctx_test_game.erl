-module(asobi_zone_ctx_test_game).
-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2]).
-export([init_zone_state/2, dump_zone_state/1]).

init(_Config) ->
    {ok, #{}}.

join(_PlayerId, State) ->
    {ok, State}.

leave(_PlayerId, State) ->
    {ok, State}.

spawn_position(_PlayerId, _State) ->
    {ok, {0.0, 0.0}}.

zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.

post_tick(TickN, State) ->
    {ok, State#{tick => TickN}}.

init_zone_state(Config, ZoneState) ->
    ZoneState#{
        built_by => init_zone_state,
        coords => maps:get(coords, Config),
        runtime => make_ref()
    }.

dump_zone_state(ZoneState) ->
    maps:remove(runtime, ZoneState).
