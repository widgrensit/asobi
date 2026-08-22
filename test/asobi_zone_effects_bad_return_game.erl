-module(asobi_zone_effects_bad_return_game).

%% A game module whose handle_effects/2 breaks its contract. asobi must keep the
%% entity map it already had rather than write the garbage back.
-export([zone_tick/2, handle_input/3, handle_effects/2]).

zone_tick(E, ZS) -> {E, ZS}.
handle_input(_P, _I, E) -> {ok, E}.
handle_effects(_Effects, _Entities) -> not_an_entity_map.
