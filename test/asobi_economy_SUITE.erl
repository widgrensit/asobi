-module(asobi_economy_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    get_wallets_empty/1,
    grant_currency/1,
    debit_currency/1,
    debit_insufficient_funds/1
]).

all() -> [{group, wallet}].

groups() ->
    [
        {wallet, [sequence], [
            get_wallets_empty, grant_currency, debit_currency, debit_insufficient_funds
        ]}
    ].

init_per_suite(Config) ->
    Config0 = nova_test:start(asobi) ++ Config,
    {ok, Resp} = nova_test:post(
        ~"/api/v1/auth/register",
        #{
            json => #{~"username" => ~"econ_test", ~"password" => ~"testpass123"}
        },
        Config0
    ),
    Body = nova_test:json(Resp),
    PlayerId = maps:get(~"player_id", Body),
    Token = maps:get(~"session_token", Body),
    [{player_id, PlayerId}, {session_token, Token} | Config0].

end_per_suite(Config) ->
    nova_test:stop(Config).

get_wallets_empty(Config) ->
    Token = proplists:get_value(session_token, Config),
    {ok, Resp} = nova_test:get(
        ~"/api/v1/wallets",
        #{headers => [{~"authorization", iolist_to_binary([~"Bearer ", Token])}]},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"wallets" := []}, Resp),
    Config.

grant_currency(Config) ->
    PlayerId = proplists:get_value(player_id, Config),
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 1000, #{reason => ~"test_grant"}),
    {ok, Wallets} = asobi_economy:get_wallets(PlayerId),
    [Wallet] = Wallets,
    ?assertEqual(1000, maps:get(balance, Wallet)),
    Config.

debit_currency(Config) ->
    PlayerId = proplists:get_value(player_id, Config),
    {ok, Wallet} = asobi_economy:debit(PlayerId, ~"gold", 300, #{reason => ~"test_debit"}),
    ?assertEqual(700, maps:get(balance, Wallet)),
    Config.

debit_insufficient_funds(Config) ->
    PlayerId = proplists:get_value(player_id, Config),
    ?assertMatch(
        {error, insufficient_funds},
        asobi_economy:debit(PlayerId, ~"gold", 9999, #{reason => ~"test_fail"})
    ),
    Config.
