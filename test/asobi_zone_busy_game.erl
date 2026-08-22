-module(asobi_zone_busy_game).

%% Answers zone_tick/2's optional third element from its own zone state, which
%% is the shape a wave spawner has: no entities between waves, and a countdown
%% asobi cannot see.
-export([zone_tick/2, handle_input/3]).

handle_input(_P, _I, E) -> {ok, E}.

%% A two-tuple means "not busy", so this also covers the additive case.
zone_tick(E, #{busy := quiet} = ZS) -> {E, ZS};
zone_tick(E, #{busy := Busy} = ZS) -> {E, ZS, Busy};
zone_tick(E, ZS) -> {E, ZS}.
