-module(asobi_tournament_api_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    list_tournaments_empty/1,
    list_tournaments/1,
    show_tournament/1,
    show_tournament_not_found/1,
    join_tournament/1,
    join_tournament_already_joined/1,
    join_tournament_not_found/1
]).

all() -> [{group, tournament_api}].

groups() ->
    [
        {tournament_api, [sequence], [
            list_tournaments_empty, list_tournaments, show_tournament,
            show_tournament_not_found, join_tournament,
            join_tournament_already_joined, join_tournament_not_found
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"tourney_p1"),
    {ok, R1} = nova_test:post(
        ~"/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    Token = maps:get(~"session_token", B1),
    PlayerId = maps:get(~"player_id", B1),
    %% Create a tournament via DB + start it as a server
    BoardId = iolist_to_binary([~"tourney_board_", integer_to_binary(erlang:unique_integer([positive]))]),
    Now = calendar:universal_time(),
    FutureEnd = calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(Now) + 3600
    ),
    TournamentCS = asobi_tournament:changeset(#{}, #{
        name => ~"Test Tournament",
        leaderboard_id => BoardId,
        max_entries => 10,
        status => ~"pending",
        start_at => Now,
        end_at => FutureEnd,
        entry_fee => #{},
        rewards => #{}
    }),
    {ok, Tournament} = asobi_repo:insert(TournamentCS),
    TournamentId = maps:get(id, Tournament),
    %% Start the tournament server
    {ok, _} = asobi_tournament_sup:start_tournament(Tournament),
    [
        {player1_id, PlayerId},
        {player1_token, Token},
        {tournament_id, TournamentId},
        {board_id, BoardId}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config) ->
    Token = proplists:get_value(player1_token, Config),
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

list_tournaments_empty(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/tournaments?status=cancelled",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"tournaments" := []}, Resp),
    Config.

list_tournaments(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/tournaments",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"tournaments" := Tournaments} = nova_test:json(Resp),
    ?assert(length(Tournaments) >= 1),
    Config.

show_tournament(Config) ->
    TournamentId = proplists:get_value(tournament_id, Config),
    {ok, Resp} = nova_test:get(
        iolist_to_binary([~"/api/v1/tournaments/", TournamentId]),
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"id" := TournamentId, ~"name" := ~"Test Tournament"}, Body),
    Config.

show_tournament_not_found(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/tournaments/00000000-0000-0000-0000-000000000000",
        #{headers => auth(Config)},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

join_tournament(Config) ->
    TournamentId = proplists:get_value(tournament_id, Config),
    {ok, Resp} = nova_test:post(
        iolist_to_binary([~"/api/v1/tournaments/", TournamentId, ~"/join"]),
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"success" := true} = nova_test:json(Resp),
    Config.

join_tournament_already_joined(Config) ->
    TournamentId = proplists:get_value(tournament_id, Config),
    {ok, Resp} = nova_test:post(
        iolist_to_binary([~"/api/v1/tournaments/", TournamentId, ~"/join"]),
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(409, Resp),
    Config.

join_tournament_not_found(Config) ->
    {ok, Resp} = nova_test:post(
        ~"/api/v1/tournaments/00000000-0000-0000-0000-000000000000/join",
        #{headers => auth(Config), json => #{}},
        Config
    ),
    ?assertStatus(404, Resp),
    Config.
