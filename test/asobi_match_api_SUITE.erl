-module(asobi_match_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    list_matches_empty/1,
    list_matches_with_records/1,
    list_matches_filter_mode/1,
    show_match/1,
    show_match_not_found/1,
    live_matches_filter_joinable/1
]).

all() -> [{group, match_api}].

groups() ->
    [
        {match_api, [sequence], [
            list_matches_empty,
            list_matches_with_records,
            list_matches_filter_mode,
            show_match,
            show_match_not_found,
            live_matches_filter_joinable
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"match_api"),
    {ok, R1} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    #{~"access_token" := Token, ~"player_id" := PlayerId} = nova_test:json(R1),
    Record1CS = kura_changeset:cast(
        asobi_match_record,
        #{},
        #{
            mode => ~"arena",
            status => ~"finished",
            players => [PlayerId],
            result => #{winner => PlayerId},
            started_at => calendar:universal_time(),
            finished_at => calendar:universal_time()
        },
        [mode, status, players, result, started_at, finished_at]
    ),
    {ok, Record1} = asobi_repo:insert(Record1CS),
    Record2CS = kura_changeset:cast(
        asobi_match_record,
        #{},
        #{
            mode => ~"deathmatch",
            status => ~"finished",
            players => [PlayerId],
            result => #{},
            started_at => calendar:universal_time(),
            finished_at => calendar:universal_time()
        },
        [mode, status, players, result, started_at, finished_at]
    ),
    {ok, _Record2} = asobi_repo:insert(Record2CS),
    [
        {player1_id, PlayerId},
        {player1_token, Token},
        {match_id, maps:get(id, Record1)}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config) ->
    {player1_token, Token} = lists:keyfind(player1_token, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

list_matches_empty(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/matches?mode=nonexistent_mode",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"matches" := []}, Resp),
    Config.

list_matches_with_records(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/matches",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"matches" := Matches} = nova_test:json(Resp),
    true = is_list(Matches),
    ?assert(length(Matches) >= 2),
    Config.

list_matches_filter_mode(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/matches?mode=arena",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"matches" := Matches} = nova_test:json(Resp),
    true = is_list(Matches),
    ?assert(length(Matches) >= 1),
    Config.

show_match(Config) ->
    {match_id, MatchId} = lists:keyfind(match_id, 1, Config),
    true = is_binary(MatchId),
    {ok, Resp} = nova_test:get(
        "/api/v1/matches/" ++ binary_to_list(MatchId),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"id" := MatchId, ~"mode" := ~"arena"}, Body),
    Config.

show_match_not_found(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/matches/00000000-0000-0000-0000-000000000000",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

%% `/matches/live` reads live processes, not the record table the rest of this
%% suite uses. A closed match must drop out of `joinable=true` and be the only
%% thing left under `joinable=false`, so a lobby browser can tell "join this"
%% from "watch this".
live_matches_filter_joinable(Config) ->
    Open = start_listed_match(~"live_open"),
    Closed = start_listed_match(~"live_closed"),
    ok = asobi_match_server:set_joinable(Closed, false),
    timer:sleep(50),
    try
        ?assertEqual([~"live_open"], live_modes("?joinable=true", Config)),
        ?assertEqual([~"live_closed"], live_modes("?joinable=false", Config)),
        ?assertEqual(
            [~"live_closed", ~"live_open"], lists:sort(live_modes("", Config))
        ),
        ?assertMatch([#{~"joinable" := true}], live_entries("?mode=live_open", Config))
    after
        stop_match(Open),
        stop_match(Closed)
    end,
    Config.

start_listed_match(Mode) ->
    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        mode => Mode,
        listed => true,
        min_players => 2,
        max_players => 4,
        tick_rate => 50
    }),
    Pid.

%% `shutdown`, not `kill`: these are transient children of asobi_match_sup, so
%% an abnormal exit is restarted and the replacement match ticks on into
%% whichever suite runs next.
stop_match(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> ok
    end.

%% The listing cache is keyed on the filters and lives 500ms, so a query made
%% right after set_joinable could otherwise read a pre-close listing.
live_entries(Query, Config) ->
    timer:sleep(600),
    {ok, Resp} = nova_test:get(
        "/api/v1/matches/live" ++ Query, #{headers => auth(Config)}, Config
    ),
    ?assertStatus(200, Resp),
    #{~"matches" := Matches} = nova_test:json(Resp),
    [M || M <- Matches, lists:member(maps:get(~"mode", M, undefined), modes_under_test())].

live_modes(Query, Config) ->
    [maps:get(~"mode", M) || M <- live_entries(Query, Config)].

modes_under_test() ->
    [~"live_open", ~"live_closed"].
