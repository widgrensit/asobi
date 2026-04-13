-module(asobi_zone_spatial_test_game).

-export([zone_tick/2, handle_input/3]).

zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.
