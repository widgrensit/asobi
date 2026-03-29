-module(asobi_register_bench).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([bench_registration/1]).

all() -> [bench_registration].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    nova_test:stop(Config).

bench_registration(Config) ->
    N = 5,
    ct:pal("~n=== Registration Benchmark (N=~p) ===~n", [N]),

    %% Phase 1: Password hashing alone
    ct:pal("--- Phase 1: Password hashing (PBKDF2-SHA256, 600k iterations) ---"),
    HashTimes = [
        begin
            {T, _} = timer:tc(fun() -> nova_auth_password:hash(~"benchmarkpass123") end),
            T
        end
     || _ <- lists:seq(1, N)
    ],
    print_stats(~"hash", HashTimes),

    %% Phase 2: Changeset (validation + hashing)
    ct:pal("--- Phase 2: Changeset (validation + hashing) ---"),
    CSTimes = [
        begin
            Username = iolist_to_binary([
                ~"bench_", integer_to_binary(erlang:unique_integer([positive]))
            ]),
            Params = #{
                username => Username, password => ~"benchmarkpass123", display_name => Username
            },
            {T, _} = timer:tc(fun() ->
                asobi_player:registration_changeset(#{}, Params)
            end),
            T
        end
     || _ <- lists:seq(1, N)
    ],
    print_stats(~"changeset", CSTimes),

    %% Phase 3: DB insert alone (skip hashing)
    ct:pal("--- Phase 3: DB insert (player + stats, no hashing) ---"),
    InsertTimes = [
        begin
            Username = iolist_to_binary([
                ~"dbtest_", integer_to_binary(erlang:unique_integer([positive]))
            ]),
            CS = kura_changeset:cast(
                asobi_player,
                #{},
                #{
                    username => Username,
                    hashed_password => ~"$pbkdf2-sha256$600000$fake$fake",
                    display_name => Username
                },
                [username, hashed_password, display_name]
            ),
            {T, Result} = timer:tc(fun() ->
                case asobi_repo:insert(CS) of
                    {ok, Player} ->
                        StatsCS = kura_changeset:cast(
                            asobi_player_stats,
                            #{},
                            #{
                                player_id => maps:get(id, Player)
                            },
                            [player_id]
                        ),
                        asobi_repo:insert(StatsCS);
                    Err ->
                        Err
                end
            end),
            ?assertMatch({ok, _}, Result),
            T
        end
     || _ <- lists:seq(1, N)
    ],
    print_stats(~"db_insert", InsertTimes),

    %% Phase 4: Session token generation
    ct:pal("--- Phase 4: Session token generation ---"),
    FakePlayer = #{id => asobi_id:generate()},
    TokenTimes = [
        begin
            {T, _} = timer:tc(fun() ->
                nova_auth_session:generate_session_token(asobi_auth, FakePlayer)
            end),
            T
        end
     || _ <- lists:seq(1, N)
    ],
    print_stats(~"token_gen", TokenTimes),

    %% Phase 5: Full HTTP registration
    ct:pal("--- Phase 5: Full HTTP registration ---"),
    HttpTimes = [
        begin
            Username = iolist_to_binary([
                ~"httpbench_", integer_to_binary(erlang:unique_integer([positive]))
            ]),
            {T, _} = timer:tc(fun() ->
                nova_test:post(
                    ~"/api/v1/auth/register",
                    #{json => #{~"username" => Username, ~"password" => ~"benchmarkpass123"}},
                    Config
                )
            end),
            T
        end
     || _ <- lists:seq(1, N)
    ],
    print_stats(~"http_full", HttpTimes),

    %% Summary
    ct:pal("=== Breakdown (median) ==="),
    ct:pal("  Password hash:  ~.1fms (~.0f% of total)", [
        median(HashTimes) / 1000,
        median(HashTimes) / median(HttpTimes) * 100
    ]),
    ct:pal("  DB insert:      ~.1fms (~.0f% of total)", [
        median(InsertTimes) / 1000,
        median(InsertTimes) / median(HttpTimes) * 100
    ]),
    ct:pal("  Token gen:      ~.1fms (~.0f% of total)", [
        median(TokenTimes) / 1000,
        median(TokenTimes) / median(HttpTimes) * 100
    ]),
    Overhead = median(HttpTimes) - median(HashTimes) - median(InsertTimes) - median(TokenTimes),
    ct:pal("  HTTP overhead:  ~.1fms (~.0f% of total)", [
        Overhead / 1000,
        Overhead / median(HttpTimes) * 100
    ]),
    ct:pal("  Total HTTP:     ~.1fms", [median(HttpTimes) / 1000]),
    ct:pal("  Regs/sec:       ~.1f (sequential)", [1000000 / median(HttpTimes)]),

    Config.

%% --- Internal ---

print_stats(Label, Times) ->
    Sorted = lists:sort(Times),
    Min = hd(Sorted),
    Max = lists:last(Sorted),
    Med = median(Times),
    Avg = lists:sum(Times) / length(Times),
    ct:pal("  ~ts: min=~.1fms  median=~.1fms  avg=~.1fms  max=~.1fms", [
        Label, Min / 1000, Med / 1000, Avg / 1000, Max / 1000
    ]).

median(List) ->
    Sorted = lists:sort(List),
    Len = length(Sorted),
    case Len rem 2 of
        1 ->
            lists:nth(Len div 2 + 1, Sorted);
        0 ->
            A = lists:nth(Len div 2, Sorted),
            B = lists:nth(Len div 2 + 1, Sorted),
            (A + B) / 2
    end.
