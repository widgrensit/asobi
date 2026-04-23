-module(hello_game).
-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).

init(_Config) ->
    {ok, #{hits => 0, players => #{}}}.

join(PlayerId, #{players := Players} = State) ->
    {ok, State#{players := Players#{PlayerId => joined}}}.

leave(PlayerId, #{players := Players} = State) ->
    {ok, State#{players := maps:remove(PlayerId, Players)}}.

handle_input(_PlayerId, #{~"action" := ~"click"}, #{hits := H} = State) ->
    NewState = State#{hits := H + 1},
    asobi_match_server:broadcast_event(self(), ~"update", #{hits => H + 1}),
    {ok, NewState};
handle_input(_PlayerId, _Input, State) ->
    {ok, State}.

tick(State) ->
    {ok, State}.

get_state(_PlayerId, #{hits := H}) ->
    #{hits => H}.
