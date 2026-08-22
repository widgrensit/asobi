-module(asobi_zone_order_game).

%% Every callback stamps its own name onto every entity, so the entity carries
%% the order asobi ran them in. Pins the tick contract widgrensit/asobi#544
%% depends on: an effect must land on the same tick's post-input state, and an
%% entity timer must fire after it.
-export([zone_tick/2, handle_input/3, handle_effects/2]).

zone_tick(Entities, ZoneState) -> {stamp(Entities, tick), ZoneState}.
handle_input(_PlayerId, _Input, Entities) -> {ok, stamp(Entities, input)}.
handle_effects(_Effects, Entities) -> {ok, stamp(Entities, effect)}.

stamp(Entities, What) ->
    maps:map(
        fun(_Id, Entity) -> Entity#{trace => maps:get(trace, Entity, []) ++ [What]} end,
        Entities
    ).
