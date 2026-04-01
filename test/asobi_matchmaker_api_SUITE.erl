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
        "/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    #{~"player_id" := P1Id, ~"session_token" := P1Token} = nova_test:json(R1),
    [
        {player1_id, P1Id},
        {player1_token, P1Token}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config) ->
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

add_ticket(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/matchmaker",
        #{
            headers => auth(Config),
            json => #{~"mode" => ~"ranked", ~"properties" => #{~"skill" => 1200}}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"ticket_id" := _, ~"status" := ~"pending"}, Body),
    #{~"ticket_id" := TicketId} = Body,
    true = is_binary(TicketId),
    _ = nova_test:delete(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    Config.

get_ticket(Config) ->
    {ok, AddResp} = nova_test:post(
        "/api/v1/matchmaker",
        #{
            headers => auth(Config),
            json => #{~"mode" => ~"ranked"}
        },
        Config
    ),
    #{~"ticket_id" := TicketId} = nova_test:json(AddResp),
    true = is_binary(TicketId),
    {ok, Resp} = nova_test:get(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"id" := TicketId}, Body),
    _ = nova_test:delete(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    Config.

get_ticket_not_found(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/matchmaker/nonexistent_ticket",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

cancel_ticket(Config) ->
    {ok, AddResp} = nova_test:post(
        "/api/v1/matchmaker",
        #{
            headers => auth(Config),
            json => #{~"mode" => ~"casual"}
        },
        Config
    ),
    #{~"ticket_id" := TicketId} = nova_test:json(AddResp),
    true = is_binary(TicketId),
    {ok, Resp} = nova_test:delete(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    {ok, Resp2} = nova_test:get(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(404, Resp2),
    Config.
