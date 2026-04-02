-module(asobi_load_bench).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([load_test/1]).

-define(DEFAULT_CONCURRENCY, 100).
-define(PASSWORD, ~"loadtest_pass123").

all() -> [load_test].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    Config.

load_test(Config) ->
    N = list_to_integer(os:getenv("ASOBI_LOAD_N", integer_to_list(?DEFAULT_CONCURRENCY))),
    ct:pal("~n=== Load Test: ~p concurrent players ===~n", [N]),

    MemBefore = erlang:memory(total),
    T0 = erlang:monotonic_time(millisecond),

    Parent = self(),
    Ref = make_ref(),
    Workers = [
        spawn_link(fun() -> Parent ! {Ref, worker(I, Config)} end)
     || I <- lists:seq(1, N)
    ],

    Results = collect(Ref, length(Workers), []),

    Elapsed =
        case erlang:monotonic_time(millisecond) - T0 of
            E when is_integer(E) -> E
        end,
    MemAfter = erlang:memory(total),
    PeakMem = MemAfter - MemBefore,

    {Successes, Failures} = lists:partition(
        fun
            ({ok, _}) -> true;
            (_) -> false
        end,
        Results
    ),
    Timings = [T || {ok, T} <- Successes],

    ct:pal("~n=== Results ==="),
    ct:pal("  Total workers:  ~p", [N]),
    ct:pal("  Successes:      ~p", [length(Successes)]),
    ct:pal("  Failures:       ~p", [length(Failures)]),
    ct:pal("  Wall clock:     ~pms", [Elapsed]),
    ElapsedSafe =
        case Elapsed of
            0 -> 1;
            _ -> Elapsed
        end,
    Throughput = length(Successes) * 1000 / ElapsedSafe,
    ct:pal("  Throughput:     ~.1f players/sec", [Throughput]),
    ct:pal("  Peak mem delta: ~.1f MB", [PeakMem / 1048576]),

    lists:foreach(
        fun({error, Reason}) ->
            ct:pal("  FAILURE: ~p", [Reason])
        end,
        Failures
    ),

    print_phase_report(Timings),

    ?assert(length(Successes) > N div 2, "More than half of workers should succeed"),
    Config.

%% --- Worker ---

worker(I, Config) ->
    try
        Username = asobi_test_helpers:unique_username(
            iolist_to_binary([~"load_", integer_to_binary(I)])
        ),
        T = #{},

        %% Register
        RegT0 = erlang:monotonic_time(microsecond),
        {ok, RegResp} = nova_test:post(
            "/api/v1/auth/register",
            #{json => #{~"username" => Username, ~"password" => ?PASSWORD}},
            Config
        ),
        RegUs = erlang:monotonic_time(microsecond) - RegT0,
        #{~"session_token" := Token0, ~"player_id" := PlayerId0} = nova_test:json(RegResp),
        true = is_binary(Token0),
        true = is_binary(PlayerId0),
        Token = Token0,
        PlayerId = PlayerId0,
        T1 = T#{register => RegUs},

        AuthHeaders = #{headers => [{~"authorization", <<"Bearer ", Token/binary>>}]},

        %% Login
        {LoginUs, {ok, _}} = timer:tc(fun() ->
            nova_test:post(
                "/api/v1/auth/login",
                #{json => #{~"username" => Username, ~"password" => ?PASSWORD}},
                Config
            )
        end),
        T2 = T1#{login => LoginUs},

        %% GET matches
        {MatchesUs, {ok, _}} = timer:tc(fun() ->
            nova_test:get("/api/v1/matches", AuthHeaders, Config)
        end),
        T3 = T2#{list_matches => MatchesUs},

        %% GET friends
        {FriendsUs, {ok, _}} = timer:tc(fun() ->
            nova_test:get("/api/v1/friends", AuthHeaders, Config)
        end),
        T4 = T3#{list_friends => FriendsUs},

        %% GET wallets
        {WalletsUs, {ok, _}} = timer:tc(fun() ->
            nova_test:get("/api/v1/wallets", AuthHeaders, Config)
        end),
        T5 = T4#{wallets => WalletsUs},

        %% GET player profile
        {ProfileUs, {ok, _}} = timer:tc(fun() ->
            nova_test:get(
                "/api/v1/players/" ++ binary_to_list(PlayerId),
                AuthHeaders,
                Config
            )
        end),
        T6 = T5#{profile => ProfileUs},

        %% GET health (unauthenticated, lightweight)
        {HealthUs, {ok, _}} = timer:tc(fun() ->
            nova_test:get("/health", Config)
        end),
        T7 = T6#{health => HealthUs},

        {ok, T7}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, hd(Stack)}}
    end.

%% --- Collection ---

collect(_Ref, 0, Acc) ->
    Acc;
collect(Ref, Remaining, Acc) ->
    receive
        {Ref, Result} -> collect(Ref, Remaining - 1, [Result | Acc])
    after 120_000 ->
        ct:pal("  TIMEOUT: ~p workers did not respond", [Remaining]),
        Acc
    end.

%% --- Reporting ---

print_phase_report(Timings) when Timings =:= [] ->
    ct:pal("  No successful timings to report.");
print_phase_report(Timings) ->
    Phases = [register, login, list_matches, list_friends, wallets, profile, health],
    ct:pal("~n  Phase           p50       p95       p99       min       max"),
    ct:pal("  ---------------------------------------------------------------"),
    lists:foreach(
        fun(Phase) ->
            Values = [maps:get(Phase, T) || T <- Timings],
            print_phase_line(Phase, Values)
        end,
        Phases
    ),

    Totals = [lists:sum(maps:values(T)) || T <- Timings],
    print_phase_line(total, Totals).

print_phase_line(Phase, Values) ->
    Sorted = lists:sort(Values),
    Len = length(Sorted),
    P50 = percentile(Sorted, Len, 50),
    P95 = percentile(Sorted, Len, 95),
    P99 = percentile(Sorted, Len, 99),
    Min =
        case hd(Sorted) of
            MN when is_number(MN) -> MN
        end,
    Max =
        case lists:last(Sorted) of
            MX when is_number(MX) -> MX
        end,
    ct:pal("  ~-15s ~7.1fms ~7.1fms ~7.1fms ~7.1fms ~7.1fms", [
        atom_to_list(Phase),
        P50 / 1000,
        P95 / 1000,
        P99 / 1000,
        Min / 1000,
        Max / 1000
    ]).

percentile(Sorted, Len, P) ->
    Idx = max(1, min(Len, ceil(Len * P / 100))),
    case Idx of
        I when is_integer(I) -> lists:nth(I, Sorted)
    end.
