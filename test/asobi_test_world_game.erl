-module(asobi_test_world_game).
-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2]).
-export([get_state/2]).

-spec init(map()) -> {ok, map()}.
init(Config) ->
    {ok, #{
        players => #{},
        tick_count => 0,
        finish_at => maps:get(finish_at, Config, undefined)
    }}.

-spec join(binary(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => Players#{PlayerId => #{score => 0}}}}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => maps:remove(PlayerId, Players)}}.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(_PlayerId, _State) ->
    {ok, {100.0, 100.0}}.

-spec zone_tick(map(), term()) -> {map(), term()}.
zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

-spec handle_input(binary(), map(), map()) -> {ok, map()} | {error, term()}.
handle_input(PlayerId, #{~"action" := ~"move", ~"x" := X, ~"y" := Y}, Entities) ->
    case maps:find(PlayerId, Entities) of
        {ok, Entity} ->
            {ok, Entities#{PlayerId => Entity#{x => X, y => Y}}};
        error ->
            {error, not_found}
    end;
handle_input(_PlayerId, #{~"action" := ~"invalid"}, _Entities) ->
    {error, invalid_action};
handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.

-spec post_tick(non_neg_integer(), map()) ->
    {ok, map()} | {finished, map(), map()}.
post_tick(TickN, #{finish_at := FinishAt} = State) when
    is_integer(FinishAt), TickN >= FinishAt
->
    {finished, #{reason => ~"time_up"}, State#{tick_count => TickN}};
post_tick(TickN, State) ->
    {ok, State#{tick_count => TickN}}.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{players := Players}) ->
    maps:get(PlayerId, Players, #{}).
