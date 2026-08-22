-module(asobi_zone_busy_game).

%% Vetoes demotion when its zone state says so, which is the shape a wave
%% spawner has: no entities between waves, and a countdown asobi cannot see.
-export([zone_tick/2, handle_input/3, zone_busy/1]).

zone_tick(E, ZS) -> {E, ZS}.
handle_input(_P, _I, E) -> {ok, E}.

zone_busy(#{busy := bad_return}) -> not_a_boolean;
zone_busy(#{busy := raises}) -> error(deliberate);
zone_busy(#{busy := Busy}) when is_boolean(Busy) -> Busy;
zone_busy(_) -> false.
