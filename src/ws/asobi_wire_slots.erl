-module(asobi_wire_slots).
-moduledoc """
Zone-scoped 2-byte entity slots for the binary wire (ADR 0013, decision 4).

A slot replaces a 36-character entity id with two bytes, which is what brings a
400-entity zone at 10% churn inside a single datagram. The mapping belongs to the
**zone**, not to a connection: a per-connection id space would mean different
bytes for every subscriber, and that destroys ADR 0001's one-buffer-per-tick
fan-out. Zone scoping keeps the shared encode intact.

## Slots track the broadcast baseline, always

`sync/2` is called wherever `broadcast_entities` advances, so the invariant is
`keys(slots) =:= keys(broadcast_entities)` at all times, and it holds whether or
not any connection has negotiated the binary wire.

Allocating lazily - only once a binary subscriber appears - was the obvious
alternative and it is a trap. A client negotiating mid-session, or a resync
arriving before the next baseline advance, would then need slots that do not
exist yet. Tying the mapping to the baseline instead means a keyframe's slots and
the delta stream's slots cannot disagree, which is the same invariant ADR 0011
established for the entities themselves. The cost is one map insert per entity
that enters the zone.

## Reuse

Slots are handed out monotonically and wrap, so a freed slot is reused as late as
the space allows. That is a mitigation, not a guarantee, and the guarantee comes
from elsewhere: a reused slot always arrives at the client on an `add`, which
carries the entity id and REPLACES the binding. The only corrupting sequence is
missing both the remove of the old entity and the add of the new one and then
receiving an update, which is a gap - and `frame_seq` detects a gap and
`world.resync` repairs it. So no generation counter is needed here; the existing
detector bounds the hazard.

## Exhaustion

65536 concurrently-live entities in one zone is far outside any sane grid config,
so exhaustion returns an error for the caller to log rather than wrapping into a
live slot. Rebinding a slot that is in use would be undetectable corruption on
every client watching that zone; a loud failure is a capacity conversation.
""".

-export([new/0, sync/2, slot_of/2, count/1]).
-export_type([slots/0]).

-define(SPACE, 65536).

-define(GEN_SPACE, 256).

-opaque slots() :: #{
    by_id := #{binary() => {non_neg_integer(), 0..255}},
    by_slot := #{non_neg_integer() => binary()},
    %% The CURRENT generation of every slot ever handed out, kept after release
    %% so the next binding can advance it. Bounded by ?SPACE, never pruned.
    gens := #{non_neg_integer() => 0..255},
    next := non_neg_integer()
}.

-doc "An empty mapping, for a zone with no entities yet.".
-spec new() -> slots().
new() -> #{by_id => #{}, by_slot => #{}, gens => #{}, next => 0}.

-doc """
Brings the mapping in line with a new broadcast baseline.

Allocates a slot for every entity that is new to `Entities` and releases the slot
of every entity that has left it. Idempotent: syncing the same map twice is a
no-op, which matters because a broadcast tick that changed nothing still advances
the baseline.
""".
-spec sync(#{binary() => term()}, slots()) -> {ok, slots()} | {error, exhausted}.
sync(Entities, #{by_id := ById} = Slots) ->
    Released = maps:fold(
        fun(Id, _Slot, Acc) ->
            case maps:is_key(Id, Entities) of
                true -> Acc;
                false -> [Id | Acc]
            end
        end,
        [],
        ById
    ),
    Slots1 = lists:foldl(fun release/2, Slots, Released),
    allocate_missing(maps:keys(Entities), Slots1).

-doc """
The slot and generation bound to `Id`, or `error` if it is not in the baseline.

The generation advances every time a slot is rebound to a different entity, and
it is what lets a lossy carrier tell a pose for the entity that holds slot 5 now
from one for the entity that held it a moment ago. On the ordered, reliable
WebSocket wire the sequencing already covers that, so this is carried but only
consulted by clients that also run the datagram plane (ADR 0012, decision 12).
""".
-spec slot_of(binary(), slots()) -> {ok, {non_neg_integer(), 0..255}} | error.
slot_of(Id, #{by_id := ById}) ->
    maps:find(Id, ById).

-doc "How many slots are currently bound. Equals the baseline's entity count.".
-spec count(slots()) -> non_neg_integer().
count(#{by_id := ById}) -> map_size(ById).

%% --- Internal ---

allocate_missing([], Slots) ->
    {ok, Slots};
allocate_missing([Id | Rest], #{by_id := ById} = Slots) ->
    case maps:is_key(Id, ById) of
        true ->
            allocate_missing(Rest, Slots);
        false ->
            case take_free_slot(Slots) of
                {ok, Slot, Slots1} ->
                    #{by_id := B1, by_slot := S1, gens := G1} = Slots1,
                    %% Fresh slots start at generation 0 and every rebinding
                    %% advances by one, wrapping at 256. Wrapping is safe by
                    %% arithmetic rather than by hope: aliasing needs the same
                    %% slot rebound 256 times between a datagram being sent and
                    %% applied, which at 65536 slots is 16.7M allocations in one
                    %% zone inside a packet's flight time.
                    Gen = (maps:get(Slot, G1, ?GEN_SPACE - 1) + 1) rem ?GEN_SPACE,
                    allocate_missing(Rest, Slots1#{
                        by_id => B1#{Id => {Slot, Gen}},
                        by_slot => S1#{Slot => Id},
                        gens => G1#{Slot => Gen}
                    });
                {error, exhausted} ->
                    {error, exhausted}
            end
    end.

%% Walks forward from `next`, wrapping once. Returning after a full lap rather
%% than looping forever is the difference between an error the operator sees and
%% a zone that hangs its own tick.
take_free_slot(#{by_slot := BySlot, next := Next} = Slots) ->
    take_free_slot(Slots, BySlot, Next, ?SPACE).

take_free_slot(_Slots, _BySlot, _Cursor, 0) ->
    {error, exhausted};
take_free_slot(Slots, BySlot, Cursor, Remaining) ->
    case maps:is_key(Cursor, BySlot) of
        false -> {ok, Cursor, Slots#{next => (Cursor + 1) rem ?SPACE}};
        true -> take_free_slot(Slots, BySlot, (Cursor + 1) rem ?SPACE, Remaining - 1)
    end.

%% Drops the binding but KEEPS the generation, which is the whole point of
%% holding it in a separate map: a slot handed out again must not restart at the
%% generation a client may still have in flight for its previous occupant.
release(Id, #{by_id := ById, by_slot := BySlot} = Slots) ->
    case ById of
        #{Id := {Slot, _Gen}} ->
            Slots#{by_id => maps:remove(Id, ById), by_slot => maps:remove(Slot, BySlot)};
        _ ->
            Slots
    end.
