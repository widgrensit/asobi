-module(asobi_matchmaker_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    add_ticket/1,
    get_ticket/1,
    get_ticket_not_found/1,
    cancel_ticket/1
]).

all() -> [add_ticket, get_ticket, get_ticket_not_found, cancel_ticket].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"mm_api"),
    {ok, R1} = nova_test:post(
        ~"/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    [
        {player1_id, maps:get(~"player_id", B1)},
        {player1_token, maps:get(~"session_token", B1)}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config) ->
    Token = proplists:get_value(player1_token, Config),
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

add_ticket(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/matchmaker",
        #{
            headers => auth(Config),
            json => #{~"mode" => ~"ranked", ~"properties" => #{~"skill" => 1200}}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"ticket_id" := _, ~"status" := ~"pending"}, Body),
    %% Clean up
    TicketId = maps:get(~"ticket_id", Body),
    _ = nova_test:delete(
        iolist_to_binary([~"/api/v1/matchmaker/", TicketId]),
        #{headers => auth(Config)},
        Config
    ),
    Config.

get_ticket(Config) ->
    %% Create a ticket first
    {ok, AddResp} = nova_test:post(
        ~"/api/v1/matchmaker",
        #{
            headers => auth(Config),
            json => #{~"mode" => ~"ranked"}
        },
        Config
    ),
    TicketId = maps:get(~"ticket_id", nova_test:json(AddResp)),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/matchmaker/", TicketId]),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"id" := TicketId}, Body),
    %% Clean up
    _ = nova_test:delete(
        iolist_to_binary([~"/api/v1/matchmaker/", TicketId]),
        #{headers => auth(Config)},
        Config
    ),
    Config.

get_ticket_not_found(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/matchmaker/nonexistent_ticket",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

cancel_ticket(Config) ->
    %% Create a ticket first
    {ok, AddResp} = nova_test:post(
        ~"/api/v1/matchmaker",
        #{
            headers => auth(Config),
            json => #{~"mode" => ~"casual"}
        },
        Config
    ),
    TicketId = maps:get(~"ticket_id", nova_test:json(AddResp)),
    {ok, Resp} = nova_test:delete(
        iolist_to_binary([~"/api/v1/matchmaker/", TicketId]),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    %% Verify it's gone
    {ok, Resp2} = nova_test:get(
        iolist_to_binary([~"/api/v1/matchmaker/", TicketId]),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(404, Resp2),
    Config.
