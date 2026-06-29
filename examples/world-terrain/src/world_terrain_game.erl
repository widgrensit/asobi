-module(world_terrain_game).

-moduledoc """
Minimal `m:asobi_world` game that wires in a terrain provider.

Everything here is a stub except `terrain_provider/1`: that callback is how
you tell Asobi which provider produces the world's chunks. Asobi starts a
terrain store with it and serves the chunks it returns to clients on zone
entry.
""".

-behaviour(asobi_world).

-export([
    init/1,
    join/2,
    leave/2,
    spawn_position/2,
    zone_tick/2,
    handle_input/3,
    post_tick/2,
    terrain_provider/1
]).

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

handle_input(PlayerId, #{~"x" := X, ~"y" := Y}, Entities) ->
    {ok, Entities#{PlayerId => #{type => ~"player", x => X, y => Y}}};
handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.

post_tick(_Tick, State) ->
    {ok, State}.

terrain_provider(_Config) ->
    {heightmap_terrain_provider, #{}}.
