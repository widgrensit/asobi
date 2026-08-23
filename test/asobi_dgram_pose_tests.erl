-module(asobi_dgram_pose_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pose production: the manifest, quantisation, and the axial rotation that covers
%% entities at rest.

pose_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a manifest is required, never guessed", fun manifest_is_required/0},
        {"more than eight fields is refused", fun eight_fields_max/0},
        {"only changed transform fields are sent", fun only_changed/0},
        {"values are absolute, not the diff", fun values_are_absolute/0},
        {"rmask and the value order come from one traversal", fun mask_matches_order/0},
        {"an out-of-range value saturates and is counted", fun saturates/0},
        {"entities at rest are refreshed by the axial rotation", fun axial_rotation/0},
        {"the whole zone is covered within one period", fun axial_covers_everything/0},
        {"a non-numeric transform field is skipped, not guessed", fun non_numeric_skipped/0},
        {"an entity with no slot is skipped silently", fun no_slot_skipped/0},
        {"no binary wire, no manifest", fun no_binary_wire_no_manifest/0}
    ]}.

setup() ->
    Prev = [{K, application:get_env(asobi, K)} || K <- [dgram_pose, binary_wire]],
    %% `manifest/0` is the plane's carrier rule: the binary wire is what binds a
    %% slot to an entity, so without it there is no manifest to have.
    application:set_env(asobi, binary_wire, true),
    application:set_env(asobi, dgram_pose, #{
        period_ticks => 4,
        fields => [
            #{name => ~"x", scale => 100},
            #{name => ~"y", scale => 100},
            #{name => ~"vx", scale => 100}
        ]
    }),
    Prev.

cleanup(Prev) ->
    [
        case V of
            undefined -> application:unset_env(asobi, K);
            {ok, Val} -> application:set_env(asobi, K, Val)
        end
     || {K, V} <- Prev
    ],
    ok.

%% --- The manifest ---

%% Guessing at `x` and `y` would silently pick a scale for a game whose world may
%% be a thousand times larger than the guess assumes.
manifest_is_required() ->
    application:unset_env(asobi, dgram_pose),
    ?assertEqual(disabled, asobi_dgram_pose:manifest()),
    application:set_env(asobi, dgram_pose, #{fields => []}),
    ?assertEqual(disabled, asobi_dgram_pose:manifest()),
    application:set_env(asobi, dgram_pose, #{fields => [#{name => ~"x", scale => 0}]}),
    ?assertEqual(disabled, asobi_dgram_pose:manifest()).

%% rmask is one byte, so a ninth field has nowhere to live. Refused rather than
%% truncated: a silently dropped field is a coordinate that never updates.
eight_fields_max() ->
    Nine = [#{name => integer_to_binary(I), scale => 10} || I <- lists:seq(1, 9)],
    application:set_env(asobi, dgram_pose, #{fields => Nine}),
    ?assertEqual(disabled, asobi_dgram_pose:manifest()),
    Eight = lists:sublist(Nine, 8),
    application:set_env(asobi, dgram_pose, #{fields => Eight}),
    ?assertMatch({ok, #{fields := [_, _, _, _, _, _, _, _]}}, asobi_dgram_pose:manifest()).

%% --- Records ---

only_changed() ->
    {ok, M} = asobi_dgram_pose:manifest(),
    Entities = #{~"a" => pos(1.0, 2.0), ~"b" => pos(3.0, 4.0)},
    {ok, Slots} = asobi_wire_slots:sync(Entities, asobi_wire_slots:new()),
    %% Tick 1 with period 4: only slots where slot rem 4 =:= 1 are force-included,
    %% so pick a tick whose phase misses both to isolate the "changed" path.
    {Records, 0} = asobi_dgram_pose:records(
        #{~"a" => [~"x"]}, Entities, Slots, M, phase_miss(Slots)
    ),
    ?assertEqual(1, length(Records)),
    [#{rmask := RMask, values := Values}] = Records,
    ?assertEqual(2#001, RMask),
    ?assertEqual([100], Values).

%% A pose is ABSOLUTE. The diff decides which fields to include; it never decides
%% what they say, or a client that missed one frame would apply a delta twice.
values_are_absolute() ->
    {ok, M} = asobi_dgram_pose:manifest(),
    Entities = #{~"a" => pos(7.5, 9.25)},
    {ok, Slots} = asobi_wire_slots:sync(Entities, asobi_wire_slots:new()),
    {[#{values := Values}], 0} =
        asobi_dgram_pose:records(#{~"a" => [~"x", ~"y"]}, Entities, Slots, M, phase_miss(Slots)),
    ?assertEqual([750, 925], Values).

%% One traversal produces both, because two would eventually disagree - and a
%% disagreement puts every field one place out on the client, which decodes as
%% plausible nonsense rather than as an error.
mask_matches_order() ->
    {ok, M} = asobi_dgram_pose:manifest(),
    Entities = #{~"a" => #{~"x" => 1.0, ~"vx" => 5.0}},
    {ok, Slots} = asobi_wire_slots:sync(Entities, asobi_wire_slots:new()),
    {[#{rmask := RMask, values := Values}], 0} =
        asobi_dgram_pose:records(
            #{~"a" => [~"x", ~"y", ~"vx"]}, Entities, Slots, M, phase_miss(Slots)
        ),
    %% y is absent from the entity, so its bit is clear and no value is written.
    ?assertEqual(2#101, RMask),
    ?assertEqual([100, 500], Values),
    ?assertEqual(2, count_bits(RMask)),
    ?assertEqual(count_bits(RMask), length(Values)).

%% Wrapping would teleport an entity from one edge of the world to the other,
%% which looks exactly like a game bug. Saturation looks like what it is.
saturates() ->
    {ok, M} = asobi_dgram_pose:manifest(),
    Entities = #{~"a" => pos(1.0e6, -1.0e6)},
    {ok, Slots} = asobi_wire_slots:sync(Entities, asobi_wire_slots:new()),
    {[#{values := Values}], Saturated} =
        asobi_dgram_pose:records(#{~"a" => [~"x", ~"y"]}, Entities, Slots, M, phase_miss(Slots)),
    ?assertEqual([32767, -32768], Values),
    ?assertEqual(2, Saturated).

%% --- Axial rotation ---

%% An entity that stops moving stops being mentioned, so a client that missed its
%% last update would keep it wrong forever. This is what fixes that, with no acks
%% and no per-client state.
axial_rotation() ->
    {ok, M} = asobi_dgram_pose:manifest(),
    Entities = #{~"a" => pos(1.0, 2.0)},
    {ok, Slots} = asobi_wire_slots:sync(Entities, asobi_wire_slots:new()),
    {ok, {Slot, _}} = asobi_wire_slots:slot_of(~"a", Slots),

    %% Nothing changed at all.
    {Off, 0} = asobi_dgram_pose:records(#{}, Entities, Slots, M, Slot + 1),
    ?assertEqual([], Off),

    %% ...until this entity's turn comes round, when it is sent in full.
    {[#{rmask := RMask}], 0} = asobi_dgram_pose:records(#{}, Entities, Slots, M, Slot),
    ?assertEqual(2#011, RMask).

%% The guarantee the rotation makes: within one period every entity is refreshed,
%% so nothing can stay stale for longer than that however unlucky the loss.
axial_covers_everything() ->
    {ok, M} = asobi_dgram_pose:manifest(),
    Ids = [integer_to_binary(I) || I <- lists:seq(1, 40)],
    Entities = maps:from_keys(Ids, pos(1.0, 2.0)),
    {ok, Slots} = asobi_wire_slots:sync(Entities, asobi_wire_slots:new()),
    #{period_ticks := Period} = M,
    Slotted = [S || Tick <- lists:seq(0, Period - 1), S <- tick_slots(Entities, Slots, M, Tick)],
    Seen = sets:from_list(Slotted, [{version, 2}]),
    ?assertEqual(40, sets:size(Seen)).

%% A pattern in a GENERATOR is a filter, not a match: `{Records, 0} <- [...]`
%% would silently skip a saturated tick, where the fold this replaced asserted
%% on the count. asobi_dgram_pose treats saturation as something worth knowing
%% before players report teleporting, so it stays a hard match.
-spec tick_slots(map(), asobi_wire_slots:slots(), map(), non_neg_integer()) -> [integer()].
tick_slots(Entities, Slots, M, Tick) ->
    {Records, 0} = asobi_dgram_pose:records(#{}, Entities, Slots, M, Tick),
    [slot_of(R) || R <- Records].

-spec slot_of(map()) -> integer().
slot_of(#{slot := S}) -> S.

%% --- Edges ---

%% A game putting a string where a coordinate goes is a game bug, and a codec that
%% guessed a number for it would hide the bug behind a plausible position.
non_numeric_skipped() ->
    {ok, M} = asobi_dgram_pose:manifest(),
    Entities = #{~"a" => #{~"x" => ~"not a number", ~"y" => 2.0}},
    {ok, Slots} = asobi_wire_slots:sync(Entities, asobi_wire_slots:new()),
    {[#{rmask := RMask, values := Values}], 0} =
        asobi_dgram_pose:records(#{~"a" => [~"x", ~"y"]}, Entities, Slots, M, phase_miss(Slots)),
    ?assertEqual(2#010, RMask),
    ?assertEqual([200], Values).

%% Not a defect and not worth a log line: an entity can be in the baseline before
%% the slot map has caught up, and the next frame carries it.
no_slot_skipped() ->
    {ok, M} = asobi_dgram_pose:manifest(),
    Entities = #{~"a" => pos(1.0, 2.0)},
    Empty = asobi_wire_slots:new(),
    ?assertEqual({[], 0}, asobi_dgram_pose:records(#{~"a" => [~"x"]}, Entities, Empty, M, 0)).

%% --- Helpers ---

pos(X, Y) -> #{~"x" => X, ~"y" => Y}.

%% A tick whose axial phase force-includes nothing, so a test can isolate the
%% "something changed" path from the rotation.
phase_miss(Slots) ->
    Taken = [S || I <- [~"a", ~"b"], {ok, {S, _}} <- [asobi_wire_slots:slot_of(I, Slots)]],
    hd([T || T <- lists:seq(0, 3), not lists:member(T, [S rem 4 || S <- Taken])]).

count_bits(N) -> length([B || B <- lists:seq(0, 7), N band (1 bsl B) =/= 0]).

%% asobi#509. One predicate for the plane's carrier rule, read by the zone that
%% emits poses AND by the mint that advertises the manifest to a client. Splitting
%% them let the mint promise a plane the zone would never send, which a client
%% reads as degraded and answers with a rebind storm.
no_binary_wire_no_manifest() ->
    ?assertMatch({ok, #{fields := [_ | _]}}, asobi_dgram_pose:manifest()),
    application:set_env(asobi, binary_wire, false),
    ?assertEqual(disabled, asobi_dgram_pose:manifest()).
