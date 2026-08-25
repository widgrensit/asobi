-module(asobi_zone_dirty_game).

-export([zone_tick/2, handle_input/3]).

%% `dirty` in the zone state is whatever the test wants the fourth return value
%% to be, so a malformed declaration is testable too. Its ABSENCE means the
%% two-tuple return - the compatibility path ADR 0022 claims is unchanged -
%% which needs a test of its own rather than an empty declaration standing in
%% for it.
zone_tick(Entities, ZoneState) when is_map(ZoneState) ->
    case maps:get(dirty, ZoneState, no_declaration) of
        no_declaration -> declared_arity(Entities, ZoneState);
        Dirty -> {Entities, ZoneState, false, Dirty}
    end;
zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

declared_arity(Entities, #{arity := 3, busy := Busy} = ZoneState) ->
    {Entities, ZoneState, Busy};
declared_arity(Entities, ZoneState) ->
    {Entities, ZoneState}.

handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.
