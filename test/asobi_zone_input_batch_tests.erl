-module(asobi_zone_input_batch_tests).
-moduledoc """
`handle_input_batch/2`: a zone hands a whole tick's inputs to a game module that
exports it, and the `world.ack` policy comes out identical to the per-input
path.

The batch exists because `asobi_lua_world` re-encoded the entire entity map into
Luerl once per input. What must not change is the ack contract, so most of these
mirror the `#474`/`#532` cases in `asobi_zone_tests` against the batch module.
""".
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_batch_test_game).

-export([on_telemetry/4]).

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    %% no_input_callback_acks_and_drops/0 attaches to [asobi, error] to prove the
    %% counter is emitted outside the limiter.
    {ok, _} = application:ensure_all_started(telemetry),
    ok.

start_zone() ->
    {ok, Pid} = asobi_zone:start_link(#{
        world_id => ~"batch_test_world",
        coords => {0, 0},
        ticker_pid => self(),
        game_module => ?GAME,
        zone_state => #{},
        broadcast_interval => 1
    }),
    Pid.

batch_test_() ->
    {setup, fun setup/0, [
        {"a module exporting handle_input_batch/2 gets one call, not one per input",
            fun one_call_per_tick/0},
        {"the per-input path is untouched for a module without it", fun single_path_intact/0},
        {"entities come back applied, in arrival order", fun applies_in_order/0},
        {"an ok outcome acks the frame stamp", fun ok_acks_stamp/0},
        {"a consumed outcome acks the reported seq, not the stamp", fun consumed_acks_report/0},
        {"an error outcome still advances the ack", fun error_advances_ack/0},
        {"a report still beats a stamp made later in the same tick", fun report_beats_stamp/0},
        {"an outcome list of the wrong length acks nothing and does not re-run",
            fun bad_length_acks_nothing_without_rerun/0},
        {"a contract violation does not bury another player's reported watermark",
            fun mismatch_does_not_bury_a_report/0},
        {"a non-conforming return keeps the entities the ZONE held",
            fun non_conforming_return_keeps_zone_entities/0},
        {"a tuple-tagged rejection reason keeps its tag", fun tuple_reason_keeps_its_tag/0},
        {"an unknown outcome falls back to the frame stamp", fun unknown_outcome_stamps/0},
        {"a nonsense consumed seq falls back to the frame stamp", fun invalid_consumed_stamps/0},
        {"an improper outcome list does not kill the zone", fun improper_outcome_list_survives/0},
        {"a non-list outcome does not kill the zone", fun non_list_outcome_survives/0},
        {"an unstamped input still produces no ack", fun unstamped_produces_no_ack/0},
        {"a module with no input callback at all keeps the zone alive",
            fun no_input_callback_acks_and_drops/0}
    ]}.

one_call_per_tick() ->
    Pid = start_zone(),
    add_player(Pid, ~"p1"),
    add_player(Pid, ~"p2"),
    move(Pid, ~"p1", 1, 1, 10),
    move(Pid, ~"p2", 2, 2, 11),
    move(Pid, ~"p1", 3, 3, 12),
    asobi_zone:tick(Pid, 1),
    ok = asobi_zone:sync(Pid),
    ?assertEqual([{batch, 3}], ?GAME:calls(Pid)),
    gen_server:stop(Pid).

%% asobi_test_world_game does not export handle_input_batch/2, so it must still
%% take the per-input path with its ack behaviour unchanged.
single_path_intact() ->
    {ok, Pid} = asobi_zone:start_link(#{
        world_id => ~"batch_test_world_single",
        coords => {0, 0},
        ticker_pid => self(),
        game_module => asobi_test_world_game,
        zone_state => #{},
        broadcast_interval => 1
    }),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"p1", #{x => 0, y => 0, type => ~"player"}),
    ok = asobi_zone:sync(Pid),
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"move", ~"x" => 5, ~"y" => 5}, 412),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(412, recv_ack()),
    Entities = asobi_zone:get_entities(Pid),
    ?assertMatch(#{x := 5, y := 5}, maps:get(~"p1", Entities)),
    gen_server:stop(Pid).

applies_in_order() ->
    Pid = start_zone(),
    add_player(Pid, ~"p1"),
    move(Pid, ~"p1", 1, 1, 1),
    move(Pid, ~"p1", 2, 2, 2),
    move(Pid, ~"p1", 9, 9, 3),
    asobi_zone:tick(Pid, 1),
    ok = asobi_zone:sync(Pid),
    Entities = asobi_zone:get_entities(Pid),
    ?assertMatch(#{x := 9, y := 9}, maps:get(~"p1", Entities)),
    gen_server:stop(Pid).

ok_acks_stamp() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    move(Pid, ~"p1", 4, 4, 77),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(77, recv_ack()),
    gen_server:stop(Pid).

consumed_acks_report() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    asobi_zone:player_input(
        Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 48}, 52
    ),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(48, recv_ack()),
    gen_server:stop(Pid).

%% No p1 entity, so the move comes back {error, not_found} - and the ack still
%% advances, exactly as the per-input path does.
error_advances_ack() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    flush(),
    move(Pid, ~"p1", 1, 1, 7),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(7, recv_ack()),
    gen_server:stop(Pid).

report_beats_stamp() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    asobi_zone:player_input(
        Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 30}, 40
    ),
    move(Pid, ~"p1", 1, 1, 99),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(30, recv_ack()),
    gen_server:stop(Pid).

%% Acking NOTHING, not by stamp: the session's ack gate is monotonic, so a stamp
%% here would permanently bury any watermark the module meant to report. A
%% missing ack is recoverable - the next clean tick acks past it.
bad_length_acks_nothing_without_rerun() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    %% Two inputs, one outcome: a contract violation.
    asobi_zone:player_input(Pid, ~"p1", #{~"outcomes" => [ok]}, 5),
    move(Pid, ~"p1", 1, 1, 6),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    ok = asobi_zone:sync(Pid),
    %% The MODULE's entities, not the zone's: a wrong-length outcome list says
    %% nothing about whether the inputs were applied, and they may have been.
    ?assertMatch(#{x := 1, y := 1}, maps:get(~"p1", asobi_zone:get_entities(Pid))),
    %% One batch call and no fallback to the per-input path: re-running would
    %% double-apply whatever the batch already did.
    ?assertEqual([{batch, 2}], ?GAME:calls(Pid)),
    gen_server:stop(Pid).

unknown_outcome_stamps() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"bad_outcome"}, 21),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(21, recv_ack()),
    gen_server:stop(Pid).

%% reported_ack/5's guard is the same on both paths, but nothing drove its
%% failure arm from the batch: a negative seq is outside the ack space, so the
%% frame stamp wins and the zone stays up.
invalid_consumed_stamps() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => -1}, 64),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(64, recv_ack()),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

%% is_list/1 is true for any cons cell, so an improper list passed the old guard
%% and length/1 then raised badarg inside the zone - taking every player in it
%% down over one module's bad return.
improper_outcome_list_survives() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"outcomes" => [ok | junk]}, 11),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

non_list_outcome_survives() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"outcomes" => not_a_list}, 12),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

%% p2's malformed batch must not cost p1 the watermark p1's module reported. The
%% ack gate is monotonic, so an overclaim here is unrecoverable for that socket.
mismatch_does_not_bury_a_report() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    add_player(Pid, ~"p2"),
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 30}, 40),
    asobi_zone:player_input(Pid, ~"p2", #{~"outcomes" => [ok]}, 41),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    %% The next clean tick still acks p1 past it, which is the recoverability
    %% a frame stamp of 41 would have destroyed.
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"consume", ~"consumed" => 31}, 42),
    asobi_zone:tick(Pid, 2),
    ?assertEqual(31, recv_ack()),
    gen_server:stop(Pid).

%% The `Other` arm: the return is not {ok, Map, _} at all, so nothing in it is
%% trustworthy - including the map. Distinct from the mismatch arm, which keeps
%% the entities the module handed back.
non_conforming_return_keeps_zone_entities() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    move(Pid, ~"p1", 8, 8, 5),
    asobi_zone:player_input(Pid, ~"p1", #{~"return" => {ok, not_a_map, [ok, ok]}}, 6),
    asobi_zone:tick(Pid, 1),
    %% Acks nothing, like the mismatch arm: `{ok, not_a_map, [{consumed, 30}]}`
    %% lands here too, and stamping over that report would bury it.
    ?assertEqual(no_ack, recv_ack()),
    ok = asobi_zone:sync(Pid),
    ?assertMatch(#{x := 0, y := 0}, maps:get(~"p1", asobi_zone:get_entities(Pid))),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

%% shape_of/1's tuple clause exists so a tagged rejection reason keeps the
%% developer's own word for what went wrong instead of collapsing to `other`.
tuple_reason_keeps_its_tag() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"reject"}, 71),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(71, recv_ack()),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

unstamped_produces_no_ack() ->
    Pid = start_zone(),
    subscribe(Pid, ~"p1"),
    add_player(Pid, ~"p1"),
    flush(),
    asobi_zone:player_input(Pid, ~"p1", #{~"action" => ~"move", ~"x" => 3, ~"y" => 3}),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_ack, recv_ack()),
    gen_server:stop(Pid).

%% Both input callbacks are optional now, so this module compiles clean and the
%% only signal is at runtime. Deleting the `none` branch of the dispatch makes
%% this fail with undef inside the zone.
no_input_callback_acks_and_drops() ->
    {ok, Pid} = asobi_zone:start_link(#{
        world_id => ~"batch_test_world_no_input",
        coords => {0, 0},
        ticker_pid => self(),
        game_module => asobi_no_input_game,
        zone_state => #{},
        broadcast_interval => 1
    }),
    ok = telemetry:attach(?MODULE, [asobi, error], fun ?MODULE:on_telemetry/4, self()),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"p1", #{x => 0, y => 0, type => ~"player"}),
    ok = asobi_zone:sync(Pid),
    flush(),
    move(Pid, ~"p1", 5, 5, 33),
    asobi_zone:tick(Pid, 1),
    %% Acked so the client stops waiting, dropped because nothing can apply it,
    %% and the zone survives.
    ?assertEqual(33, recv_ack()),
    ?assert(is_process_alive(Pid)),
    ?assertMatch(#{x := 0, y := 0}, maps:get(~"p1", asobi_zone:get_entities(Pid))),
    %% The counter is the signal an operator alerts on, and it is emitted
    %% outside the limiter so suppressing the line cannot suppress the rate.
    ?assertEqual(#{game_module => asobi_no_input_game}, recv_telemetry()),
    telemetry:detach(?MODULE),
    gen_server:stop(Pid).

%% shape_of/1 is what keeps a client-influenced term out of the log while still
%% naming what went wrong. Tested directly because it is pure and because its
%% bound is the whole point.
shape_of_test() ->
    ?assertEqual({tuple, error, 2}, asobi_zone:shape_of({error, {out_of_range, 5}})),
    ?assertEqual({tuple, ok, 2}, asobi_zone:shape_of({ok, #{a => 1}})),
    ?assertEqual({tuple, {binary, 3}, 2}, asobi_zone:shape_of({~"abc", 1})),
    ?assertEqual(other, asobi_zone:shape_of({})),
    ?assertEqual({binary, 5}, asobi_zone:shape_of(~"hello")),
    ?assertEqual(map, asobi_zone:shape_of(#{a => 1})),
    ?assertEqual(number, asobi_zone:shape_of(1.5)).

%% One level, not one per nesting: recursing would be O(depth) to build and
%% O(depth^2) to pretty-print, which is a 40 GB log line for a 200k-deep tuple.
shape_of_does_not_recurse_test() ->
    Deep = nest(5000, deepest),
    ?assertEqual({tuple, other, 2}, asobi_zone:shape_of(Deep)),
    ?assert(erts_debug:flat_size(asobi_zone:shape_of(Deep)) < 20).

nest(0, Acc) -> Acc;
nest(N, Acc) -> nest(N - 1, {Acc, x}).

%% --- helpers ---

subscribe(Pid, PlayerId) ->
    asobi_zone:subscribe(Pid, {PlayerId, self()}),
    ok = asobi_zone:sync(Pid).

add_player(Pid, PlayerId) ->
    asobi_zone:add_entity(Pid, PlayerId, #{x => 0, y => 0, type => ~"player"}),
    ok = asobi_zone:sync(Pid).

move(Pid, PlayerId, X, Y, Seq) ->
    asobi_zone:player_input(Pid, PlayerId, #{~"action" => ~"move", ~"x" => X, ~"y" => Y}, Seq).

on_telemetry(_Event, _Measurements, #{kind := no_input_handler, details := Details}, Pid) ->
    Pid ! {telemetry, Details},
    ok;
on_telemetry(_Event, _Measurements, _Meta, _Pid) ->
    ok.

recv_telemetry() ->
    receive
        {telemetry, Details} -> Details
    after 300 -> no_telemetry
    end.

recv_ack() ->
    receive
        {asobi_message, {world_ack, _Tick, Seq}} -> Seq
    after 300 -> no_ack
    end.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.
