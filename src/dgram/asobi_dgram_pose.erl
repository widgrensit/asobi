-module(asobi_dgram_pose).
-moduledoc """
Turns a zone's changed transform state into pose records.

Pure: no processes, no sockets, no clock. The zone calls `records/5` on its
broadcast tick and hands the result to the gateway.

## The manifest is negotiated once, over TLS

    {dgram_pose, #{
        period_ticks => 20,
        fields => [
            #{name => ~"x",  scale => 100},
            #{name => ~"y",  scale => 100},
            #{name => ~"vx", scale => 100},
            #{name => ~"vy", scale => 100}
        ]
    }}

The list is the canonical order and the bit order of `rmask`, so a decoder is a
fixed layout rather than something self-describing. That is the point: the wire
carries no field names at all, and the client learns them once in the mint
response instead of on every datagram.

At most **eight** fields, because `rmask` is one byte. A ninth is a
configuration error rather than a silent truncation.

## int16 and a scale, not float32

Halves every field, and decodes in Lua 5.1 with two multiplies rather than a
hand-assembled IEEE-754 mantissa. `scale => 100` means two decimal places and a
range of +/-327.67 in world units; a game with a bigger world uses a smaller
scale and accepts coarser steps, which is a decision only that game can make.

**A value outside the range saturates and is counted, never wrapped.** Wrapping
would teleport an entity from one edge of the world to the other, which looks
exactly like a game bug and is the sort of thing that gets debugged for a week.
Saturation puts it against the edge, which looks like what it is.

## Entities at rest

A pose only ever carries what changed, so an entity that stops moving stops being
mentioned - and a client that missed its last update would keep it wrong forever.
Axial frame synchronisation fixes that without acks, without per-client state and
without a second encode: on each tick, every entity whose `slot rem Period`
equals `Tick rem Period` is included whether it changed or not. At 20 Hz with a
period of 20 that re-sends one twentieth of the zone per tick, so anything stale
is corrected within a second.

It is the only loss-repair scheme compatible with one shared baseline and one
shared encode, which is why it is this rather than anything cleverer.

## What a pose can never do

Create an entity, remove one, or touch a non-transform field. Structurally, not
by convention: the record carries a slot and a bitmask over the manifest, and
there is nowhere in it to say anything else. Creation and removal ride the
reliable, ordered `world.tick` and only that.
""".

-export([manifest/0, fieldmask/1, records/5, quantise/2]).
-export_type([manifest/0, field/0]).

-define(MAX_FIELDS, 8).
-define(I16_MIN, -32768).
-define(I16_MAX, 32767).
-define(DEFAULT_PERIOD, 20).

-type field() :: #{name := binary(), scale := number()}.

-type manifest() :: #{fields := [field()], period_ticks := pos_integer()}.

-doc """
The configured manifest, or `disabled`.

`disabled` when nothing is configured, which is the default: a deployment that
has not described its transform fields cannot have them quantised, and guessing
at `x` and `y` would silently pick a scale for a game whose world is a thousand
times larger.
""".
-spec manifest() -> {ok, manifest()} | disabled.
manifest() ->
    case application:get_env(asobi, dgram_pose) of
        {ok, #{fields := Fields}} when is_list(Fields), Fields =/= [] ->
            case validate(Fields, []) of
                {ok, Valid} when length(Valid) =< ?MAX_FIELDS ->
                    {ok, #{fields => Valid, period_ticks => period()}};
                _ ->
                    disabled
            end;
        _ ->
            disabled
    end.

-doc "The bit over the manifest that every field occupies. All of them, always.".
-spec fieldmask(manifest()) -> 0..255.
fieldmask(#{fields := Fields}) -> (1 bsl length(Fields)) - 1.

-doc """
Builds this tick's pose records.

`Changed` maps an entity id to the transform field names that changed, as the
zone's own delta computation already found them. `Entities` is the new broadcast
baseline, and values are read from it rather than from the diff, because a pose is
absolute: what the diff decides is which fields to *include*, never what they say.

Entities with no slot are skipped. That is not a defect to log: an entity can be
in the baseline before the slot map has caught up, and the frame after this one
carries it.
""".
-spec records(
    #{binary() => [binary()]},
    #{binary() => map()},
    asobi_wire_slots:slots(),
    manifest(),
    non_neg_integer()
) -> {[asobi_dgram:pose_record()], non_neg_integer()}.
records(Changed, Entities, Slots, #{fields := Fields, period_ticks := Period}, TickN) ->
    Phase = TickN rem Period,
    build(maps:to_list(Entities), Changed, Slots, Fields, Period, Phase, [], 0).

-doc """
One value onto the wire, saturating rather than wrapping.

Returns `{saturated, Clamped}` when the value did not fit, so the caller can count
it: a game whose entities routinely saturate has the wrong scale configured, and
that is worth knowing before players report teleporting.
""".
-spec quantise(term(), field()) -> {ok, integer()} | {saturated, integer()} | skip.
quantise(Value, #{scale := Scale}) when is_number(Value) ->
    clamp(round(Value * Scale));
quantise(_Value, _Field) ->
    %% A transform field holding something that is not a number is a game putting
    %% a string where a coordinate goes. Skipped rather than guessed at.
    skip.

%% --- Internal ---

clamp(N) when N > ?I16_MAX -> {saturated, ?I16_MAX};
clamp(N) when N < ?I16_MIN -> {saturated, ?I16_MIN};
clamp(N) -> {ok, N}.

build([], _Changed, _Slots, _Fields, _Period, _Phase, Acc, Saturated) ->
    {lists:reverse(Acc), Saturated};
build([{Id, State} | Rest], Changed, Slots, Fields, Period, Phase, Acc, Saturated) ->
    case asobi_wire_slots:slot_of(Id, Slots) of
        error ->
            build(Rest, Changed, Slots, Fields, Period, Phase, Acc, Saturated);
        {ok, {Slot, Gen}} ->
            %% Included if something moved, or if this is the entity's turn in
            %% the axial rotation. The second is what covers entities at rest.
            Wanted =
                case Slot rem Period =:= Phase of
                    true -> all;
                    false -> maps:get(Id, Changed, none)
                end,
            case Wanted of
                none ->
                    build(Rest, Changed, Slots, Fields, Period, Phase, Acc, Saturated);
                _ ->
                    {RMask, Values, Sat} = pack(Fields, State, Wanted, 0, 0, [], 0),
                    case RMask of
                        0 ->
                            build(
                                Rest,
                                Changed,
                                Slots,
                                Fields,
                                Period,
                                Phase,
                                Acc,
                                Saturated + Sat
                            );
                        _ ->
                            Record = #{
                                slot => Slot,
                                gen => Gen,
                                rmask => RMask,
                                values => lists:reverse(Values)
                            },
                            build(
                                Rest,
                                Changed,
                                Slots,
                                Fields,
                                Period,
                                Phase,
                                [Record | Acc],
                                Saturated + Sat
                            )
                    end
            end
    end.

%% Fields are walked in manifest order, which IS the bit order of rmask and the
%% order the values are written in. One traversal produces both, so they cannot
%% disagree - the failure that would put every field one place out on the client.
pack([], _State, _Wanted, _Bit, RMask, Values, Sat) ->
    {RMask, Values, Sat};
pack([#{name := Name} = Field | Rest], State, Wanted, Bit, RMask, Values, Sat) ->
    Include =
        case Wanted of
            all -> maps:is_key(Name, State);
            Names -> lists:member(Name, Names) andalso maps:is_key(Name, State)
        end,
    case Include andalso quantise(maps:get(Name, State, undefined), Field) of
        false ->
            pack(Rest, State, Wanted, Bit + 1, RMask, Values, Sat);
        skip ->
            pack(Rest, State, Wanted, Bit + 1, RMask, Values, Sat);
        {ok, V} ->
            pack(Rest, State, Wanted, Bit + 1, RMask bor (1 bsl Bit), [V | Values], Sat);
        {saturated, V} ->
            pack(Rest, State, Wanted, Bit + 1, RMask bor (1 bsl Bit), [V | Values], Sat + 1)
    end.

validate([], Acc) ->
    {ok, lists:reverse(Acc)};
validate([#{name := Name, scale := Scale} | Rest], Acc) when
    is_binary(Name), is_number(Scale), Scale > 0
->
    validate(Rest, [#{name => Name, scale => Scale} | Acc]);
validate(_Bad, _Acc) ->
    invalid.

period() ->
    case application:get_env(asobi, dgram_pose) of
        {ok, #{period_ticks := P}} when is_integer(P), P > 0 -> P;
        _ -> ?DEFAULT_PERIOD
    end.
