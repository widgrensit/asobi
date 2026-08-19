-module(asobi_zone_binary_wire_tests).
-include_lib("eunit/include/eunit.hrl").

%% The zone's half of the binary wire (ADR 0013): both buffers in one message,
%% slots tracking the broadcast baseline, and a text fallback that is never wrong.

-define(GAME, asobi_test_world_game).

binary_wire_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"off by default, and the frozen message shape is untouched",
            fun off_by_default_keeps_the_frozen_shape/0},
        {"on, a delta carries both wires in one message and they agree",
            fun delta_carries_both_wires/0},
        {"the keyframe carries the slot bindings, or a binary client has none",
            fun keyframe_carries_slot_bindings/0},
        {"a removal names an entity that already left the baseline",
            fun removal_still_has_a_slot/0},
        {"leaving a zone sends an UNGATED binary frame, not sequence zero",
            fun leave_removals_are_ungated/0},
        {"a slot survives across ticks so update records stay bound",
            fun slots_are_stable_across_ticks/0},
        {"a non-scalar field drops the whole zone to text rather than diverging",
            fun non_scalar_field_falls_back_to_text/0},
        {"an atom-keyed entity encodes rather than killing the zone",
            fun atom_field_names_survive_the_tick/0},
        {"a passing refusal is repaired by a keyframe on the next frame",
            fun refusal_is_repaired_by_a_keyframe/0},
        {"a structural refusal latches the zone to text rather than stranding slots",
            fun structural_refusal_latches_to_text/0},
        {"a latched zone tries the binary wire again once the entity is gone",
            fun latch_retries_and_recovers/0}
    ]}.

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    Prev = application:get_env(asobi, binary_wire),
    Prev.

cleanup(Prev) ->
    application:unset_env(asobi, binary_wire_retry_ms),
    case Prev of
        undefined -> application:unset_env(asobi, binary_wire);
        {ok, V} -> application:set_env(asobi, binary_wire, V)
    end.

%% --- Tests ---

%% Seven SDKs consume this wire by copying source, three with no version pin, so
%% a shipped game must keep working untouched. The default is the proof.
off_by_default_keeps_the_frozen_shape() ->
    application:unset_env(asobi, binary_wire),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    ?assertMatch({zone_keyframe, _, _}, recv()),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 1),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),
    gen_server:stop(Pid).

delta_carries_both_wires() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.5, ~"hp" => 7}),
    asobi_zone:tick(Pid, 1),
    {zone_delta_raw, Json, Bin} = recv_delta(),
    {ok, Frame} = asobi_wire:decode(Bin),
    #{~"payload" := #{~"frame_seq" := Seq, ~"updates" := [Update]}} = json:decode(Json),
    %% The two wires must agree on everything that is not the id encoding: same
    %% sequence position, same op, same fields. A binary frame that quietly says
    %% something else is worse than no binary frame.
    ?assertMatch(#{kind := sequenced, zone := {0, 0}, kf := false}, Frame),
    ?assertEqual(Seq, maps:get(frame_seq, Frame)),
    ?assertMatch(
        [#{op := add, id := ~"e1", fields := #{~"x" := 1.5, ~"hp" := 7}}],
        maps:get(
            records, Frame
        )
    ),
    ?assertEqual(~"a", maps:get(~"op", Update)),
    gen_server:stop(Pid).

%% The slot->id bindings ride the add records, and a keyframe is all-adds, so
%% this is the frame that gives a binary client its whole mapping. Without it a
%% joining client sees updates for slots it has never heard of.
keyframe_carries_slot_bindings() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0}),
    asobi_zone:add_entity(Pid, ~"e2", #{~"x" => 2.0}),
    %% Advance the broadcast baseline; slots track it, not the sim entities.
    asobi_zone:tick(Pid, 1),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    {zone_keyframe, _Meta, _Deltas, Bin} = recv_keyframe(),
    {ok, #{kf := Kf, records := Recs}} = asobi_wire:decode(Bin),
    ?assert(Kf),
    ?assertEqual(2, length(Recs)),
    ?assert(lists:all(fun(#{op := Op}) -> Op =:= add end, Recs)),
    ?assertEqual([~"e1", ~"e2"], lists:sort([Id || #{id := Id} <- Recs])),
    ?assertEqual(2, length(lists:usort([S || #{slot := S} <- Recs]))),
    gen_server:stop(Pid).

%% The trap the union sync exists for: a removal names an entity that has already
%% left the new baseline, so releasing its slot first would leave it slotless in
%% the very frame announcing its departure - and the frame would silently drop to
%% text on every removal.
removal_still_has_a_slot() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0}),
    asobi_zone:tick(Pid, 1),
    {zone_delta_raw, _, AddBin} = recv_delta(),
    {ok, #{records := [#{slot := Slot}]}} = asobi_wire:decode(AddBin),
    asobi_zone:remove_entity(Pid, ~"e1"),
    asobi_zone:tick(Pid, 2),
    {zone_delta_raw, _, RemBin} = recv_delta(),
    ?assertMatch({ok, #{records := [#{op := remove, slot := Slot}]}}, asobi_wire:decode(RemBin)),
    gen_server:stop(Pid).

%% The leave mirror is applied ungated on the text wire because it carries no
%% frame_seq. Encoded as sequence 0 on the binary wire, every client past its
%% first frame would discard the one message that clears its ghosts.
leave_removals_are_ungated() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0}),
    asobi_zone:tick(Pid, 1),
    _ = recv_delta(),
    asobi_zone:unsubscribe(Pid, ~"p1"),
    {zone_removals, _Coords, _Deltas, Bin} = recv_removals(),
    ?assertMatch({ok, #{kind := ungated, records := [#{op := remove}]}}, asobi_wire:decode(Bin)),
    gen_server:stop(Pid).

%% An update record carries the slot alone, so the slot has to mean the same
%% entity on the tick after the add. A per-frame allocation would look correct in
%% a single-frame test and rebind every entity in a running game.
slots_are_stable_across_ticks() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0}),
    asobi_zone:tick(Pid, 1),
    {zone_delta_raw, _, AddBin} = recv_delta(),
    {ok, #{records := [#{op := add, slot := Slot}]}} = asobi_wire:decode(AddBin),
    %% add_entity on a live id replaces its state, which is what the diff sees.
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 9.0}),
    asobi_zone:tick(Pid, 2),
    {zone_delta_raw, _, UpBin} = recv_delta(),
    ?assertMatch(
        {ok, #{records := [#{op := update, slot := Slot, fields := #{~"x" := 9.0}}]}},
        asobi_wire:decode(UpBin)
    ),
    gen_server:stop(Pid).

%% asobi_wire carries six scalar types. Dropping a list field from the binary
%% frame while the text frame keeps it would make the two wires disagree about
%% what an entity IS, so the zone stays on text entirely instead.
non_scalar_field_falls_back_to_text() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"inventory" => [~"sword"]}),
    asobi_zone:tick(Pid, 1),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),
    gen_server:stop(Pid).

%% --- Helpers ---

start_zone() ->
    {ok, Pid} = asobi_zone:start_link(#{
        world_id => ~"test_world",
        coords => {0, 0},
        ticker_pid => self(),
        game_module => ?GAME,
        broadcast_interval => 1,
        zone_state => #{}
    }),
    Pid.

recv() ->
    receive
        {asobi_message, Msg} -> Msg
    after 1000 -> timeout
    end.

recv_delta() -> recv_matching(fun(M) -> element(1, M) =:= zone_delta_raw end).
recv_keyframe() -> recv_matching(fun(M) -> element(1, M) =:= zone_keyframe end).
recv_removals() -> recv_matching(fun(M) -> element(1, M) =:= zone_removals end).

%% The zone also sends acks and tick receipts; skip past them rather than
%% assert on message order, which is not what any of these tests are about.
recv_matching(Pred) ->
    case recv() of
        timeout ->
            timeout;
        Msg ->
            case Pred(Msg) of
                true -> Msg;
                false -> recv_matching(Pred)
            end
    end.

%% asobi#509. Field names out of a Luerl `zone_tick` can be atoms, and the encoder
%% called `byte_size/1` on them - a badarg inside the tick, so the zone
%% gen_server died and every subscriber's WS handler followed it into a call on a
%% dead pid. From the players' side that was a hung loading screen with nothing
%% pointing at the wire.
atom_field_names_survive_the_tick() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{type => ~"ship", ~"x" => 1.0}),
    asobi_zone:tick(Pid, 1),
    {zone_delta_raw, _Json, Bin} = recv_delta(),
    {ok, #{records := [#{fields := Fields}]}} = asobi_wire:decode(Bin),
    ?assertEqual(#{~"type" => ~"ship", ~"x" => 1.0}, Fields),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

%% asobi#510. A text frame carries no slots, so every binding its `add` records
%% would have established is missing on every binary client - and the NEXT
%% successful binary frame then names those slots in `op:"u"` records the client
%% drops, with a contiguous `frame_seq` that gives it no reason to resync. The
%% repair is the one ADR 0013 decision 4 already names: send a keyframe, which is
%% all-adds and re-establishes the whole mapping.
refusal_is_repaired_by_a_keyframe() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0}),
    asobi_zone:tick(Pid, 1),
    ?assertMatch({zone_delta_raw, _, _}, recv_delta()),

    %% A list has no binary form, so the frame introducing e2 is text.
    asobi_zone:add_entity(Pid, ~"e2", #{~"x" => 2.0, ~"path" => [1, 2]}),
    asobi_zone:tick(Pid, 2),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),

    %% e2 leaves, so the zone can encode again - and what it sends is a keyframe,
    %% not the delta, because a binary client's slot table is a frame behind.
    asobi_zone:remove_entity(Pid, ~"e2"),
    asobi_zone:tick(Pid, 3),
    {zone_delta_raw, _Json, Bin} = recv_delta(),
    {ok, #{kf := Kf, records := Records}} = asobi_wire:decode(Bin),
    ?assert(Kf),
    ?assertEqual([{add, ~"e1"}], [{Op, Id} || #{op := Op, id := Id} <- Records]),
    gen_server:stop(Pid).

%% When the cause is the shape of the game's entities rather than one frame, every
%% keyframe after it refuses too. Streaming binary frames whose slots no client can
%% bind is worse than not using the wire, so the zone gives it up for its life and
%% everyone falls back to text - which carries everything, and which a binary
%% client handles by construction.
structural_refusal_latches_to_text() ->
    application:set_env(asobi, binary_wire, true),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0}),
    asobi_zone:add_entity(Pid, ~"e2", #{~"x" => 2.0, ~"path" => [1, 2]}),
    asobi_zone:tick(Pid, 1),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),

    %% The rebind keyframe refuses for the same reason, so the wire latches off.
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 3.0}),
    asobi_zone:tick(Pid, 2),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),

    %% And stays off, including for an entity that could be encoded on its own.
    asobi_zone:remove_entity(Pid, ~"e2"),
    asobi_zone:tick(Pid, 3),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 4.0}),
    asobi_zone:tick(Pid, 4),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),
    gen_server:stop(Pid).

%% Latching for the zone's life is correct and, in a persistent world, expensive:
%% one entity carrying a debug field for ten seconds would cost every player the
%% datagram plane until the zone restarted. So the zone asks again on a doubling
%% backoff, and the retry frame is a keyframe - a successful one rebinds every
%% client rather than stranding the slots it just allocated.
latch_retries_and_recovers() ->
    application:set_env(asobi, binary_wire, true),
    %% Ask again on the next broadcast rather than in a minute, which is the
    %% knob's purpose. Zero rather than a small number because these ticks run
    %% microseconds apart and any real delay would not have elapsed.
    application:set_env(asobi, binary_wire_retry_ms, 0),
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    _ = recv(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0}),
    asobi_zone:add_entity(Pid, ~"e2", #{~"x" => 2.0, ~"path" => [1, 2]}),
    asobi_zone:tick(Pid, 1),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),

    %% The rebind keyframe refuses too, so the zone latches to text.
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 3.0}),
    asobi_zone:tick(Pid, 2),
    ?assertMatch({zone_delta_raw, _}, recv_delta()),

    %% The offending entity leaves. The retry window has passed, so the next
    %% broadcast re-arms the wire and sends a keyframe rather than a delta.
    asobi_zone:remove_entity(Pid, ~"e2"),
    asobi_zone:tick(Pid, 3),
    {zone_delta_raw, _Json, Bin} = recv_delta(),
    {ok, #{kf := Kf, records := Records}} = asobi_wire:decode(Bin),
    ?assert(Kf),
    ?assertEqual([{add, ~"e1"}], [{Op, Id} || #{op := Op, id := Id} <- Records]),

    %% ...and it stays on the binary wire afterwards.
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 5.0}),
    asobi_zone:tick(Pid, 4),
    ?assertMatch({zone_delta_raw, _, _}, recv_delta()),
    gen_server:stop(Pid).
