-module(asobi_stats_test_game).
-behaviour(asobi_match).

%% Ends the match on its first tick and declares the winner it was
%% configured with, so asobi_match_stats_SUITE can assert wins/losses.

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).

-spec init(map()) -> {ok, map()}.
init(Config) ->
    {ok, #{winner => maps:get(winner, Config, undefined)}}.

-spec join(binary(), map()) -> {ok, map()}.
join(_PlayerId, State) ->
    {ok, State}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(_PlayerId, State) ->
    {ok, State}.

-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(_PlayerId, _Input, State) ->
    {ok, State}.

-spec tick(map()) -> {finished, map(), map()}.
tick(#{winner := Winner} = State) ->
    {finished, #{winner => Winner}, State}.

-spec get_state(binary(), map()) -> map().
get_state(_PlayerId, State) ->
    State.
