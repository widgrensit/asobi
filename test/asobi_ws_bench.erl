-module(asobi_ws_bench).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([register_players/1, ws_throughput/1]).

-define(PASSWORD, ~"wsbench_pass123").

all() -> [{group, bench}].

groups() ->
    [{bench, [sequence], [register_players, ws_throughput]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gun),
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    Config.

%% Phase 1: Bulk register players. Reuses cached file if enough exist.
register_players(Config) ->
    File = "/tmp/asobi_bench_players.term",
    Total = env_int("ASOBI_BENCH_PLAYERS", 1000),
    case file:read_file(File) of
        {ok, Bin} ->
            Existing =
                case binary_to_term(Bin) of
                    L when is_list(L) -> L
                end,
            case length(Existing) >= Total of
                true ->
                    ct:pal("~n=== Reusing ~w pre-registered players ===", [length(Existing)]),
                    Config;
                false ->
                    do_register(Total, File, Config)
            end;
        {error, _} ->
            do_register(Total, File, Config)
    end.

do_register(Total, File, Config) ->
    BatchSize = env_int("ASOBI_BENCH_BATCH", 50),
    ct:pal("~n=== Registering ~w players (batch size ~w) ===", [Total, BatchSize]),

    T0 = erlang:monotonic_time(millisecond),
    Players = register_batches(Total, BatchSize, 0, Config, []),
    Elapsed = erlang:monotonic_time(millisecond) - T0,

    Registered = length(Players),
    Rate =
        case Elapsed of
            0 -> 0;
            E when is_integer(E) -> Registered * 1000 div E
        end,
    ct:pal("  Registered: ~w players in ~wms (~w/sec)", [Registered, Elapsed, Rate]),
    ?assert(Registered > 0),
    file:write_file(File, term_to_binary(Players)),
    Config.

%% Phase 2: Open WS connections from the player pool and blast heartbeats.
ws_throughput(Config) ->
    Connections = env_int("ASOBI_WS_N", 500),
    MsgsPerConn = env_int("ASOBI_WS_MSGS", 200),
    Port = proplists:get_value(nova_test_port, Config, 8082),

    %% Pick players from the pool (saved to file by register_players)
    {ok, Bin} = file:read_file("/tmp/asobi_bench_players.term"),
    AllPlayers =
        case binary_to_term(Bin) of
            L when is_list(L) -> L
        end,
    Players = lists:sublist(AllPlayers, Connections),
    ActualN = length(Players),

    ct:pal("~n=== WebSocket Benchmark ==="),
    ct:pal("  Connections:    ~w", [ActualN]),
    ct:pal("  Msgs/conn:      ~w", [MsgsPerConn]),
    ct:pal("  Total messages: ~w", [ActualN * MsgsPerConn]),

    Parent = self(),
    Ref = make_ref(),
    MemBefore = erlang:memory(total),
    T0 = erlang:monotonic_time(microsecond),

    %% Phase A: Connect all WS clients in waves
    ct:pal("  Connecting..."),
    WaveSize = env_int("ASOBI_WS_WAVE", 200),
    ConnRef = make_ref(),
    connect_waves(Players, WaveSize, Port, Parent, ConnRef),
    Conns = collect(ConnRef, ActualN, [], 120_000),
    LiveConns = [{C, S} || {ok, {C, S}} <- Conns],
    ConnectedN = length(LiveConns),
    ct:pal("  Connected: ~w of ~w", [ConnectedN, ActualN]),

    %% Phase B: Blast messages from all connections simultaneously
    ct:pal("  Blasting ~w msgs each...", [MsgsPerConn]),
    BlastRef = make_ref(),
    lists:foreach(
        fun({ConnPid, StreamRef}) ->
            spawn_link(fun() ->
                T0B = erlang:monotonic_time(microsecond),
                blast_messages(ConnPid, StreamRef, MsgsPerConn),
                Received = drain_replies(ConnPid, StreamRef, MsgsPerConn, 0),
                ElapsedB = erlang:monotonic_time(microsecond) - T0B,
                gun:close(ConnPid),
                Parent !
                    {BlastRef,
                        {ok, #{elapsed_us => ElapsedB, sent => MsgsPerConn, received => Received}}}
            end)
        end,
        LiveConns
    ),
    Results = collect(BlastRef, length(LiveConns), [], 300_000),
    Elapsed = erlang:monotonic_time(microsecond) - T0,
    MemAfter = erlang:memory(total),

    {Successes, Failures} = lists:partition(
        fun
            ({ok, _}) -> true;
            (_) -> false
        end,
        Results
    ),

    SuccessCount = length(Successes),
    TotalMsgsSent = SuccessCount * MsgsPerConn,
    ElapsedMs = Elapsed / 1000,
    MemDelta = (MemAfter - MemBefore) / 1048576,

    ct:pal("~n=== Results ==="),
    ct:pal("  Connections:    ~w ok, ~w failed", [SuccessCount, length(Failures)]),
    ct:pal("  Messages sent:  ~w", [TotalMsgsSent]),
    ct:pal("  Wall clock:     ~w ms", [round(ElapsedMs)]),
    ct:pal("  Peak mem delta: ~w MB", [round(MemDelta)]),

    lists:foreach(
        fun(F) -> ct:pal("  FAILURE: ~p", [F]) end,
        lists:sublist(Failures, 5)
    ),

    TotalReceived = lists:sum([R || {ok, #{received := R}} <- Successes]),

    case SuccessCount of
        0 ->
            ct:pal("  Throughput: N/A (no successes)");
        _ ->
            ElapsedSafe =
                case ElapsedMs < 1.0 of
                    true -> 1.0;
                    false -> ElapsedMs
                end,
            ct:pal("  Msgs received:  ~w", [TotalReceived]),
            ct:pal("  Msg throughput:  ~w msg/sec (sent)", [
                round(TotalMsgsSent * 1000 / ElapsedSafe)
            ]),
            ct:pal("  Msg throughput:  ~w msg/sec (recv)", [
                round(TotalReceived * 1000 / ElapsedSafe)
            ]),
            ct:pal("  Conn throughput: ~w conn/sec", [round(SuccessCount * 1000 / ElapsedSafe)])
    end,

    %% Per-worker RTT (total elapsed / msgs)
    WorkerRtts = [
        E div max(1, S)
     || {ok, #{elapsed_us := E, sent := S}} <- Successes, is_integer(E), is_integer(S)
    ],
    print_latency_report(WorkerRtts),

    ?assert(SuccessCount > ActualN div 2),
    Config.

connect_waves([], _WaveSize, _Port, _Parent, _Ref) ->
    ok;
connect_waves(Players, WaveSize, Port, Parent, Ref) ->
    {Wave, Rest} =
        case length(Players) > WaveSize of
            true -> lists:split(WaveSize, Players);
            false -> {Players, []}
        end,
    lists:foreach(
        fun({Token, _PlayerId}) ->
            spawn_link(fun() ->
                Parent ! {Ref, ws_connect(Port, Token)}
            end)
        end,
        Wave
    ),
    timer:sleep(100),
    connect_waves(Rest, WaveSize, Port, Parent, Ref).

%% --- WS Connect (returns gun pid + stream ref) ---

ws_connect(Port, Token) ->
    try
        {ok, ConnPid} = gun:open("localhost", Port, #{protocols => [http]}),
        {ok, _Protocol} = gun:await_up(ConnPid, 30000),

        StreamRef = gun:ws_upgrade(ConnPid, "/ws"),
        receive
            {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers} -> ok
        after 30000 ->
            error(ws_upgrade_timeout)
        end,

        AuthMsg = json:encode(#{
            ~"type" => ~"session.connect",
            ~"cid" => ~"auth",
            ~"payload" => #{~"token" => Token}
        }),
        gun:ws_send(ConnPid, StreamRef, {text, AuthMsg}),
        receive
            {gun_ws, ConnPid, StreamRef, {text, AuthReply}} ->
                case json:decode(AuthReply) of
                    #{~"type" := ~"session.connected"} -> ok;
                    #{~"type" := ~"error"} -> error(auth_failed)
                end
        after 60000 ->
            error(auth_timeout)
        end,
        {ok, {ConnPid, StreamRef}}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, hd(Stack)}}
    end.

blast_messages(_ConnPid, _StreamRef, 0) ->
    ok;
blast_messages(ConnPid, StreamRef, Remaining) ->
    Msg = json:encode(#{
        ~"type" => ~"session.heartbeat",
        ~"cid" => integer_to_binary(Remaining)
    }),
    gun:ws_send(ConnPid, StreamRef, {text, Msg}),
    blast_messages(ConnPid, StreamRef, Remaining - 1).

drain_replies(_ConnPid, _StreamRef, 0, Count) ->
    Count;
drain_replies(ConnPid, StreamRef, Remaining, Count) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, _}} ->
            drain_replies(ConnPid, StreamRef, Remaining - 1, Count + 1)
    after 15000 ->
        Count
    end.

%% --- Registration Batches ---

register_batches(0, _BatchSize, Done, _Config, Acc) ->
    ct:pal("  ... registered ~w total", [Done]),
    Acc;
register_batches(Remaining, BatchSize, Done, Config, Acc) ->
    Batch =
        case min(Remaining, BatchSize) of
            B when is_integer(B) -> B
        end,
    Parent = self(),
    Ref = make_ref(),
    lists:foreach(
        fun(I) ->
            spawn_link(fun() ->
                Idx =
                    Done +
                        case I of
                            II when is_integer(II) -> II
                        end,
                Username = asobi_test_helpers:unique_username(
                    iolist_to_binary([~"bench_", integer_to_binary(Idx)])
                ),
                Result =
                    try
                        {ok, Resp} = nova_test:post(
                            "/api/v1/auth/register",
                            #{json => #{~"username" => Username, ~"password" => ?PASSWORD}},
                            Config
                        ),
                        case nova_test:status(Resp) of
                            S when S >= 200, S < 300 ->
                                Body = nova_test:json(Resp),
                                #{~"session_token" := Token, ~"player_id" := PlayerId} = Body,
                                true = is_binary(Token),
                                true = is_binary(PlayerId),
                                {ok, {Token, PlayerId}};
                            _ ->
                                error
                        end
                    catch
                        _:_ -> error
                    end,
                Parent ! {Ref, Result}
            end)
        end,
        lists:seq(1, Batch)
    ),
    BatchResults = collect(Ref, Batch, [], 120_000),
    NewPlayers = [{T, P} || {ok, {T, P}} <- BatchResults],
    NewDone = Done + Batch,
    case NewDone rem 500 of
        0 -> ct:pal("  ... ~w registered", [NewDone]);
        _ -> ok
    end,
    register_batches(Remaining - Batch, BatchSize, NewDone, Config, NewPlayers ++ Acc).

%% --- Helpers ---

collect(_Ref, 0, Acc, _Timeout) ->
    Acc;
collect(Ref, Remaining, Acc, Timeout) ->
    receive
        {Ref, Result} -> collect(Ref, Remaining - 1, [Result | Acc], Timeout)
    after Timeout ->
        ct:pal("  TIMEOUT: ~w workers did not respond", [Remaining]),
        Acc
    end.

print_latency_report([]) ->
    ct:pal("  No latency data.");
print_latency_report(AllLatencies) ->
    Sorted = lists:sort(AllLatencies),
    Len = length(Sorted),
    P50 = nth_pct(Sorted, Len, 50),
    P95 = nth_pct(Sorted, Len, 95),
    P99 = nth_pct(Sorted, Len, 99),
    Min = hd(Sorted),
    Max = lists:last(Sorted),
    ct:pal("~n  Avg RTT per worker:"),
    ct:pal("    p50:  ~w us", [P50]),
    ct:pal("    p95:  ~w us", [P95]),
    ct:pal("    p99:  ~w us", [P99]),
    ct:pal("    min:  ~w us", [Min]),
    ct:pal("    max:  ~w us", [Max]).

nth_pct(Sorted, Len, P) ->
    Idx = max(1, min(Len, ceil(Len * P / 100))),
    case Idx of
        I when is_integer(I) -> lists:nth(I, Sorted)
    end.

env_int(Name, Default) ->
    list_to_integer(os:getenv(Name, integer_to_list(Default))).
