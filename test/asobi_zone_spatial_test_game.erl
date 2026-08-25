-module(asobi_zone_spatial_test_game).

-export([zone_tick/2, handle_input/3]).

%% An entity marked `despawn` is dropped by the tick itself rather than by a
%% `remove_entity` cast, which is the only way to reach sync_spatial_grid's
%% removal path from a test (widgrensit/asobi#558).
zone_tick(Entities, ZoneState) ->
    {maps:filter(fun(_Id, E) -> not despawning(E) end, Entities), ZoneState}.

handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.

despawning(E) when is_map(E) -> maps:get(despawn, E, false) =:= true;
despawning(_E) -> false.
