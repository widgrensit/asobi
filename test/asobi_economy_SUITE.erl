-module(asobi_economy_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    get_wallets_empty/1,
    grant_currency/1,
    debit_currency/1,
    debit_insufficient_funds/1,
    get_history/1,
    concurrent_wallet_creation/1,
    concurrent_debits_no_overspend/1,
    debit_rejects_negative_amount/1
]).

all() ->
    [
        {group, wallet},
        concurrent_wallet_creation,
        concurrent_debits_no_overspend,
        debit_rejects_negative_amount
    ].

groups() ->
    [
        {wallet, [sequence], [
            get_wallets_empty, grant_currency, debit_currency, debit_insufficient_funds, get_history
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    Username = asobi_test_helpers:unique_username(~"econ"),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{
            json => #{~"username" => Username, ~"password" => ~"testpass123"}
        },
        Config0
    ),
    #{~"player_id" := PlayerId, ~"session_token" := Token} = nova_test:json(Resp),
    [{player_id, PlayerId}, {session_token, Token} | Config0].

end_per_suite(Config) ->
    Config.

get_wallets_empty(Config) ->
    {session_token, Token} = lists:keyfind(session_token, 1, Config),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/wallets",
        #{headers => [{~"authorization", <<"Bearer ", Token/binary>>}]},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"wallets" := []}, Resp),
    Config.

grant_currency(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    true = is_binary(PlayerId),
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 1000, #{reason => ~"test_grant"}),
    {ok, Wallets} = asobi_economy:get_wallets(PlayerId),
    [Wallet] = Wallets,
    ?assertEqual(1000, maps:get(balance, Wallet)),
    Config.

debit_currency(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    true = is_binary(PlayerId),
    {ok, Wallet} = asobi_economy:debit(PlayerId, ~"gold", 300, #{reason => ~"test_debit"}),
    ?assertEqual(700, maps:get(balance, Wallet)),
    Config.

debit_insufficient_funds(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    true = is_binary(PlayerId),
    ?assertMatch(
        {error, insufficient_funds},
        asobi_economy:debit(PlayerId, ~"gold", 9999, #{reason => ~"test_fail"})
    ),
    Config.

get_history(Config) ->
    {session_token, Token} = lists:keyfind(session_token, 1, Config),
    true = is_binary(Token),
    {ok, Resp} = nova_test:get(
        "/api/v1/wallets/gold/history",
        #{headers => [{~"authorization", <<"Bearer ", Token/binary>>}]},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"transactions" := History} = nova_test:json(Resp),
    true = is_list(History),
    ?assert(length(History) >= 2),
    Config.

%% F-5 regression: N parallel debits of the same wallet must never let
%% the balance go below zero (no double-spend). Without
%% pg_advisory_xact_lock around the read-check-write window, two
%% concurrent debits could both pass the `Balance >= Amount` guard.
concurrent_debits_no_overspend(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    true = is_binary(PlayerId),
    Currency = <<"f5_lock_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Start = 100,
    Price = 10,
    %% 20 concurrent debits, only 10 should succeed.
    Workers = 20,
    {ok, _} = asobi_economy:grant(PlayerId, Currency, Start, #{reason => ~"f5_test"}),
    Self = self(),
    Pids = [
        spawn(fun() ->
            Result = asobi_economy:debit(PlayerId, Currency, Price, #{reason => ~"f5_test"}),
            Self ! {result, self(), Result}
        end)
     || _ <- lists:seq(1, Workers)
    ],
    Results = [
        receive
            {result, P, R} -> R
        after 10000 -> timeout
        end
     || P <- Pids
    ],
    Successes = length([R || {ok, _} = R <- Results]),
    Insufficient = length([R || {error, insufficient_funds} = R <- Results]),
    ?assertEqual(Workers, Successes + Insufficient),
    ?assertEqual(Start div Price, Successes),
    {ok, MyWallet} = asobi_economy:get_or_create_wallet(PlayerId, Currency),
    ?assertEqual(0, maps:get(balance, MyWallet)),
    Config.

debit_rejects_negative_amount(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    true = is_binary(PlayerId),
    %% The function-head guard `Amount > 0` should fail-closed for any
    %% non-positive integer (function_clause crash on the caller side).
    ?assertError(function_clause, asobi_economy:debit(PlayerId, ~"gold", -1, #{})),
    ?assertError(function_clause, asobi_economy:debit(PlayerId, ~"gold", 0, #{})),
    ?assertError(function_clause, asobi_economy:grant(PlayerId, ~"gold", -1, #{})),
    Config.

concurrent_wallet_creation(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    true = is_binary(PlayerId),
    Currency = ~"concurrent_test",
    Self = self(),
    Pids = [
        spawn(fun() ->
            Result = asobi_economy:get_or_create_wallet(PlayerId, Currency),
            Self ! {done, self(), Result}
        end)
     || _ <- lists:seq(1, 10)
    ],
    Results = [
        receive
            {done, P, R} -> R
        after 5000 -> timeout
        end
     || P <- Pids
    ],
    lists:foreach(fun(R) -> ?assertMatch({ok, _}, R) end, Results),
    Wallets = [W || {ok, W} <- Results],
    [First | Rest] = Wallets,
    FirstId = maps:get(id, First),
    lists:foreach(
        fun(W) when is_map(W) -> ?assertEqual(FirstId, maps:get(id, W)) end,
        Rest
    ),
    Config.
