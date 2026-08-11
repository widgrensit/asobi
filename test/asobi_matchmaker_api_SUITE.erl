-module(asobi_matchmaker_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    add_ticket/1,
    add_ticket_reports_already_queued/1,
    add_ticket_omitted_mode_rejected/1,
    get_ticket/1,
    get_ticket_not_found/1,
    cancel_ticket/1,
    supplied_party_is_not_accepted/1,
    other_player_cannot_read_ticket/1,
    other_player_cannot_cancel_ticket/1
]).

all() ->
    [
        add_ticket,
        add_ticket_reports_already_queued,
        add_ticket_omitted_mode_rejected,
        get_ticket,
        get_ticket_not_found,
        cancel_ticket,
        supplied_party_is_not_accepted,
        other_player_cannot_read_ticket,
        other_player_cannot_cancel_ticket
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    %% The matchmaker edge now rejects unknown modes, so register the modes these
    %% tests submit. Merge into (and later restore) any existing game_modes.
    PrevModes = application:get_env(asobi, game_modes),
    Existing =
        case PrevModes of
            {ok, M} when is_map(M) -> M;
            _ -> #{}
        end,
    %% add_ticket_omitted_mode_rejected depends on "default" being absent -
    %% remove it explicitly rather than relying on Existing not having it.
    %% known_mode/1 now requires a resolvable module (not just a game_modes
    %% key), so these need a `module` entry - the tests never let a match
    %% actually spawn, so any atom clears the known_mode gate.
    application:set_env(
        asobi,
        game_modes,
        (maps:remove(~"default", Existing))#{
            ~"ranked" => #{module => asobi_matchmaker_api_suite_test_mod},
            ~"casual" => #{module => asobi_matchmaker_api_suite_test_mod}
        }
    ),
    U1 = asobi_test_helpers:unique_username(~"mm_api1"),
    U2 = asobi_test_helpers:unique_username(~"mm_api2"),
    {ok, R1} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U2, ~"password" => ~"testpass123"}},
        Config0
    ),
    #{~"player_id" := P1Id, ~"access_token" := P1Token} = nova_test:json(R1),
    #{~"access_token" := P2Token} = nova_test:json(R2),
    [
        {player1_id, P1Id},
        {player1_token, P1Token},
        {player2_token, P2Token},
        {prev_game_modes, PrevModes}
        | Config0
    ].

end_per_suite(Config) ->
    case lists:keyfind(prev_game_modes, 1, Config) of
        {prev_game_modes, {ok, V}} -> application:set_env(asobi, game_modes, V);
        {prev_game_modes, undefined} -> application:unset_env(asobi, game_modes);
        false -> ok
    end,
    Config.

auth(Config) ->
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

auth2(Config) ->
    {player2_token, Token} = lists:keyfind(player2_token, 1, Config),
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

%% The reply metadata has to survive the controller's JSON projection, not just
%% asobi_matchmaker:add/2's return map - and `already_queued' has to encode as a
%% JSON boolean rather than a string. Asserted at the edge a client actually
%% talks to.
add_ticket_reports_already_queued(Config) ->
    Post = fun() ->
        {ok, Resp} = nova_test:post(
            "/api/v1/matchmaker",
            #{headers => auth(Config), json => #{~"mode" => ~"ranked"}},
            Config
        ),
        ?assertStatus(200, Resp),
        nova_test:json(Resp)
    end,
    Body1 = Post(),
    ?assertMatch(#{~"already_queued" := false}, Body1),
    Body2 = Post(),
    ?assertMatch(#{~"already_queued" := true}, Body2),
    #{~"ticket_id" := TicketId} = Body1,
    ?assertEqual(TicketId, maps:get(~"ticket_id", Body2)),
    _ = nova_test:delete(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    Config.

%% asobi#243 incident: a request with no `mode' field defaults to "default"
%% (asobi_matchmaker_controller:add/1), which used to be unconditionally
%% accepted by known_mode/1 even though this suite's game_modes never maps
%% "default" - the ticket queued, then failed later with no_game_module
%% instead of an immediate, actionable 400 here.
add_ticket_omitted_mode_rejected(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/matchmaker",
        #{
            headers => auth(Config),
            json => #{~"properties" => #{~"skill" => 1200}}
        },
        Config
    ),
    ?assertStatus(400, Resp),
    ?assertMatch(
        #{~"error" := #{~"code" := ~"matchmaker.unknown_mode"}}, nova_test:json(Resp)
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

%% asobi never supported grouping by a client-supplied party list: the field
%% was accepted, sanitised and echoed while nothing downstream read it. It is
%% gone now, and this pins that a supplied `party` is ignored outright rather
%% than silently accepted - accept-and-do-nothing is worse than rejecting.
supplied_party_is_not_accepted(Config) ->
    {ok, AddResp} = nova_test:post(
        "/api/v1/matchmaker",
        #{
            headers => auth(Config),
            json => #{
                ~"mode" => ~"ranked",
                ~"party" => [~"someone-else", ~"00000000-0000-0000-0000-000000000001"]
            }
        },
        Config
    ),
    #{~"ticket_id" := TicketId} = nova_test:json(AddResp),
    true = is_binary(TicketId),
    {ok, GetResp} = nova_test:get(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    Body = nova_test:json(GetResp),
    ?assertNot(
        maps:is_key(~"party", Body),
        "a supplied party must not be echoed back as if it did something"
    ),
    _ = nova_test:delete(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    Config.

%% F-8 regression: another player cannot read someone else's ticket.
other_player_cannot_read_ticket(Config) ->
    {ok, AddResp} = nova_test:post(
        "/api/v1/matchmaker",
        #{headers => auth(Config), json => #{~"mode" => ~"casual"}},
        Config
    ),
    #{~"ticket_id" := TicketId} = nova_test:json(AddResp),
    true = is_binary(TicketId),
    {ok, ForbiddenResp} = nova_test:get(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth2(Config)},
        Config
    ),
    ?assertStatus(403, ForbiddenResp),
    _ = nova_test:delete(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    Config.

%% F-8 regression: another player cannot cancel someone else's ticket.
other_player_cannot_cancel_ticket(Config) ->
    {ok, AddResp} = nova_test:post(
        "/api/v1/matchmaker",
        #{headers => auth(Config), json => #{~"mode" => ~"casual"}},
        Config
    ),
    #{~"ticket_id" := TicketId} = nova_test:json(AddResp),
    true = is_binary(TicketId),
    {ok, ForbiddenResp} = nova_test:delete(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth2(Config)},
        Config
    ),
    ?assertStatus(403, ForbiddenResp),
    %% The owner can still see / cancel it.
    {ok, GetResp} = nova_test:get(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, GetResp),
    _ = nova_test:delete(
        "/api/v1/matchmaker/" ++ binary_to_list(TicketId),
        #{headers => auth(Config)},
        Config
    ),
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
