-module(asobi_zone_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_world_game).

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

cleanup(_) ->
    ok.

start_zone() ->
    start_zone(#{}).

start_zone(Overrides) ->
    Config = maps:merge(
        #{
            world_id => <<"test_world">>,
            coords => {0, 0},
            ticker_pid => self(),
            game_module => ?GAME,
            zone_state => #{}
        },
        Overrides
    ),
    {ok, Pid} = asobi_zone:start_link(Config),
    Pid.

zone_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts empty", fun starts_empty/0},
        {"add and remove entities", fun add_remove_entities/0},
        {"subscribe and unsubscribe", fun subscribe_unsubscribe/0},
        {"unsubscribe sends a removal for every entity the zone holds",
            fun unsubscribe_sends_removals_for_entities/0},
        {"unsubscribe of an unknown player sends nothing",
            fun unsubscribe_unknown_player_is_noop/0},
        {"resync re-sends a keyframe to a subscriber", fun resync_sends_keyframe/0},
        {"resync for a player who is not subscribed sends nothing",
            fun resync_unsubscribed_sends_nothing/0},
        {"resubscribing the same pid is idempotent", fun resubscribe_same_pid_is_idempotent/0},
        {"resubscribing a new pid replaces and demonitors the old one",
            fun resubscribe_new_pid_replaces_and_demonitors_old/0},
        {"tick processes inputs and broadcasts deltas", fun tick_broadcasts/0},
        {"tick with no changes sends no deltas", fun tick_no_changes/0},
        {"tick acks to ticker", fun tick_acks/0},
        {"world.input seq comes back as a world.ack (#474)", fun world_ack_returns_seq/0},
        {"a rejected input still advances the world.ack (#474)",
            fun world_ack_advances_on_reject/0},
        {"world.input without a seq produces no world.ack (#474)",
            fun world_ack_absent_without_seq/0},
        {"world.ack keeps the highest seq (#474)", fun world_ack_keeps_highest_seq/0},
        {"a consumed seq reported by handle_input acks below the frame stamp (#532)",
            fun world_ack_uses_reported_consumed_seq/0},
        {"a reported seq above the frame stamp is acked too (#532)",
            fun world_ack_reported_seq_above_stamp/0},
        {"a report is authoritative for the rest of the tick (#532)",
            fun world_ack_report_beats_a_later_stamp/0},
        {"a reported seq never regresses the ack across ticks (#532)",
            fun world_ack_reported_seq_never_regresses/0},
        {"an invalid reported seq falls back to the frame stamp (#532)",
            fun world_ack_invalid_reported_seq_falls_back/0},
        {"a reported seq wider than the ack space is refused (#532)",
            fun world_ack_reported_seq_is_bounded/0},
        {"a report beats a stamp that arrived before it (#532)",
            fun world_ack_report_beats_an_earlier_stamp/0},
        {"the newest report in a tick wins, even downwards (#532)",
            fun world_ack_newest_report_wins/0},
        {"a rejected input's stamp does not beat a report already made (#532)",
            fun world_ack_error_stamp_does_not_beat_a_report/0},
        {"a spec-violating seq neither acks nor kills the zone (#532)",
            fun world_ack_garbage_seq_does_not_kill_the_zone/0},
        {"world.ack is per-connection - p1's ack never reaches p2 (#474)",
            fun world_ack_is_per_connection/0},
        {"a straggler input re-arms the zone's ack after the entity left (#477)",
            fun world_ack_rearms_in_the_zone_left_behind/0},
        {"a negative seq is ignored - no ack (#474 hardening)",
            fun world_ack_ignores_negative_seq/0},
        {"a non-integer seq via player_input/4 does not crash the zone (#474 hardening)",
            fun world_ack_survives_non_integer_seq/0},
        {"queued inputs apply in arrival order", fun inputs_apply_in_arrival_order/0},
        {"subscriber DOWN cleans up", fun subscriber_down_cleanup/0},
        {"tick touches zone_manager when subscribers present", fun tick_touches_zone_manager/0},
        {"tick hibernates when empty", fun tick_hibernates_when_empty/0},
        {"tick does not hibernate with NPC entities", fun tick_no_hibernate_with_npcs/0},
        {"spawn_entity with a known template creates the entity",
            fun spawn_entity_known_template/0},
        {"spawn_entity with an unknown template logs and emits telemetry, spawns nothing",
            fun spawn_entity_unknown_template_observable/0},
        {"spawn_entity bounds an over-long template_id before it is observable",
            fun spawn_entity_long_template_id_bounded/0},
        {"spawn_entity keeps a multibyte template_id valid UTF-8 when bounding",
            fun spawn_entity_multibyte_template_id_stays_utf8/0},
        {"spawn_templates_hint updates a live zone's spawnable templates",
            fun spawn_templates_hint_updates_live_zone/0},
        {"spawn_templates_hint returning garbage logs a warning and survives",
            fun spawn_templates_hint_malformed_return_is_observable/0},
        {"an NPC within the boundary margin does not transfer zones",
            fun npc_within_margin_does_not_transfer/0},
        {"an NPC past the boundary margin transfers to the neighbouring zone",
            fun npc_past_margin_transfers/0},
        {"an NPC whose target zone cannot be resolved stays here, clamped",
            fun npc_transfer_unavailable_zone_keeps_entity/0},
        {"an NPC stays here when the zone manager refuses to create the target",
            fun npc_transfer_zone_manager_error_keeps_entity/0},
        {"an NPC crossing into an unloaded zone has it created for it",
            fun npc_transfer_creates_unloaded_target_zone/0},
        {"a binary-keyed NPC past the boundary margin transfers too",
            fun binary_keyed_npc_past_margin_transfers/0},
        {"a zone holding only binary-keyed NPCs does not hibernate",
            fun tick_no_hibernate_with_binary_keyed_npcs/0},
        {"reap stops a zone with no entities", fun reap_stops_empty_zone/0},
        {"reap declines and re-touches a zone that still has entities",
            fun reap_declines_when_occupied/0},
        {"sync drains earlier casts to a live zone", fun sync_drains_live_zone/0},
        {"sync reports a stopped zone instead of exiting the caller",
            fun sync_reports_stopped_zone/0}
    ]}.

starts_empty() ->
    Pid = start_zone(),
    ?assertEqual(#{}, asobi_zone:get_entities(Pid)),
    ?assertEqual(0, asobi_zone:get_subscriber_count(Pid)),
    gen_server:stop(Pid).

add_remove_entities() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"e1">>, #{x => 10, y => 20}),
    timer:sleep(10),
    ?assertEqual(#{<<"e1">> => #{x => 10, y => 20}}, asobi_zone:get_entities(Pid)),
    asobi_zone:remove_entity(Pid, <<"e1">>),
    timer:sleep(10),
    ?assertEqual(#{}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

spawn_entity_known_template() ->
    Pid = start_zone(#{
        spawn_templates => #{
            ~"cube" => #{type => ~"object", base_state => #{~"solid" => true}}
        }
    }),
    asobi_zone:spawn_entity(Pid, ~"cube", {10, 20}),
    timer:sleep(10),
    Entities = asobi_zone:get_entities(Pid),
    ?assertEqual(1, map_size(Entities)),
    [Entity] = maps:values(Entities),
    ?assertEqual(~"object", maps:get(type, Entity)),
    gen_server:stop(Pid).

%% asobi#247: an unresolvable template_id must be observable (log +
%% telemetry), not silently dropped - the game.zone.spawn caller has no
%% synchronous way to learn a cast failed, so this is the only signal.
spawn_entity_unknown_template_observable() ->
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
    ),
    Pid = start_zone(#{spawn_templates => #{}}),
    try
        asobi_zone:spawn_entity(Pid, ~"nonexistent", {10, 20}),
        timer:sleep(10),
        ?assertEqual(#{}, asobi_zone:get_entities(Pid)),
        receive
            {ev, #{kind := unknown_spawn_template, details := D}} ->
                ?assertEqual(~"nonexistent", maps:get(template_id, D))
        after 1000 -> ?assert(false, timeout_waiting_for_unknown_spawn_template_event)
        end
    after
        telemetry:detach(Ref),
        gen_server:stop(Pid)
    end.

spawn_entity_long_template_id_bounded() ->
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
    ),
    Long = binary:copy(~"a", 200),
    Pid = start_zone(#{spawn_templates => #{}}),
    try
        asobi_zone:spawn_entity(Pid, Long, {10, 20}),
        receive
            {ev, #{kind := unknown_spawn_template, details := D}} ->
                Id = maps:get(template_id, D),
                ?assertEqual(64, byte_size(Id)),
                ?assertEqual(binary:part(Long, 0, 64), Id)
        after 1000 -> ?assert(false, timeout_waiting_for_bounded_template_id)
        end
    after
        telemetry:detach(Ref),
        gen_server:stop(Pid)
    end.

%% A 64-byte cut lands mid-codepoint here; the details map is exported verbatim
%% to handlers that JSON-encode it, so it must stay valid UTF-8.
spawn_entity_multibyte_template_id_stays_utf8() ->
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
    ),
    Split = <<(binary:copy(~"a", 63))/binary, "å"/utf8>>,
    Pid = start_zone(#{spawn_templates => #{}}),
    try
        asobi_zone:spawn_entity(Pid, Split, {10, 20}),
        receive
            {ev, #{kind := unknown_spawn_template, details := D}} ->
                Id = maps:get(template_id, D),
                ?assert(byte_size(Id) =< 64),
                ?assert(is_binary(unicode:characters_to_binary(Id))),
                _ = json:encode(#{~"template_id" => Id})
        after 1000 -> ?assert(false, timeout_waiting_for_utf8_safe_template_id)
        end
    after
        telemetry:detach(Ref),
        gen_server:stop(Pid)
    end.

subscribe_unsubscribe() ->
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    timer:sleep(10),
    ?assertEqual(1, asobi_zone:get_subscriber_count(Pid)),
    asobi_zone:unsubscribe(Pid, <<"p1">>),
    timer:sleep(10),
    ?assertEqual(0, asobi_zone:get_subscriber_count(Pid)),
    gen_server:stop(Pid).

%% asobi#474: a world.input carrying a client seq comes back to that connection
%% as a world.ack, so the client can reconcile its prediction.
world_ack_returns_seq() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"p1", #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"move", ~"x" => 5, ~"y" => 5}, 412),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(412, recv_ack()),
    gen_server:stop(Pid).

%% A rejected input still advances the ack: the server consumed the seq, it just
%% declined the effect. With no p1 entity the move is rejected (not_found).
world_ack_advances_on_reject() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"move", ~"x" => 1, ~"y" => 1}, 7),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(7, recv_ack()),
    gen_server:stop(Pid).

%% A client that never stamps a seq (did not opt in) gets no ack frames.
world_ack_absent_without_seq() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"p1", #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"move", ~"x" => 3, ~"y" => 3}),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    gen_server:stop(Pid).

%% Out-of-order or duplicate seqs never regress the ack: the highest wins.
world_ack_keeps_highest_seq() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{}, 5),
    asobi_zone:player_input(Pid, ~"p1", #{}, 3),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(5, recv_ack()),
    gen_server:stop(Pid).

%% asobi#532: a client predicting at 60 Hz against a 12.5 Hz zone batches
%% several simulation steps into one frame. If the zone caps how many it runs
%% per tick and parks the rest, the frame stamp says more ran than did - the
%% client would discard predicted steps the server has not applied and could
%% never replay them. handle_input reporting what it consumed acks BELOW the
%% stamp, which is the whole point: a max would let "arrived" beat "ran".
world_ack_uses_reported_consumed_seq() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(
        Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 42}, 100
    ),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(42, recv_ack()),
    gen_server:stop(Pid).

%% The other stamping convention: a frame stamped with the FIRST seq in its
%% batch, where the zone ran through the end of it. The report is above the
%% stamp and the client must hear the higher number or it replays steps the
%% server already applied.
world_ack_reported_seq_above_stamp() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 9}, 5),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(9, recv_ack()),
    gen_server:stop(Pid).

%% Once a module has said what it consumed, a plain stamped input arriving
%% later in the same tick must not raise the ack past it.
world_ack_report_beats_a_later_stamp() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 12}, 40),
    asobi_zone:player_input(Pid, ~"p1", #{}, 30),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(12, recv_ack()),
    gen_server:stop(Pid).

%% Cross-tick monotonicity still holds: a report is authoritative within a tick,
%% never a licence to walk the ack backwards, which would make the client
%% replay from a point it has already reconciled past.
world_ack_reported_seq_never_regresses() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 50}, 50),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(50, recv_ack()),
    %% Stamp 60 on a report of 20: the stamp must not sneak the ack up, and the
    %% report must not walk it back. With the feature reverted this reads 60,
    %% so the case actually discriminates.
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 20}, 60),
    asobi_zone:tick(Pid, 2),
    ?assertEqual(50, recv_ack()),
    gen_server:stop(Pid).

%% The mirror of world_ack_report_beats_a_later_stamp: the rule is that a report
%% is authoritative for the tick whatever order the two arrive in, and only one
%% of the two orders was pinned.
world_ack_report_beats_an_earlier_stamp() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{}, 30),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 12}, 40),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(12, recv_ack()),
    gen_server:stop(Pid).

%% A module revising its watermark DOWN within a tick is the parking case this
%% feature exists for, so the newest report has to win rather than the highest.
world_ack_newest_report_wins() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 40}, 100),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 12}, 101),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(12, recv_ack()),
    gen_server:stop(Pid).

%% #474 says a rejected input still advances the ack to its frame stamp, and
%% this feature says a report outranks a stamp. Both are true: refusing one
%% input does not unrun the steps another input already consumed.
world_ack_error_stamp_does_not_beat_a_report() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 12}, 40),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"invalid"}, 50),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(12, recv_ack()),
    gen_server:stop(Pid).

%% player_input/4 is exported, so a spec-violating seq must neither ack nor
%% function_clause the shared zone - which would DoS every player in it. The
%% tick-local path is total for the same reason record_ack/3 is.
world_ack_garbage_seq_does_not_kill_the_zone() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{}, off_the_wire(~"garbage")),
    asobi_zone:player_input(Pid, ~"p1", #{}, off_the_wire({tuple, 1})),
    asobi_zone:player_input(Pid, ~"p1", #{}, off_the_wire([1, 2, 3])),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

%% The documented way to write this callback derives the watermark from the
%% client's payload, so the reported value is attacker-influenced by design.
%% asobi_ws_handler bounds the stamped seq to a JS-safe integer for exactly this
%% reason; the reported one is a second door into the same wire field, and an
%% ack the session gate keeps forever - so a bignum here would silence that
%% connection's acks from every zone, not just this one.
world_ack_reported_seq_is_bounded() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    Huge = 16#1FFFFFFFFFFFFF + 1,
    asobi_zone:player_input(
        Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => Huge}, 11
    ),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(11, recv_ack()),
    ?assert(is_process_alive(Pid)),
    %% The largest in-range value is still acked, so the bound is a ceiling and
    %% not an off-by-one that costs a legitimate game its last seq.
    asobi_zone:player_input(
        Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 16#1FFFFFFFFFFFFF}, 12
    ),
    asobi_zone:tick(Pid, 2),
    ?assertEqual(16#1FFFFFFFFFFFFF, recv_ack()),
    gen_server:stop(Pid).

%% A game module is user code. A nonsense consumed seq must neither crash the
%% shared zone process nor be acked: the frame stamp is the recoverable answer.
world_ack_invalid_reported_seq_falls_back() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(
        Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => ~"nope"}, 7
    ),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(7, recv_ack()),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

%% asobi#474: the ack is per-connection - p1's seq reaches p1 only, never p2's
%% connection. That isolation is the whole point of the frame over the shared
%% entity-field ack.
world_ack_is_per_connection() ->
    Parent = self(),
    Pid = start_zone(#{broadcast_interval => 1}),
    P2 = spawn(fun() -> p2_ack_forwarder(Parent) end),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:subscribe(Pid, {~"p2", P2}),
    asobi_zone:add_entity(Pid, ~"p1", #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"move", ~"x" => 2, ~"y" => 2}, 99),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(99, recv_ack()),
    receive
        {p2_saw_ack, S} ->
            ?assert(false, "p2 received a world.ack for p1's seq: " ++ integer_to_list(S))
    after 100 -> ok
    end,
    gen_server:stop(Pid).

p2_ack_forwarder(Parent) ->
    receive
        {asobi_message, {world_ack, _T, S}} -> Parent ! {p2_saw_ack, S};
        _ -> p2_ack_forwarder(Parent)
    end.

%% asobi#477: this pins the zone-side behaviour the session-side filter exists to
%% correct. A crossing player stays subscribed to the zone they left whenever it
%% remains in their interest ring, and input still routed there during the
%% crossing re-arms the ack, so the zone goes on emitting a mark that the zone
%% they moved into has already passed. The zone cannot know that on its own -
%% only the connection sees both streams - which is why asobi_player_session
%% drops any ack that does not advance. If this test ever starts reporting
%% no_ack, the zone has grown a guard and the session filter may be redundant.
world_ack_rearms_in_the_zone_left_behind() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"p1", #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"move", ~"x" => 5, ~"y" => 5}, 412),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(412, recv_ack()),
    %% The straggler: cast before the crossing lands, drained on the next tick.
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"move", ~"x" => 6, ~"y" => 6}, 413),
    asobi_zone:remove_entity(Pid, ~"p1"),
    flush_messages(),
    asobi_zone:tick(Pid, 2),
    ?assertEqual(413, recv_ack()),
    asobi_zone:tick(Pid, 3),
    ?assertEqual(413, recv_ack()),
    gen_server:stop(Pid).

%% asobi#474 hardening: record_ack is total and rejects negatives, so a
%% spec-violating seq reaching the exported player_input/4 neither acks nor
%% crashes the shared zone process (which would DoS every player in it).
world_ack_ignores_negative_seq() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{}, -5),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

world_ack_survives_non_integer_seq() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    flush_messages(),
    asobi_zone:player_input(Pid, ~"p1", #{}, off_the_wire(~"not-a-seq")),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

recv_ack() ->
    receive
        {asobi_message, {world_ack, _Tick, Seq}} -> Seq
    after 300 -> no_ack
    end.

%% widgrensit/asobi#293: leaving a zone's interest ring must mirror joining
%% it - subscribe_new/3 sends an `a` for every entity, so unsubscribe must
%% send an `r` for every entity still held, or the departing client's copy
%% of this zone freezes at its last known state forever (the zone never
%% sends it another update once the subscription is gone).
%% The repair half of frame_seq. A client that saw a gap asks for a baseline and
%% gets one carrying the zone's CURRENT frame_seq with kf: true, which is what it
%% resets its high-water mark to.
resync_sends_keyframe() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 1, y => 1, type => ~"player"}),
    timer:sleep(10),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    %% One broadcast so the zone has a non-zero frame_seq and a real baseline,
    %% which is what makes the assertion below distinguishable from the join
    %% keyframe's frame_seq of 0.
    asobi_zone:tick(Pid, 1),
    timer:sleep(20),
    flush_messages(),

    asobi_zone:resync(Pid, ~"p1"),
    receive
        {asobi_message, {zone_keyframe, Meta, Snapshot}} ->
            ?assertEqual(true, maps:get(~"kf", Meta)),
            ?assertEqual([0, 0], maps:get(~"zone", Meta)),
            ?assertEqual(1, maps:get(~"frame_seq", Meta)),
            ?assertEqual([~"e1"], [Id || #{~"id" := Id} <- Snapshot])
    after 500 ->
        ?assert(false)
    end,
    gen_server:stop(Pid).

%% A resync naming a zone the requester is not subscribed to is dropped, not
%% answered. Answering would make the frame a way to read any zone in the world,
%% and there is nothing to repair for a client that was never told anything.
resync_unsubscribed_sends_nothing() ->
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 1, y => 1, type => ~"player"}),
    timer:sleep(10),
    flush_messages(),

    asobi_zone:resync(Pid, ~"never_subscribed"),
    receive
        {asobi_message, {zone_keyframe, _, _}} -> ?assert(false)
    after 200 -> ok
    end,
    gen_server:stop(Pid).

unsubscribe_sends_removals_for_entities() ->
    %% broadcast_interval 1 so one tick is one broadcast: the leave frame removes
    %% what the client was TOLD about (broadcast_entities), not what the zone
    %% happens to hold, so the entities have to reach the client first.
    Pid = start_zone(#{broadcast_interval => 1}),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 1, y => 1, type => ~"player"}),
    asobi_zone:add_entity(Pid, ~"e2", #{x => 2, y => 2, type => ~"npc"}),
    timer:sleep(10),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(20),
    flush_messages(),

    asobi_zone:unsubscribe(Pid, ~"p1"),
    Removals =
        receive
            {asobi_message, {zone_removals, {0, 0}, Deltas}} -> Deltas
        after 200 -> []
        end,
    ?assertEqual(
        lists:sort([~"e1", ~"e2"]),
        lists:sort([Id || #{~"op" := ~"r", ~"id" := Id} <- Removals])
    ),
    timer:sleep(10),
    ?assertEqual(0, asobi_zone:get_subscriber_count(Pid)),
    gen_server:stop(Pid).

%% Unsubscribing a player who was never subscribed (or already removed) must
%% stay a pure no-op - no message to a pid that never subscribed.
unsubscribe_unknown_player_is_noop() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 1, y => 1, type => ~"player"}),
    timer:sleep(10),
    asobi_zone:unsubscribe(Pid, ~"nobody"),
    ?assertEqual(
        timeout,
        receive
            {asobi_message, {zone_delta, 0, _}} -> resent
        after 100 -> timeout
        end
    ),
    gen_server:stop(Pid).

%% asobi#275: callers now (re-)subscribe a crossing/backfilled player to a
%% zone unconditionally, even when they may already be subscribed - a
%% same-pid re-subscribe must be a true no-op, not a second monitor/2 (which
%% would leak the first MonRef, since only the latest one is ever kept in
%% subscribers) or a wasted second snapshot send.
resubscribe_same_pid_is_idempotent() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 1, y => 1, type => ~"player"}),
    timer:sleep(10),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    #{subscribers := #{~"p1" := {_, Ref0}}} = sys:get_state(Pid),
    {monitored_by, Before} = process_info(self(), monitored_by),
    flush_messages(),

    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    #{subscribers := #{~"p1" := {SamePid, Ref1}}} = sys:get_state(Pid),
    ?assertEqual(self(), SamePid),
    %% The original monitor ref is retained - a fresh monitor/2 call would
    %% have replaced it with a new one and left the old one dangling.
    ?assertEqual(Ref0, Ref1),
    {monitored_by, After} = process_info(self(), monitored_by),
    ?assertEqual(length(Before), length(After)),
    ?assertEqual(1, asobi_zone:get_subscriber_count(Pid)),
    ?assertEqual(
        timeout,
        receive
            {asobi_message, {zone_delta, 0, _}} -> resent
        after 100 -> timeout
        end
    ),
    gen_server:stop(Pid).

%% A reconnect legitimately re-subscribes the same PlayerId under a new
%% session pid - that must replace the old subscription (fresh monitor, fresh
%% snapshot) and demonitor the stale one so its later DOWN can't evict the
%% live subscription (asobi_zone's DOWN handler filters by pid, not by ref).
resubscribe_new_pid_replaces_and_demonitors_old() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, ~"e1", #{x => 1, y => 1, type => ~"player"}),
    timer:sleep(10),
    Old = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_zone:subscribe(Pid, {~"p1", Old}),
    timer:sleep(10),
    #{subscribers := #{~"p1" := {Old, OldRef}}} = sys:get_state(Pid),

    asobi_zone:subscribe(Pid, {~"p1", self()}),
    timer:sleep(10),
    #{subscribers := #{~"p1" := {NewPid, NewRef}}} = sys:get_state(Pid),
    ?assertEqual(self(), NewPid),
    ?assertNotEqual(OldRef, NewRef),
    %% The re-subscribe keyframe is built from the shared broadcast baseline, so
    %% before any broadcast tick it is legitimately empty. What matters here is
    %% that a keyframe arrives at all, and that it is marked as one.
    ?assertMatch(
        {#{~"kf" := true, ~"zone" := [0, 0]}, _},
        receive
            {asobi_message, {zone_keyframe, Meta, Snapshot}} -> {Meta, Snapshot}
        after 200 -> timeout
        end
    ),

    exit(Old, kill),
    timer:sleep(50),
    ?assertEqual(1, asobi_zone:get_subscriber_count(Pid)),
    gen_server:stop(Pid).

tick_broadcasts() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"e1">>, #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    timer:sleep(10),
    %% Subscribe sends a keyframe built from the shared broadcast baseline. e1 was
    %% added but never broadcast, so it is NOT in the keyframe - it arrives as an
    %% op:"a" in the first delta instead. Snapshotting `entities` here is what
    %% used to send it twice, once in the snapshot and again in that first delta.
    receive
        {asobi_message, {zone_keyframe, Meta, Snapshot}} ->
            ?assertEqual(true, maps:get(~"kf", Meta)),
            ?assertEqual(0, maps:get(~"frame_seq", Meta)),
            ?assertEqual([0, 0], maps:get(~"zone", Meta)),
            ?assertEqual([], Snapshot)
    after 1000 ->
        ?assert(false)
    end,
    %% Broadcast interval is 3, so tick 3 broadcasts
    asobi_zone:tick(Pid, 1),
    asobi_zone:tick(Pid, 2),
    asobi_zone:tick(Pid, 3),
    receive
        {asobi_message, {zone_delta_raw, Bin}} when is_binary(Bin) ->
            #{~"type" := ~"world.tick", ~"payload" := #{~"tick" := 3}} = json:decode(Bin),
            ok
    after 1000 ->
        ?assert(false)
    end,
    %% Tick 4 does not broadcast (4 rem 3 = 1)
    asobi_zone:tick(Pid, 4),
    receive
        {asobi_message, {zone_delta_raw, _}} ->
            ?assert(false)
    after 100 ->
        ok
    end,
    gen_server:stop(Pid).

inputs_apply_in_arrival_order() ->
    %% Regression: when several player_input casts arrive between two
    %% ticks they used to be processed newest-first, so the OLDEST x
    %% won and every later move was overwritten. Assert the newest
    %% input wins instead.
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"p1">>, #{x => 0, y => 0, type => ~"player"}),
    timer:sleep(10),
    [
        asobi_zone:player_input(Pid, <<"p1">>, #{
            ~"action" => ~"move", ~"x" => X, ~"y" => 100
        })
     || X <- [10, 20, 30, 40, 50]
    ],
    asobi_zone:tick(Pid, 1),
    timer:sleep(20),
    Entities = asobi_zone:get_entities(Pid),
    ?assertMatch(#{x := 50, y := 100}, maps:get(<<"p1">>, Entities)),
    gen_server:stop(Pid).

tick_no_changes() ->
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    receive
        {asobi_message, {zone_delta, 1, _}} ->
            ?assert(false);
        {asobi_message, {zone_delta_raw, _}} ->
            ?assert(false)
    after 100 ->
        ok
    end,
    gen_server:stop(Pid).

tick_acks() ->
    Pid = start_zone(),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    receive
        {'$gen_cast', {tick_done, Pid, 1}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    gen_server:stop(Pid).

subscriber_down_cleanup() ->
    Pid = start_zone(),
    SubPid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_zone:subscribe(Pid, {<<"p1">>, SubPid}),
    timer:sleep(10),
    ?assertEqual(1, asobi_zone:get_subscriber_count(Pid)),
    exit(SubPid, kill),
    timer:sleep(50),
    ?assertEqual(0, asobi_zone:get_subscriber_count(Pid)),
    gen_server:stop(Pid).

tick_touches_zone_manager() ->
    ZMPid = start_mock_zone_manager(),
    Pid = start_zone(#{zone_manager_pid => ZMPid}),
    asobi_zone:subscribe(Pid, {<<"p1">>, self()}),
    flush_messages(),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(50),
    ZMPid ! {get_touches, self()},
    receive
        {touches, Touches} ->
            ?assert(length(Touches) > 0),
            ?assertEqual({0, 0}, hd(Touches))
    after 1000 ->
        ?assert(false)
    end,
    gen_server:stop(Pid),
    ZMPid ! stop.

tick_hibernates_when_empty() ->
    Pid = start_zone(),
    asobi_zone:tick(Pid, 1),
    timer:sleep(50),
    {current_function, {Mod, Fun, _}} = erlang:process_info(Pid, current_function),
    HibernateStr = atom_to_list(Fun),
    ?assert(
        string:find(HibernateStr, "hibernate") =/= nomatch,
        lists:flatten(io_lib:format("expected hibernate, got ~p:~p", [Mod, Fun]))
    ),
    gen_server:stop(Pid).

tick_no_hibernate_with_npcs() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"npc1">>, #{type => ~"npc", x => 0, y => 0}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(50),
    {current_function, CF} = erlang:process_info(Pid, current_function),
    ?assertNotEqual({erlang, hibernate, 3}, CF),
    gen_server:stop(Pid).

%% asobi#253: spawn_templates/1 is only ever called once, at zone creation -
%% a template added by a later script hot-reload never reached an
%% already-running zone. spawn_templates_hint/1 is the fix: an optional,
%% per-tick, cheap "did templates change" callback. asobi_test_world_game
%% doesn't export it normally (verified: it's absent from
%% -export([init/1, join/2, ...])), so injecting it via meck's non_strict
%% mode - the same technique already used for phases/1 in
%% asobi_world_server_tests.erl - both proves the callback is genuinely
%% optional (erlang:function_exported/3 must see it appear) and lets this
%% test control exactly when a "change" is reported.
spawn_templates_hint_updates_live_zone() ->
    Pid = start_zone(#{spawn_templates => #{}}),
    meck:new(?GAME, [passthrough, non_strict]),
    meck:expect(?GAME, spawn_templates_hint, fun(_ZoneState) ->
        {changed, #{~"goblin" => #{type => ~"npc", base_state => #{}}}}
    end),
    try
        %% Before the hint has run: the template is genuinely unknown.
        asobi_zone:spawn_entity(Pid, ~"goblin", {5, 5}),
        timer:sleep(10),
        ?assertEqual(#{}, asobi_zone:get_entities(Pid)),
        %% A tick applies the hint's {changed, _} result to the live spawner.
        asobi_zone:tick(Pid, 1),
        timer:sleep(10),
        %% The same template_id that failed above now spawns.
        asobi_zone:spawn_entity(Pid, ~"goblin", {5, 5}),
        timer:sleep(10),
        Entities = asobi_zone:get_entities(Pid),
        ?assertEqual(1, map_size(Entities)),
        [Entity] = maps:values(Entities),
        ?assertEqual(~"npc", maps:get(type, Entity))
    after
        meck:unload(?GAME),
        gen_server:stop(Pid)
    end.

%% asobi#253 code review: a callback return that's neither `unchanged` nor a
%% well-formed `{changed, Map}` is a bug in the game module, not a normal
%% "nothing changed" outcome. It must be observable (logged) and must not
%% touch the spawner's existing templates - not silently swallowed like the
%% expected `unchanged` case.
spawn_templates_hint_malformed_return_is_observable() ->
    Pid = start_zone(#{
        spawn_templates => #{~"cube" => #{type => ~"object", base_state => #{}}}
    }),
    meck:new(?GAME, [passthrough, non_strict]),
    meck:expect(?GAME, spawn_templates_hint, fun(_ZoneState) -> not_a_valid_hint_return end),
    try
        asobi_zone:tick(Pid, 1),
        timer:sleep(10),
        ?assert(is_process_alive(Pid)),
        %% The existing template survives untouched - the malformed return
        %% must not have reached asobi_zone_spawner:set_templates/2.
        asobi_zone:spawn_entity(Pid, ~"cube", {1, 1}),
        timer:sleep(10),
        ?assertEqual(1, map_size(asobi_zone:get_entities(Pid)))
    after
        meck:unload(?GAME),
        gen_server:stop(Pid)
    end.

%% Regression for widgrensit/asobi#248 (security review): the crossing check
%% needs a margin, not a hard edge, or a player camped on a boundary re-homes
%% every tick - full interest-ring diff and zone snapshot resend each time.
past_zone_margin_test() ->
    ZoneSize = 100,
    Coords = {1, 1},
    Fraction = 0.15,
    %% Just inside the zone: never past the margin.
    ?assertNot(asobi_zone:past_zone_margin({150.0, 150.0}, Coords, ZoneSize, Fraction)),
    %% Just past the edge (100..200), but within the 15-unit margin.
    ?assertNot(asobi_zone:past_zone_margin({205.0, 150.0}, Coords, ZoneSize, Fraction)),
    ?assertNot(asobi_zone:past_zone_margin({95.0, 150.0}, Coords, ZoneSize, Fraction)),
    %% Exactly at the margin boundary (200 + 100*0.15 = 215 / 100 - 15 = 85):
    %% the low side's `<` excludes 85, the high side's `>=` includes 215.
    ?assertNot(asobi_zone:past_zone_margin({85.0, 150.0}, Coords, ZoneSize, Fraction)),
    ?assert(asobi_zone:past_zone_margin({215.0, 150.0}, Coords, ZoneSize, Fraction)),
    %% Clearly past the margin on every side.
    ?assert(asobi_zone:past_zone_margin({220.0, 150.0}, Coords, ZoneSize, Fraction)),
    ?assert(asobi_zone:past_zone_margin({80.0, 150.0}, Coords, ZoneSize, Fraction)),
    ?assert(asobi_zone:past_zone_margin({150.0, 220.0}, Coords, ZoneSize, Fraction)),
    ?assert(asobi_zone:past_zone_margin({150.0, 80.0}, Coords, ZoneSize, Fraction)),
    %% A different fraction actually changes the threshold, proving the
    %% argument is live and not shadowed by a leftover constant.
    ?assertNot(asobi_zone:past_zone_margin({210.0, 150.0}, Coords, ZoneSize, 0.5)),
    ?assert(asobi_zone:past_zone_margin({210.0, 150.0}, Coords, ZoneSize, 0.05)).

%% zone_size=200, grid_size=10, rehome_margin=0.15 => 30-unit margin.
classify_crossing_boundary_test() ->
    C = {0, 0},
    ?assertEqual(same, asobi_zone:classify_crossing({199.0, 0.0}, C, 200, 10, 0.15)),
    ?assertEqual(same, asobi_zone:classify_crossing({229.9, 0.0}, C, 200, 10, 0.15)),
    ?assertEqual({crossed, {1, 0}}, asobi_zone:classify_crossing({230.0, 0.0}, C, 200, 10, 0.15)),
    %% One axis clear, the other still inside its margin: still a crossing,
    %% and the target is the zone that actually contains the point.
    ?assertEqual(
        {crossed, {1, 1}}, asobi_zone:classify_crossing({245.0, 215.0}, C, 200, 10, 0.15)
    ),
    %% Out-of-world clamps back onto Coords before the margin is consulted.
    ?assertEqual(same, asobi_zone:classify_crossing({-9000.0, 0.0}, C, 200, 10, 0.15)).

%% zone_size=200, rehome_margin=0.15 => zone {0,0} covers x in [0, 200),
%% margin is 30 units. Passed explicitly so a change to either default
%% doesn't silently retune what these tests exercise.
-define(NPC_MARGIN_ZONE_SIZE, 200).
-define(NPC_MARGIN_REHOME_MARGIN, 0.15).

npc_within_margin_does_not_transfer() ->
    Pid = start_zone(#{
        world_id => ~"npc_margin_within",
        zone_size => ?NPC_MARGIN_ZONE_SIZE,
        rehome_margin => ?NPC_MARGIN_REHOME_MARGIN
    }),
    %% x=215 is past the raw edge (200) but within the 30-unit margin (230).
    asobi_zone:add_entity(Pid, ~"npc1", #{type => ~"npc", x => 215.0, y => 0.0}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(20),
    ?assert(maps:is_key(~"npc1", asobi_zone:get_entities(Pid))),
    gen_server:stop(Pid).

npc_past_margin_transfers() ->
    WorldId = ~"npc_margin_past",
    Config = #{
        world_id => WorldId,
        zone_size => ?NPC_MARGIN_ZONE_SIZE,
        rehome_margin => ?NPC_MARGIN_REHOME_MARGIN
    },
    Pid = start_zone(Config#{coords => {0, 0}}),
    TargetPid = start_zone(Config#{coords => {1, 0}}),
    %% x=245 clears the 30-unit margin past the raw edge (200 + 30 = 230).
    asobi_zone:add_entity(Pid, ~"npc1", #{type => ~"npc", x => 245.0, y => 0.0}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(20),
    ?assertNot(maps:is_key(~"npc1", asobi_zone:get_entities(Pid))),
    ?assert(maps:is_key(~"npc1", asobi_zone:get_entities(TargetPid))),
    gen_server:stop(Pid),
    gen_server:stop(TargetPid).

%% asobi#271: an NPC whose target zone can't be resolved must stay in this
%% zone (clamped back inside its bounds, as a rate-limited player is), not be
%% destroyed - and the denied crossing stays observable the same way #251
%% made spawn_at_zone_unavailable observable.
npc_transfer_unavailable_zone_keeps_entity() ->
    Self = self(),
    Ref = make_ref(),
    {ok, _} = application:ensure_all_started(telemetry),
    telemetry:attach(
        Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
    ),
    Pid = start_zone(#{
        world_id => ~"npc_transfer_no_target",
        coords => {0, 0},
        zone_size => ?NPC_MARGIN_ZONE_SIZE,
        rehome_margin => ?NPC_MARGIN_REHOME_MARGIN
    }),
    try
        %% x=245 clears the margin; no zone is loaded at {1,0} in this world
        %% and this zone has no zone manager to create one.
        asobi_zone:add_entity(Pid, ~"npc1", #{type => ~"npc", x => 245.0, y => 0.0}),
        timer:sleep(10),
        asobi_zone:tick(Pid, 1),
        timer:sleep(20),
        Npc = maps:get(~"npc1", asobi_zone:get_entities(Pid)),
        ?assert(maps:get(x, Npc) < ?NPC_MARGIN_ZONE_SIZE),
        receive
            {ev, #{kind := zone_unavailable, details := D}} ->
                ?assertEqual({1, 0}, maps:get(coords, D)),
                ?assertEqual(~"npc1", maps:get(entity_id, D)),
                ?assertEqual(no_zone_manager, maps:get(reason, D))
        after 1000 -> ?assert(false, timeout_waiting_for_zone_unavailable_event)
        end
    after
        telemetry:detach(Ref),
        gen_server:stop(Pid)
    end.

%% Same, for a zone manager that refuses to create the target (the world hit
%% max_active_zones): the crossing is denied, the NPC survives.
npc_transfer_zone_manager_error_keeps_entity() ->
    ZMPid = start_mock_zone_manager(#{ensure_zone => {error, max_zones_reached}}),
    Pid = start_zone(#{
        world_id => ~"npc_transfer_zm_error",
        coords => {0, 0},
        zone_size => ?NPC_MARGIN_ZONE_SIZE,
        rehome_margin => ?NPC_MARGIN_REHOME_MARGIN,
        zone_manager_pid => ZMPid
    }),
    try
        asobi_zone:add_entity(Pid, ~"npc1", #{type => ~"npc", x => 245.0, y => 0.0}),
        timer:sleep(10),
        asobi_zone:tick(Pid, 1),
        timer:sleep(20),
        Npc = maps:get(~"npc1", asobi_zone:get_entities(Pid)),
        ?assert(maps:get(x, Npc) < ?NPC_MARGIN_ZONE_SIZE)
    after
        gen_server:stop(Pid),
        ZMPid ! stop
    end.

%% asobi#271: an unloaded neighbour is the normal state under lazy_zones, so
%% the NPC crossing path asks the zone manager to create it - exactly as
%% asobi_world_server:handle_move/4 does for a crossing player - and tells
%% the world server about the creation so it can backfill subscribers (#275).
npc_transfer_creates_unloaded_target_zone() ->
    WorldId = ~"npc_transfer_creates_target",
    Config = #{
        world_id => WorldId,
        zone_size => ?NPC_MARGIN_ZONE_SIZE,
        rehome_margin => ?NPC_MARGIN_REHOME_MARGIN
    },
    ZMPid = start_mock_zone_manager(#{spawn_zone_config => Config}),
    Pid = start_zone(Config#{
        coords => {0, 0}, zone_manager_pid => ZMPid, world_server_pid => self()
    }),
    flush_messages(),
    try
        asobi_zone:add_entity(Pid, ~"npc1", #{type => ~"npc", x => 245.0, y => 0.0}),
        timer:sleep(10),
        asobi_zone:tick(Pid, 1),
        timer:sleep(50),
        ?assertNot(maps:is_key(~"npc1", asobi_zone:get_entities(Pid))),
        receive
            {'$gen_cast', {zone_created, Coords, TargetPid}} ->
                ?assertEqual({1, 0}, Coords),
                ?assert(maps:is_key(~"npc1", asobi_zone:get_entities(TargetPid))),
                gen_server:stop(TargetPid)
        after 1000 -> ?assert(false, timeout_waiting_for_zone_created)
        end
    after
        gen_server:stop(Pid),
        ZMPid ! stop
    end.

%% Regression for widgrensit/asobi#269: the crossing fold matched entity
%% fields by atom key only, so an entity map shaped the way the Lua bridge
%% hands one over - every key a binary - never reached classify_crossing/5 at
%% all and simply stayed in the wrong zone forever.
binary_keyed_npc_past_margin_transfers() ->
    WorldId = ~"npc_margin_past_binary",
    Config = #{
        world_id => WorldId,
        zone_size => ?NPC_MARGIN_ZONE_SIZE,
        rehome_margin => ?NPC_MARGIN_REHOME_MARGIN
    },
    Pid = start_zone(Config#{coords => {0, 0}}),
    TargetPid = start_zone(Config#{coords => {1, 0}}),
    asobi_zone:add_entity(Pid, ~"npc1", #{~"type" => ~"npc", ~"x" => 245.0, ~"y" => 0.0}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(20),
    ?assertNot(maps:is_key(~"npc1", asobi_zone:get_entities(Pid))),
    ?assert(maps:is_key(~"npc1", asobi_zone:get_entities(TargetPid))),
    gen_server:stop(Pid),
    gen_server:stop(TargetPid).

%% Same root cause as above: has_tickable_entities/1 read the type by atom
%% key, so a zone full of Lua-owned NPCs looked empty and hibernated.
tick_no_hibernate_with_binary_keyed_npcs() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, ~"npc1", #{~"type" => ~"npc", ~"x" => 0, ~"y" => 0}),
    timer:sleep(10),
    asobi_zone:tick(Pid, 1),
    timer:sleep(50),
    {current_function, CF} = erlang:process_info(Pid, current_function),
    ?assertNotEqual({erlang, hibernate, 3}, CF),
    gen_server:stop(Pid).

reap_stops_empty_zone() ->
    Pid = start_zone(),
    Ref = monitor(process, Pid),
    asobi_zone:reap(Pid),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> ?assert(false, timeout_waiting_for_reap_stop)
    end.

%% asobi#283, found via the nightly prop_input_never_dropped flake (#282):
%% asobi_zone_manager:release_zone/2 backdates a zone's last-active stamp the
%% moment it empties out, so it becomes reap-eligible on the next sweep. But
%% nothing un-stales that timestamp on re-occupation for a zone with no live
%% subscribers - this zone's own tick only touches the manager on the
%% map_size(Subs) > 0 branch, and neither does asobi_zone_manager:ensure_zone
%% for an existing zone. A zone could empty, get re-occupied (players joined
%% with no live session, exactly as prop_input_never_dropped's harness does),
%% and still get torn down by a sweep the manager scheduled while it was
%% briefly empty. The zone is the one source of truth for its own occupancy
%% at the moment it actually receives the cast, so it must decline instead
%% of trusting the manager's bookkeeping - and re-touch so the manager's
%% timestamp catches up instead of retrying every sweep.
reap_declines_when_occupied() ->
    ZMPid = start_mock_zone_manager(),
    Pid = start_zone(#{zone_manager_pid => ZMPid}),
    asobi_zone:add_entity(Pid, <<"p1">>, #{type => ~"player", x => 0, y => 0}),
    timer:sleep(10),
    asobi_zone:reap(Pid),
    timer:sleep(20),
    ?assert(is_process_alive(Pid)),
    ZMPid ! {get_touches, self()},
    receive
        {touches, Touches} ->
            ?assert(length(Touches) > 0),
            ?assertEqual({0, 0}, hd(Touches))
    after 1000 ->
        ?assert(false, timeout_waiting_for_touch)
    end,
    gen_server:stop(Pid),
    ZMPid ! stop.

sync_drains_live_zone() ->
    Pid = start_zone(),
    asobi_zone:add_entity(Pid, <<"p1">>, #{type => ~"player", x => 0, y => 0}),
    ?assertEqual(ok, asobi_zone:sync(Pid)),
    ?assert(maps:is_key(<<"p1">>, asobi_zone:get_entities(Pid))),
    gen_server:stop(Pid).

%% asobi#283: a zone reaped between a caller resolving its pid and draining
%% its casts used to exit that caller with {normal, {gen_server, call, _}} -
%% for asobi_world_server that meant the whole world gen_statem going down
%% over one player's placement.
sync_reports_stopped_zone() ->
    Pid = start_zone(),
    gen_server:stop(Pid),
    ?assertEqual(zone_gone, asobi_zone:sync(Pid)).

start_mock_zone_manager() ->
    start_mock_zone_manager(#{}).

start_mock_zone_manager(Opts) ->
    spawn(fun() -> mock_zm_loop([], Opts) end).

mock_zm_loop(Touches, Opts) ->
    receive
        {'$gen_cast', {touch_zone, Coords}} ->
            mock_zm_loop([Coords | Touches], Opts);
        {get_touches, From} ->
            From ! {touches, Touches},
            mock_zm_loop(Touches, Opts);
        {'$gen_call', From, {lookup_zone, _Coords}} ->
            gen_server:reply(From, not_loaded),
            mock_zm_loop(Touches, Opts);
        {'$gen_call', From, {ensure_zone, Coords}} ->
            gen_server:reply(From, mock_zm_ensure(Coords, Opts)),
            mock_zm_loop(Touches, Opts);
        stop ->
            ok
    end.

mock_zm_ensure(Coords, Opts) ->
    case maps:get(ensure_zone, Opts, undefined) of
        undefined ->
            Config = maps:get(spawn_zone_config, Opts, #{}),
            {ok, start_zone(Config#{coords => Coords}), created};
        Reply ->
            Reply
    end.

flush_messages() ->
    receive
        _ -> flush_messages()
    after 0 -> ok
    end.

%% The seq a client stamps on a world.input frame is whatever it sent, and
%% `player_input/4` is exported - so proving the zone survives a spec-violating
%% one means handing it a value the spec forbids. `dynamic()` is the honest
%% type for a value that crossed the wire, and it is confined to this helper:
%% it enters `player_input/4` and never leaves it (docs/eqwalizer-idioms.md).
-spec off_the_wire(term()) -> dynamic().
off_the_wire(Seq) ->
    Seq.
