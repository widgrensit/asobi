-module(asobi_wire_tests).
-include_lib("eunit/include/eunit.hrl").

%% The binary world.tick codec and its zone-scoped slot allocator (ADR 0013).

%% --- Codec: round-trip ---

%% Every value type an entity field can hold, through one frame. A codec that
%% only round-trips floats would pass a naive test and drop `hp` and `type` on the
%% first real game.
all_value_types_round_trip_test() ->
    Fields = #{
        ~"x" => 1.5,
        ~"hp" => 100,
        ~"alive" => true,
        ~"stunned" => false,
        ~"type" => ~"player",
        ~"target" => null
    },
    F = frame([#{op => add, slot => 5, gen => 0, id => uuid(), fields => Fields}]),
    ?assertEqual({ok, F}, roundtrip(F)).

envelope_round_trips_including_negative_coords_test() ->
    %% Zone coords run negative either side of the origin, so a signed encoding is
    %% load-bearing rather than cosmetic.
    F = (frame([]))#{zone => {-7, -1}, frame_seq => 16#1FFFFFFFFFFFFF, kf => true, tick => 0},
    ?assertEqual({ok, F}, roundtrip(F)).

%% An add carries the binding (slot AND id); update and remove carry the slot
%% alone. That asymmetry is the whole reason no separate mapping message exists.
only_an_add_carries_the_entity_id_test() ->
    F = frame([
        #{op => add, slot => 1, gen => 0, id => uuid(), fields => #{~"x" => 1.0}},
        #{op => update, slot => 1, gen => 0, fields => #{~"x" => 2.0}},
        #{op => remove, slot => 1, gen => 0}
    ]),
    {ok, #{records := [A, U, R]}} = roundtrip(F),
    ?assert(maps:is_key(id, A)),
    ?assertNot(maps:is_key(id, U)),
    ?assertNot(maps:is_key(id, R)),
    ?assertEqual(1, maps:get(slot, U)).

%% Ids go as text, not 16 raw bytes, so a client can compare an entity to the
%% player_id session.connected gave it without knowing how the wire packed it.
entity_id_survives_byte_for_byte_test() ->
    Id = ~"01a0115f-547e-714f-829f-408c855ab77b",
    F = frame([#{op => add, slot => 0, gen => 0, id => Id, fields => #{}}]),
    {ok, #{records := [#{id := Back}]}} = roundtrip(F),
    ?assertEqual(Id, Back).

%% The dictionary exists so repeated field names are paid for once. Forty records
%% sharing four names must not cost a hundred and sixty names.
repeated_field_names_are_paid_for_once_test() ->
    Fields = #{~"x" => 1.0, ~"y" => 2.0, ~"vx" => 0.5, ~"vy" => -0.5},
    One = frame([#{op => update, slot => 1, gen => 0, fields => Fields}]),
    Forty = frame([#{op => update, slot => I, gen => 0, fields => Fields} || I <- lists:seq(1, 40)]),
    {ok, B1} = asobi_wire:encode(One),
    {ok, B40} = asobi_wire:encode(Forty),
    %% Per-record growth must be the record cost alone, with no name text in it.
    PerRecord = (byte_size(B40) - byte_size(B1)) / 39,
    ?assert(PerRecord < 30),
    ?assertEqual({ok, Forty}, roundtrip(Forty)).

%% The number the design turns on: a steady-state delta has to fit one datagram.
forty_update_delta_fits_a_datagram_test() ->
    Fields = #{~"x" => 1.0, ~"y" => 2.0, ~"vx" => 0.5, ~"vy" => -0.5},
    F = frame([#{op => update, slot => I, gen => 0, fields => Fields} || I <- lists:seq(1, 40)]),
    {ok, Bin} = asobi_wire:encode(F),
    ?assert(byte_size(Bin) =< 1200),
    %% And decisively smaller than the JSON it replaces. Measured at 3.7x on this
    %% frame (3795 against 1039); the assertion is a 3x floor rather than the
    %% real figure, so a regression fails without the test needing an edit every
    %% time a byte moves.
    Json = iolist_to_binary(json:encode(json_shape(F))),
    ?assert(byte_size(Bin) * 3 < byte_size(Json)).

%% 32 dictionary slots is a hard cap because the index is five bits. Exceeding it
%% must refuse the frame: silently dropping fields is corruption the client can
%% never detect.
too_many_distinct_field_names_is_refused_test() ->
    Fields = #{integer_to_binary(I) => 1.0 || I <- lists:seq(1, 33)},
    F = frame([#{op => update, slot => 1, gen => 0, fields => Fields}]),
    ?assertEqual({error, dict_too_large}, asobi_wire:encode(F)),
    %% Exactly 32 is still fine, so the boundary is where it says it is.
    Ok = #{integer_to_binary(I) => 1.0 || I <- lists:seq(1, 32)},
    ?assertMatch(
        {ok, _},
        asobi_wire:encode(F#{records => [#{op => update, slot => 1, gen => 0, fields => Ok}]})
    ).

%% asobi#509. A Luerl table hands the zone whichever key form the game script
%% wrote, and an atom one reached `byte_size/1` and killed the zone gen_server
%% mid-tick - taking every subscriber's session with it. Atoms are the form the
%% text wire already renders as a plain JSON key, so the two wires agree.
atom_field_names_encode_as_their_text_form_test() ->
    Atoms = frame([#{op => update, slot => 1, gen => 0, fields => #{type => 7, ~"x" => 1.0}}]),
    Binaries = frame([
        #{op => update, slot => 1, gen => 0, fields => #{~"type" => 7, ~"x" => 1.0}}
    ]),
    ?assertEqual(asobi_wire:encode(Binaries), asobi_wire:encode(Atoms)),
    {ok, Bin} = asobi_wire:encode(Atoms),
    ?assertMatch({ok, #{records := [#{fields := #{~"type" := 7}}]}}, asobi_wire:decode(Bin)).

%% The invariant the length checks exist for, and the one the module was missing:
%% `encode/1` must never hand back bytes `decode/1` will not take. Erlang's bit
%% syntax truncates rather than raising, so an over-long name, id or string used to
%% produce a frame read at the wrong offset from that byte on - `{ok, Bytes}` from
%% the encoder and a discarded frame on the client, which is corruption the server
%% never hears about.
encode_never_produces_bytes_decode_rejects_test() ->
    Long = binary:copy(~"a", 300),
    Huge = binary:copy(~"b", 70_000),
    Frames = [
        frame([#{op => update, slot => 1, gen => 0, fields => #{Long => 1.0}}]),
        frame([#{op => add, slot => 1, gen => 0, id => Long, fields => #{~"x" => 1.0}}]),
        frame([#{op => update, slot => 1, gen => 0, fields => #{~"s" => Huge}}])
    ],
    [
        ?assertMatch({ok, _}, asobi_wire:decode(Bin))
     || F <- Frames, {ok, Bin} <- [asobi_wire:encode(F)]
    ],
    ?assertEqual({error, bad_field_name}, asobi_wire:encode(hd(Frames))),
    ?assertEqual({error, bad_entity_id}, asobi_wire:encode(lists:nth(2, Frames))),
    ?assertEqual({error, value_too_large}, asobi_wire:encode(lists:nth(3, Frames))).

%% The boundaries are where they say they are: the dictionary and the id both
%% count their length in one byte, and a string value in two.
length_limits_are_inclusive_test() ->
    Name = binary:copy(~"a", 255),
    ?assertMatch(
        {ok, _},
        asobi_wire:encode(
            frame([#{op => update, slot => 1, gen => 0, fields => #{Name => 1.0}}])
        )
    ),
    Id = binary:copy(~"i", 255),
    ?assertMatch(
        {ok, _},
        asobi_wire:encode(
            frame([#{op => add, slot => 1, gen => 0, id => Id, fields => #{~"x" => 1.0}}])
        )
    ),
    Str = binary:copy(~"s", 65_535),
    ?assertMatch(
        {ok, _},
        asobi_wire:encode(
            frame([#{op => update, slot => 1, gen => 0, fields => #{~"s" => Str}}])
        )
    ),
    %% One byte past each is the refusal, so the boundary is exact rather than
    %% approximately right.
    ?assertEqual(
        {error, bad_field_name},
        asobi_wire:encode(
            frame([
                #{op => update, slot => 1, gen => 0, fields => #{binary:copy(~"a", 256) => 1.0}}
            ])
        )
    ),
    ?assertEqual(
        {error, bad_entity_id},
        asobi_wire:encode(
            frame([
                #{
                    op => add,
                    slot => 1,
                    gen => 0,
                    id => binary:copy(~"i", 256),
                    fields => #{~"x" => 1.0}
                }
            ])
        )
    ),
    ?assertEqual(
        {error, value_too_large},
        asobi_wire:encode(
            frame([
                #{
                    op => update,
                    slot => 1,
                    gen => 0,
                    fields => #{~"s" => binary:copy(~"s", 65_536)}
                }
            ])
        )
    ).

%% An atom key is bounded by the same 255 bytes a binary one is, and an atom of 255
%% CHARACTERS can be four times that in UTF-8 - so the check has to be on the
%% rendered text rather than on the atom.
atom_field_name_past_the_limit_refuses_the_frame_test() ->
    Wide = list_to_atom(lists:duplicate(200, 16#4E2D)),
    F = frame([#{op => update, slot => 1, gen => 0, fields => #{Wide => 1.0}}]),
    ?assert(byte_size(atom_to_binary(Wide, utf8)) > 255),
    ?assertEqual({error, bad_field_name}, asobi_wire:encode(F)),
    %% The boundary is where it says it is, on the rendered bytes: 85 three-byte
    %% characters is exactly 255, one ASCII character more is 256.
    Exact = list_to_atom(lists:duplicate(85, 16#4E2D)),
    ?assertEqual(255, byte_size(atom_to_binary(Exact, utf8))),
    ?assertMatch(
        {ok, _},
        asobi_wire:encode(frame([#{op => update, slot => 1, gen => 0, fields => #{Exact => 1.0}}]))
    ),
    Over = list_to_atom(lists:duplicate(85, 16#4E2D) ++ "a"),
    ?assertEqual(256, byte_size(atom_to_binary(Over, utf8))),
    ?assertEqual(
        {error, bad_field_name},
        asobi_wire:encode(frame([#{op => update, slot => 1, gen => 0, fields => #{Over => 1.0}}]))
    ),
    %% ...and one that fits still encodes, so the bound is on length not on atoms.
    Narrow = list_to_atom(lists:duplicate(80, 16#4E2D)),
    ?assertMatch(
        {ok, _},
        asobi_wire:encode(frame([#{op => update, slot => 1, gen => 0, fields => #{Narrow => 1.0}}]))
    ).

%% asobi#509 again, one branch below where it was fixed. The entity id reaches
%% `byte_size/1` too, and a Lua table that mixes named and numeric keys hands the
%% zone a non-binary one - so this raised, and the zone died mid-tick.
non_binary_entity_id_refuses_the_frame_test() ->
    F = frame([#{op => add, slot => 1, gen => 0, id => 5.0, fields => #{~"x" => 1.0}}]),
    ?assertEqual({error, bad_entity_id}, asobi_wire:encode(F)).

%% A record with no `fields` at all is legal on both wires - an add for an entity
%% with an empty state, and every remove. Normalising must leave those alone
%% rather than treating the absent key as an empty one it then has to rebuild.
records_without_fields_survive_normalisation_test() ->
    Add = frame([#{op => add, slot => 1, gen => 0, id => ~"e1"}]),
    ?assertEqual({ok, Add}, roundtrip(Add)),
    Remove = frame([#{op => remove, slot => 1, gen => 0}]),
    ?assertEqual({ok, Remove}, roundtrip(Remove)).

%% Total on the field names, which is the whole point: the encoder runs inside the
%% zone's tick, so anything it cannot express has to come back as a value rather
%% than as an exception.
non_textual_field_names_refuse_the_frame_test() ->
    Numeric = frame([#{op => update, slot => 1, gen => 0, fields => #{1 => 1.0}}]),
    ?assertEqual({error, bad_field_name}, asobi_wire:encode(Numeric)),
    Tuple = frame([#{op => update, slot => 1, gen => 0, fields => #{{a, b} => 1.0}}]),
    ?assertEqual({error, bad_field_name}, asobi_wire:encode(Tuple)).

%% Keeping one of two keys that normalise to the same name would put a value on
%% the binary wire that the text wire does not carry, which is the disagreement
%% the whole-frame fallback exists to prevent.
colliding_field_names_refuse_the_frame_test() ->
    F = frame([#{op => update, slot => 1, gen => 0, fields => #{type => 1, ~"type" => 2}}]),
    ?assertEqual({error, ambiguous_field_name}, asobi_wire:encode(F)).

%% The leave-removal frame carries no position in the zone's stream - on the text
%% wire that is said by omitting frame_seq, which a fixed-layout binary frame
%% cannot do. If the kind byte did not survive, that frame would decode as
%% sequence 0 and every client past its first frame would discard the one message
%% that clears its ghosts.
frame_kind_survives_and_is_distinguishable_test() ->
    Recs = [#{op => remove, slot => 3, gen => 0}],
    Seq = frame(Recs),
    Ungated = (frame(Recs))#{kind => ungated, frame_seq => 0},
    ?assertEqual({ok, Seq}, roundtrip(Seq)),
    ?assertEqual({ok, Ungated}, roundtrip(Ungated)),
    {ok, A} = asobi_wire:encode(Seq),
    {ok, B} = asobi_wire:encode(Ungated),
    ?assertNotEqual(binary:first(A), binary:first(B)).

%% --- Codec: hostile input ---

%% These bytes will one day arrive on a datagram from an unauthenticated source,
%% so decode must be TOTAL. A decoder that raises is a remote crash; one that only
%% works on its own output is not a decoder.
decode_is_total_test() ->
    {ok, Good} = asobi_wire:encode(
        frame([#{op => update, slot => 1, gen => 0, fields => #{~"x" => 1.0}}])
    ),
    Cases = [
        {"empty", <<>>},
        {"one byte", <<1>>},
        {"truncated envelope", binary:part(Good, 0, 10)},
        {"truncated mid-record", binary:part(Good, 0, byte_size(Good) - 2)},
        {"trailing junk", <<Good/binary, 0, 0, 0>>},
        {"unknown kind byte", <<9, (binary:part(Good, 1, byte_size(Good) - 1))/binary>>},
        {"declared count too high", <<
            (binary:part(Good, 0, byte_size(Good) - 6))/binary, 255, 255
        >>}
    ],
    [
        ?assertEqual({error, malformed}, asobi_wire:decode(B), Label)
     || {Label, B} <- Cases
    ],
    %% Random noise, not just hand-picked mutations.
    [
        ?assertMatch({error, malformed}, asobi_wire:decode(crypto:strong_rand_bytes(N)))
     || N <- lists:seq(1, 60)
    ].

%% --- Slots ---

slots_track_the_baseline_test() ->
    S0 = asobi_wire_slots:new(),
    {ok, S1} = asobi_wire_slots:sync(#{~"a" => 1, ~"b" => 1}, S0),
    ?assertEqual(2, asobi_wire_slots:count(S1)),
    ?assertMatch({ok, {_Slot, _Gen}}, asobi_wire_slots:slot_of(~"a", S1)),
    %% An entity leaving the baseline releases its slot.
    {ok, S2} = asobi_wire_slots:sync(#{~"b" => 1}, S1),
    ?assertEqual(error, asobi_wire_slots:slot_of(~"a", S2)),
    ?assertEqual(1, asobi_wire_slots:count(S2)).

%% A broadcast tick that changed nothing still advances the baseline, so syncing
%% the same map twice must not churn slots - a client would see every entity
%% removed and re-added.
sync_is_idempotent_test() ->
    Ents = #{~"a" => 1, ~"b" => 1, ~"c" => 1},
    {ok, S1} = asobi_wire_slots:sync(Ents, asobi_wire_slots:new()),
    {ok, S2} = asobi_wire_slots:sync(Ents, S1),
    ?assertEqual(
        [asobi_wire_slots:slot_of(I, S1) || I <- maps:keys(Ents)],
        [asobi_wire_slots:slot_of(I, S2) || I <- maps:keys(Ents)]
    ).

%% Two live entities must never share a slot. This is the invariant whose failure
%% would be silent cross-entity corruption on every client in the zone.
slots_are_unique_while_live_test() ->
    Ids = [integer_to_binary(I) || I <- lists:seq(1, 500)],
    {ok, S} = asobi_wire_slots:sync(maps:from_keys(Ids, 1), asobi_wire_slots:new()),
    Assigned = [
        begin
            {ok, {N, _}} = asobi_wire_slots:slot_of(I, S),
            N
        end
     || I <- Ids
    ],
    ?assertEqual(500, length(lists:usort(Assigned))),
    ?assert(lists:all(fun(N) -> N >= 0 andalso N < 65536 end, Assigned)).

%% Handed out monotonically, so a freed slot is reused as late as the space
%% allows rather than immediately - which is the mitigation for slot reuse, with
%% frame_seq as the actual guarantee.
freed_slots_are_not_reused_immediately_test() ->
    {ok, S1} = asobi_wire_slots:sync(#{~"a" => 1, ~"b" => 1}, asobi_wire_slots:new()),
    {ok, {SlotA, _}} = asobi_wire_slots:slot_of(~"a", S1),
    {ok, S2} = asobi_wire_slots:sync(#{~"b" => 1}, S1),
    {ok, S3} = asobi_wire_slots:sync(#{~"b" => 1, ~"c" => 1}, S2),
    {ok, {SlotC, _}} = asobi_wire_slots:slot_of(~"c", S3),
    ?assertNotEqual(SlotA, SlotC).

%% Wraparound has to find the freed gap rather than hand out a live slot or spin.
%%
%% This fills the WHOLE 65536 space on purpose. A smaller test proves nothing:
%% monotonic allocation alone keeps slots distinct until the cursor laps, so the
%% occupancy check is unreachable below a full space and a test that stops at a few
%% hundred entities passes with the check deleted. Verified by deleting it.
wraparound_reuses_freed_slots_without_stealing_live_ones_test() ->
    Full = [integer_to_binary(I) || I <- lists:seq(1, 65536)],
    {ok, S1} = asobi_wire_slots:sync(maps:from_keys(Full, 1), asobi_wire_slots:new()),
    ?assertEqual(65536, asobi_wire_slots:count(S1)),

    %% Free three, from positions the cursor has long passed.
    Freed = [~"10", ~"5000", ~"40000"],
    Kept = maps:from_keys(Full -- Freed, 1),
    FreedSlots = lists:sort([
        begin
            {ok, {N, _}} = asobi_wire_slots:slot_of(I, S1),
            N
        end
     || I <- Freed
    ]),
    {ok, S2} = asobi_wire_slots:sync(Kept, S1),

    %% Three newcomers must land exactly in the three holes: the space is
    %% otherwise full, so any other answer means a live entity was displaced.
    New = maps:merge(Kept, maps:from_keys([~"n1", ~"n2", ~"n3"], 1)),
    {ok, S3} = asobi_wire_slots:sync(New, S2),
    ?assertEqual(65536, asobi_wire_slots:count(S3)),
    NewSlots = lists:sort([
        begin
            {ok, {N, _}} = asobi_wire_slots:slot_of(I, S3),
            N
        end
     || I <- [~"n1", ~"n2", ~"n3"]
    ]),
    ?assertEqual(FreedSlots, NewSlots),

    %% And nothing that was kept moved or collided.
    Live = [
        begin
            {ok, {N, _}} = asobi_wire_slots:slot_of(I, S3),
            N
        end
     || I <- maps:keys(New)
    ],
    ?assertEqual(65536, length(lists:usort(Live))).

%% The generation is what lets a lossy carrier tell the entity holding slot 5 now
%% from the one that held it a moment ago (ADR 0012, decision 12). It must advance
%% on REBIND and hold steady otherwise, or a datagram client either drops live
%% poses or applies stale ones.
generation_advances_only_when_a_slot_is_rebound_test() ->
    {ok, S1} = asobi_wire_slots:sync(#{~"a" => 1}, asobi_wire_slots:new()),
    {ok, {Slot, Gen0}} = asobi_wire_slots:slot_of(~"a", S1),

    %% A baseline that changed nothing must not churn the generation.
    {ok, S2} = asobi_wire_slots:sync(#{~"a" => 1}, S1),
    ?assertEqual({ok, {Slot, Gen0}}, asobi_wire_slots:slot_of(~"a", S2)),

    %% Free it, then force the cursor all the way round so the same slot comes
    %% back. Its generation must not come back with it.
    {ok, S3} = asobi_wire_slots:sync(#{}, S2),
    Filler = maps:from_keys([integer_to_binary(I) || I <- lists:seq(1, 65535)], 1),
    {ok, S4} = asobi_wire_slots:sync(Filler, S3),
    {ok, S5} = asobi_wire_slots:sync(Filler#{~"b" => 1}, S4),
    ?assertEqual({ok, {Slot, (Gen0 + 1) rem 256}}, asobi_wire_slots:slot_of(~"b", S5)).

%% One past the space is exhaustion, and it must be an error rather than a
%% rebound live slot: rebinding a slot in use is corruption every client in the
%% zone would apply and none could detect.
exhaustion_is_an_error_not_a_silent_rebind_test() ->
    Full = maps:from_keys([integer_to_binary(I) || I <- lists:seq(1, 65536)], 1),
    {ok, S} = asobi_wire_slots:sync(Full, asobi_wire_slots:new()),
    ?assertEqual({error, exhausted}, asobi_wire_slots:sync(Full#{~"one_too_many" => 1}, S)).

%% --- Fixture corpus ---

%% The committed corpus is the only thing seven SDK decoders can check themselves
%% against, so it has to still be what the encoder produces. A codec change that
%% nobody propagated fails here rather than in a shipped game.
%%
%% If this fails and the change was intended: asobi_wire_fixtures:generate(),
%% commit the bytes, and update every SDK decoder in the same change.
fixture_corpus_matches_the_encoder_test() ->
    ?assertMatch({ok, N} when N > 0, asobi_wire_fixtures:check()).

%% And the corpus must survive the decoder, or an SDK author debugging against it
%% is chasing a fault in the fixture rather than in their code.
fixture_corpus_round_trips_test() ->
    [
        begin
            {ok, Bin} = file:read_file(asobi_wire_fixtures:path(Name)),
            ?assertEqual({ok, Frame}, asobi_wire:decode(Bin), Name)
        end
     || {Name, Frame} <- asobi_wire_fixtures:frames()
    ].

%% --- Helpers ---

frame(Records) ->
    #{
        kind => sequenced,
        zone => {0, 0},
        frame_seq => 17,
        kf => false,
        tick => 4711,
        records => Records
    }.

roundtrip(F) ->
    {ok, Bin} = asobi_wire:encode(F),
    asobi_wire:decode(Bin).

%% The JSON frame carrying the same information, for the size comparison. Ids are
%% real 36-char UUIDv7s because that is what the JSON wire actually sends.
json_shape(#{zone := {ZX, ZY}, frame_seq := Seq, kf := Kf, tick := Tick, records := Recs}) ->
    #{
        ~"type" => ~"world.tick",
        ~"payload" => #{
            ~"zone" => [ZX, ZY],
            ~"frame_seq" => Seq,
            ~"kf" => Kf,
            ~"tick" => Tick,
            ~"updates" => [json_delta(R) || R <- Recs]
        }
    }.

json_delta(#{op := Op} = R) ->
    Base = #{~"op" => json_op(Op), ~"id" => maps:get(id, R, uuid())},
    maps:merge(Base, maps:get(fields, R, #{})).

json_op(add) -> ~"a";
json_op(update) -> ~"u";
json_op(remove) -> ~"r".

uuid() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(
        io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])
    ).
