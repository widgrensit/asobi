-module(asobi_zone_dirty_game).

-export([zone_tick/2, handle_input/3]).

%% Declares what it changed instead of handing back a rebuilt map, which is
%% what lets asobi keep the untouched entities as the same terms
%% (widgrensit/asobi#557). `dirty` in the zone state is whatever the test wants
%% the fourth return value to be, so a malformed declaration is testable too.
zone_tick(Entities, ZoneState) when is_map(ZoneState) ->
    {Entities, ZoneState, false, maps:get(dirty, ZoneState, #{})};
zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.
