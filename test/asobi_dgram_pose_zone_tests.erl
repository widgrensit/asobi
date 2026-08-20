-module(asobi_dgram_pose_zone_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pose production from inside a real zone tick: does the zone emit what the
%% plane expects, and does it stay silent when it should?

-define(GAME, asobi_test_world_game).

zone_pose_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a zone with no manifest emits nothing", fun no_manifest_no_pose/0},
        {"a zone with the binary wire off emits nothing", fun no_binary_wire_no_pose/0},
        {"an entity the wire cannot carry takes the zone off the plane",
            fun unencodable_entity_stops_the_plane/0},
        {"a passing refusal costs one tick of poses, not the plane",
            fun passing_refusal_recovers/0},
        {"a zone with no datagram subscribers emits nothing", fun no_subscribers_no_pose/0},
        {"a client on the JSON wire is not sent poses it cannot resolve",
            fun json_wire_client_gets_no_pose/0},
        {"a moving entity produces a decodable pose", fun moving_entity_produces_pose/0},
        {"pose and the binary wire share one slot map", fun one_slot_map/0},
        {"the pose sequence is independent of frame_seq", fun independent_sequences/0}
    ]}.

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    Prev = [{K, application:get_env(asobi, K)} || K <- [dgram_pose, binary_wire]],
    application:set_env(asobi, dgram_pose, #{
        period_ticks => 20,
        fields => [#{name => ~"x", scale => 100}, #{name => ~"y", scale => 100}]
    }),
    %% The plane's precondition, not a detail of the fixture - see
    %% `asobi_dgram_pose:manifest/0`.
    application:set_env(asobi, binary_wire, true),
    %% Stand in for the mint's ETS mirror. The zone reads it directly, so a test
    %% can populate it without a whole engine behind it.
    ensure_table(asobi_dgram_conns, [named_table, public, {read_concurrency, true}]),
    %% ...and for the link client, which is where a pose leaves the engine.
    %%
    %% Captured into ETS rather than sent to a pid: eunit runs the fixture in a
    %% different process from the test body, so a mock that messaged `self()`
    %% here would deliver every pose to a process nothing ever reads.
    ensure_table(asobi_pose_capture, [named_table, public, ordered_set]),
    meck:new(asobi_dgram_link_client, [non_strict]),
    meck:expect(asobi_dgram_link_client, pose, fun(Body, ConnIds) ->
        ets:insert(asobi_pose_capture, {erlang:unique_integer([monotonic]), Body, ConnIds}),
        ok
    end),
    Prev.

cleanup(Prev) ->
    meck:unload(asobi_dgram_link_client),
    %% The mirror is a named table the real mint creates for itself at boot, so a
    %% stand-in left behind here makes any later test that starts a mint crash on
    %% `already_exists`.
    drop_table(asobi_dgram_conns),
    drop_table(asobi_pose_capture),
    [
        case V of
            undefined -> application:unset_env(asobi, K);
            {ok, Val} -> application:set_env(asobi, K, Val)
        end
     || {K, V} <- Prev
    ],
    ok.

drop_table(Name) ->
    case ets:whereis(Name) of
        undefined -> ok;
        _Tid -> ets:delete(Name)
    end,
    ok.

%% --- Tests ---

%% Guessing a scale for a world of unknown size is worse than not doing this at
%% all, so an unconfigured game gets no plane rather than a badly quantised one.
no_manifest_no_pose() ->
    application:unset_env(asobi, dgram_pose),
    Pid = start_zone(),
    ets:insert(asobi_dgram_conns, {~"p1", 4242, true}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_pose, recv_pose()),
    gen_server:stop(Pid).

%% asobi#509. Emitting poses with the wire off burned an encode per tick to
%% produce datagrams every client discarded.
no_binary_wire_no_pose() ->
    application:set_env(asobi, binary_wire, false),
    Pid = start_zone(),
    ets:insert(asobi_dgram_conns, {~"p1", 4242, true}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_pose, recv_pose()),
    gen_server:stop(Pid).

%% asobi#510. An entity the encoder cannot take drops the frame to text, and a
%% text add carries no slot - so no client can resolve a pose, for this entity or
%% any other in the zone. The zone latches to the text wire instead of streaming
%% datagrams every client would discard, and every entity keeps moving on
%% `world.tick`, which is the carrier that can name them.
unencodable_entity_stops_the_plane() ->
    Pid = start_zone(),
    ets:insert(asobi_dgram_conns, {~"p1", 4242, true}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    %% A list is not one of the six scalar types the wire carries, so the frame
    %% announcing this entity is refused and sent as text.
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0, ~"path" => [1, 2]}),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_pose, recv_pose()),
    gen_server:stop(Pid).

%% A refusal that passes must not cost the zone its plane. The frame that follows
%% one is a keyframe, so every client is rebound in a single broadcast interval
%% and the poses resume - the plane pauses for one tick rather than latching off.
passing_refusal_recovers() ->
    Pid = start_zone(),
    ets:insert(asobi_dgram_conns, {~"p1", 4242, true}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 1),
    ?assertMatch({pose, _, _}, recv_pose()),

    %% A frame the encoder refuses: no poses this tick, because no client can be
    %% sure of its slot table until the repair lands.
    asobi_zone:add_entity(Pid, ~"e2", #{~"x" => 5.0, ~"y" => 5.0, ~"path" => [1, 2]}),
    asobi_zone:tick(Pid, 2),
    ?assertEqual(no_pose, recv_pose()),

    %% The offending entity leaves, the keyframe rebinds everyone, poses resume.
    asobi_zone:remove_entity(Pid, ~"e2"),
    asobi_zone:tick(Pid, 3),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 7.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 4),
    ?assertMatch({pose, _, _}, recv_pose()),
    gen_server:stop(Pid).

%% Building a body for nobody is the one cost on this path that is trivially
%% avoidable, and a zone whose players are all on the WebSocket is the common case.
no_subscribers_no_pose() ->
    Pid = start_zone(),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_pose, recv_pose()),
    gen_server:stop(Pid).

%% The end of the whole chain: a zone tick becomes bytes a client can decode into
%% a position.
moving_entity_produces_pose() ->
    Pid = start_zone(),
    ets:insert(asobi_dgram_conns, {~"p1", 4242, true}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 12.5, ~"y" => -3.25}),
    asobi_zone:tick(Pid, 1),
    {pose, Body, ConnIds} = recv_pose(),
    ?assertEqual([4242], ConnIds),

    %% Decodes as the header the plane's own codec writes.
    <<Tick:32/little, BSeq:32/little, ZX:16/signed-little, ZY:16/signed-little, FieldMask:8,
        Count:8, _Epoch:16/little, Rest/binary>> = Body,
    ?assertEqual({1, 0, 0, 0, 2#11, 1}, {Tick, BSeq, ZX, ZY, FieldMask, Count}),

    %% ...and the record is the entity, quantised at the configured scale.
    <<_Slot:16/little, _Gen:8, RMask:8, X:16/signed-little, Y:16/signed-little>> = Rest,
    ?assertEqual(2#11, RMask),
    ?assertEqual({1250, -325}, {X, Y}),
    gen_server:stop(Pid).

%% Two slot allocations for one zone would eventually disagree about which entity
%% holds a slot, which is exactly the class of defect ADR 0011 exists to close. So
%% the pose plane and the binary wire read the SAME slot, and this proves it by
%% comparing the two wires' own bytes.
one_slot_map() ->
    Pid = start_zone(),
    ets:insert(asobi_dgram_conns, {~"p1", 4242, true}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 1),

    {pose, Body, _} = recv_pose(),
    <<_:128, PoseSlot:16/little, PoseGen:8, _/binary>> = Body,
    {zone_delta_raw, _Json, Bin} = recv_delta(),
    {ok, #{records := [#{slot := WireSlot, gen := WireGen}]}} = asobi_wire:decode(Bin),

    ?assertEqual(WireSlot, PoseSlot),
    ?assertEqual(WireGen, PoseGen),
    gen_server:stop(Pid).

%% The two carriers lose frames independently, so sharing a counter would make
%% each look like it had gaps the other caused. A client gap-detects them apart.
independent_sequences() ->
    Pid = start_zone(),
    ets:insert(asobi_dgram_conns, {~"p1", 4242, true}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 1),
    {pose, First, _} = recv_pose(),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 9.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 2),
    {pose, Second, _} = recv_pose(),
    <<_:32, A:32/little, _/binary>> = First,
    <<_:32, B:32/little, _/binary>> = Second,
    ?assertEqual(0, A),
    ?assertEqual(1, B),
    gen_server:stop(Pid).

%% --- Helpers ---

%% Created once and emptied between fixtures. `try` rather than `catch`, because
%% the only expected failure is "already exists" and swallowing everything would
%% hide a real one.
ensure_table(Name, Opts) ->
    try
        ets:new(Name, Opts)
    catch
        error:badarg -> ets:delete_all_objects(Name)
    end,
    ets:delete_all_objects(Name).

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

%% Takes the oldest captured pose, so consecutive calls walk the stream in the
%% order the zone produced it.
recv_pose() -> recv_pose(30).

recv_pose(0) ->
    no_pose;
recv_pose(N) ->
    case ets:first(asobi_pose_capture) of
        '$end_of_table' ->
            timer:sleep(20),
            recv_pose(N - 1);
        Key ->
            [{Key, Body, ConnIds}] = ets:lookup(asobi_pose_capture, Key),
            ets:delete(asobi_pose_capture, Key),
            {pose, Body, ConnIds}
    end.

recv_delta() ->
    receive
        {asobi_message, Msg} when element(1, Msg) =:= zone_delta_raw -> Msg;
        {asobi_message, _Other} -> recv_delta()
    after 500 -> no_delta
    end.

%% asobi#510, one layer out from the zone. `asobi.datagram.open` mints for any
%% session with a gateway configured - deliberately, because the plane's other
%% half carries `world.input` upstream and that needs no slots, so UDP input
%% works on either wire. What it must not do is put a JSON-wire client on the
%% receiving end: it never gets an `add` record, so every pose names a slot it
%% cannot resolve and drops it, and the entity looks frozen with nothing logged
%% anywhere. The mint records the answer; the zone asks for it.
json_wire_client_gets_no_pose() ->
    Pid = start_zone(),
    %% Minted, and on the text wire - the flag the mint writes for it.
    ets:insert(asobi_dgram_conns, {~"p1", 4242, false}),
    asobi_zone:subscribe(Pid, {~"p1", self()}),
    asobi_zone:add_entity(Pid, ~"e1", #{~"x" => 1.0, ~"y" => 2.0}),
    asobi_zone:tick(Pid, 1),
    ?assertEqual(no_pose, recv_pose()),
    gen_server:stop(Pid).
