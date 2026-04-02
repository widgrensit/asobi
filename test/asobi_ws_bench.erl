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

%% Phase 1: Bulk register players. This is slow (pbkdf2) but only runs once.
register_players(Config) ->
    Total = env_int("ASOBI_BENCH_PLAYERS", 1000),
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
    ct:pal("  Errors: ~w", [Total - Registered]),
    ?assert(Registered > 0),
    File = "/tmp/asobi_bench_players.term",
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

    lists:foreach(
        fun({Token, _PlayerId}) ->
            spawn_link(fun() ->
                Parent ! {Ref, ws_worker(Port, Token, MsgsPerConn)}
            end)
        end,
        Players
    ),

    Results = collect(Ref, ActualN, [], 180_000),
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

    case SuccessCount of
        0 ->
            ct:pal("  Throughput: N/A (no successes)");
        _ ->
            ElapsedSafe =
                case ElapsedMs < 1.0 of
                    true -> 1.0;
                    false -> ElapsedMs
                end,
            ct:pal("  Msg throughput:  ~w msg/sec", [round(TotalMsgsSent * 1000 / ElapsedSafe)]),
            ct:pal("  Conn throughput: ~w conn/sec", [round(SuccessCount * 1000 / ElapsedSafe)])
    end,

    AllLatencies = lists:flatmap(
        fun({ok, #{latencies := Ls}}) when is_list(Ls) -> Ls end,
        Successes
    ),
    print_latency_report(AllLatencies),

    ?assert(SuccessCount > ActualN div 2),
    Config.

%% --- WS Worker ---

ws_worker(Port, Token, MsgsPerConn) ->
    try
        {ok, ConnPid} = gun:open("localhost", Port, #{protocols => [http]}),
        {ok, _Protocol} = gun:await_up(ConnPid, 10000),

        StreamRef = gun:ws_upgrade(ConnPid, "/ws"),
        receive
            {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers} -> ok
        after 10000 ->
            error(ws_upgrade_timeout)
        end,

        %% Authenticate
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
        after 10000 ->
            error(auth_timeout)
        end,

        Latencies = heartbeat_loop(ConnPid, StreamRef, MsgsPerConn, []),
        gun:close(ConnPid),
        {ok, #{latencies => Latencies}}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, hd(Stack)}}
    end.

heartbeat_loop(_ConnPid, _StreamRef, 0, Acc) ->
    lists:reverse(Acc);
heartbeat_loop(ConnPid, StreamRef, Remaining, Acc) ->
    Msg = json:encode(#{
        ~"type" => ~"session.heartbeat",
        ~"cid" => integer_to_binary(Remaining)
    }),
    T0 = erlang:monotonic_time(microsecond),
    gun:ws_send(ConnPid, StreamRef, {text, Msg}),
    receive
        {gun_ws, ConnPid, StreamRef, {text, _Reply}} ->
            Latency = erlang:monotonic_time(microsecond) - T0,
            heartbeat_loop(ConnPid, StreamRef, Remaining - 1, [Latency | Acc])
    after 10000 ->
        lists:reverse(Acc)
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
    ct:pal("~n  Heartbeat RTT:"),
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
