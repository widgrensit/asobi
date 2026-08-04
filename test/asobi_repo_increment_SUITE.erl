-module(asobi_repo_increment_SUITE).

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([accumulates_rather_than_overwrites/1, creates_the_row_when_it_is_missing/1]).

%% asobi#362: an extension counter needs SET c = c + EXCLUDED.c, which neither
%% update_all/2 nor kura's on_conflict expresses. The statement and its uuid
%% parameter only get exercised against a real Postgres here.

all() -> [accumulates_rather_than_overwrites, creates_the_row_when_it_is_missing].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    [{player_id, register_player(Config0)} | Config0].

end_per_suite(Config) ->
    Config.

register_player(Config) ->
    Username = asobi_test_helpers:unique_username(~"increment"),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId} = nova_test:json(Resp),
    PlayerId.

player_id(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    PlayerId.

increment(PlayerId, Deltas) ->
    asobi_repo:increment(asobi_player_stats, #{player_id => PlayerId}, Deltas).

accumulates_rather_than_overwrites(Config) ->
    PlayerId = player_id(Config),
    ?assertMatch({ok, _}, asobi_repo:get(asobi_player_stats, PlayerId)),

    {ok, First} = increment(PlayerId, #{games_played => 1, wins => 1}),
    ?assertMatch(#{games_played := 1, wins := 1}, First),

    %% An overwrite would leave games_played at 2. Accumulation makes it 3.
    {ok, Second} = increment(PlayerId, #{games_played => 2, losses => 1}),
    ?assertMatch(#{games_played := 3, wins := 1, losses := 1}, Second),

    ?assertMatch(
        #{games_played := 3, wins := 1, losses := 1},
        element(2, asobi_repo:get(asobi_player_stats, PlayerId))
    ),
    Config.

%% The insert half. An extension's progress row does not exist until the first
%% event, and needing a separate insert-then-retry is the race the primitive
%% exists to remove.
creates_the_row_when_it_is_missing(Config) ->
    PlayerId = player_id(Config),
    {ok, Row} = asobi_repo:get(asobi_player_stats, PlayerId),
    {ok, _} = asobi_repo:delete(asobi_player_stats, Row),
    ?assertMatch({error, _}, asobi_repo:get(asobi_player_stats, PlayerId)),

    {ok, Created} = increment(PlayerId, #{games_played => 5}),
    ?assertMatch(#{games_played := 5, wins := 0}, Created),
    Config.
