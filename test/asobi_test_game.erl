-module(asobi_test_game).
-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).

-spec init(map()) -> {ok, map()}.
init(_Config) ->
    {ok, #{players => #{}, tick_count => 0}}.

-spec join(binary(), map()) -> {ok, map()}.
join(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => Players#{PlayerId => #{score => 0}}}}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => maps:remove(PlayerId, Players)}}.

-spec handle_input(binary(), map(), map()) -> {ok, map()} | {error, term()}.
handle_input(_PlayerId, #{~"action" := ~"invalid"}, _State) ->
    {error, invalid_action};
handle_input(_PlayerId, _Input, State) ->
    {ok, State}.

-spec tick(map()) -> {ok, map()}.
tick(#{tick_count := Count} = State) ->
    {ok, State#{tick_count => Count + 1}}.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{players := Players}) ->
    maps:get(PlayerId, Players, #{}).
