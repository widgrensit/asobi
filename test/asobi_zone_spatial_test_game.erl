-module(asobi_zone_spatial_test_game).

-export([zone_tick/2, handle_input/3]).

%% Two markers, both driven from the tick rather than from a cast, because a
%% cast reaches the grid through spatial_grid_insert/remove and never through
%% sync_spatial_grid/3 - which is the function widgrensit/asobi#557 and #558
%% both rewrote.
zone_tick(Entities, ZoneState) ->
    Kept = maps:filter(fun(_Id, E) -> not despawning(E) end, Entities),
    {maps:map(fun(_Id, E) -> drift(E) end, Kept), ZoneState}.

handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.

despawning(E) when is_map(E) -> maps:get(despawn, E, false) =:= true;
despawning(_E) -> false.

drift(#{drift := D, x := X} = E) when is_number(D), is_number(X) -> E#{x => X + D};
drift(E) -> E.
