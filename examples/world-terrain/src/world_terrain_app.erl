-module(world_terrain_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    world_terrain_sup:start_link().

stop(_State) ->
    ok.
