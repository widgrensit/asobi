-module(asobi_match_stats_SUITE).

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([finished_match_updates_participant_stats/1]).

%% asobi#329: player_stats never moved. The counters are raw SQL (kura's
%% update_all/2 can only SET literals), so the statement and its uuid
%% parameter only get exercised against a real Postgres here.

all() -> [finished_match_updates_participant_stats].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    Winner = register_player(Config0),
    Loser = register_player(Config0),
    [{winner_id, Winner}, {loser_id, Loser} | Config0].

end_per_suite(Config) ->
    Config.

register_player(Config) ->
    Username = asobi_test_helpers:unique_username(~"stats"),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId} = nova_test:json(Resp),
    PlayerId.

finished_match_updates_participant_stats(Config) ->
    {winner_id, Winner} = lists:keyfind(winner_id, 1, Config),
    {loser_id, Loser} = lists:keyfind(loser_id, 1, Config),
    ?assertMatch(#{games_played := 0, wins := 0, losses := 0}, stats(Winner)),

    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_stats_test_game,
        min_players => 2,
        max_players => 2,
        tick_rate => 20,
        game_config => #{winner => Winner}
    }),
    #{match_id := MatchId} = asobi_match_server:get_info(Pid),
    ok = asobi_match_server:join(Pid, Winner),
    ok = asobi_match_server:join(Pid, Loser),

    ok = wait_for_games_played(Winner, 1, 100),
    ?assertMatch(#{games_played := 1, wins := 1, losses := 0}, stats(Winner)),
    ?assertMatch(#{games_played := 1, wins := 0, losses := 1}, stats(Loser)),

    %% The counters ride on this insert, which used to fail its
    %% started_at/finished_at cast on every single finished match.
    {ok, Record} = asobi_repo:get(asobi_match_record, MatchId),
    ?assertMatch(#{status := ~"finished"}, Record),
    ?assertMatch({{_, _, _}, {_, _, _}}, maps:get(finished_at, Record)),
    Config.

stats(PlayerId) ->
    {ok, Row} = asobi_repo:get(asobi_player_stats, PlayerId),
    Row.

wait_for_games_played(_PlayerId, _Expected, 0) ->
    error(timeout_waiting_for_player_stats);
wait_for_games_played(PlayerId, Expected, N) ->
    case stats(PlayerId) of
        #{games_played := Expected} ->
            ok;
        _ ->
            timer:sleep(50),
            wait_for_games_played(PlayerId, Expected, N - 1)
    end.
