-module(asobi_bot_input_game).
-behaviour(asobi_match).

%% Records every input the match server accepts into a public ETS table so a
%% test can read what a bot actually sent, tick by tick.

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).
-export([log/0, inputs/0]).

-define(LOG, asobi_bot_input_log).

-spec log() -> ets:table().
log() ->
    case ets:whereis(?LOG) of
        undefined -> ets:new(?LOG, [named_table, public, ordered_set]);
        Tid -> Tid
    end.

-spec inputs() -> [map()].
inputs() ->
    [Input || {_Seq, Input} <- ets:tab2list(?LOG), is_map(Input)].

-spec init(map()) -> {ok, map()}.
init(_Config) ->
    {ok, #{players => #{}, tick_count => 0}}.

-spec join(binary(), map()) -> {ok, map()}.
join(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => Players#{PlayerId => #{}}}}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{players := Players} = State) ->
    {ok, State#{players => maps:remove(PlayerId, Players)}}.

-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(_PlayerId, Input, State) ->
    true = ets:insert(?LOG, {erlang:unique_integer([monotonic]), Input}),
    {ok, State}.

-spec tick(map()) -> {ok, map()}.
tick(#{tick_count := Count} = State) ->
    {ok, State#{tick_count => Count + 1}}.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{players := Players}) ->
    maps:get(PlayerId, Players, #{}).
