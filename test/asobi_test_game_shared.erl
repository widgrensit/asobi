-module(asobi_test_game_shared).
-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/1]).

-spec init(map()) -> {ok, map()}.
init(_Config) ->
    {ok, #{players => #{}, tick_count => 0, world => #{npcs => 0}}}.

-spec join(binary(), map()) -> {ok, map()}.
join(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => Players#{PlayerId => #{score => 0}}}}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => maps:remove(PlayerId, Players)}}.

-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(_PlayerId, _Input, State) ->
    {ok, State}.

-spec tick(map()) -> {ok, map()}.
tick(#{tick_count := Count} = State) ->
    {ok, State#{tick_count => Count + 1}}.

-spec get_state(map()) -> map().
get_state(#{world := World, tick_count := Tc}) ->
    #{~"world" => World, ~"tick" => Tc}.
