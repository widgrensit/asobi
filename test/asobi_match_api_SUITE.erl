-module(asobi_match_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    list_matches_empty/1,
    list_matches_with_records/1,
    list_matches_filter_mode/1,
    show_match/1,
    show_match_not_found/1
]).

all() -> [{group, match_api}].

groups() ->
    [
        {match_api, [sequence], [
            list_matches_empty,
            list_matches_with_records,
            list_matches_filter_mode,
            show_match,
            show_match_not_found
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
    #{~"session_token" := Token, ~"player_id" := PlayerId} = nova_test:json(R1),
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
