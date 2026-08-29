-module(asobi_bot_input_game).
-moduledoc """
Records every input the match server accepts, so a test can read what a bot
actually sent, tick by tick.

The table is ETS rather than the process dictionary because the match server
runs in a different process from the test that reads it.
""".

-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).
-export([reset/0, inputs/0]).

-define(LOG, asobi_bot_input_log).

-spec reset() -> ok.
reset() ->
    case ets:whereis(?LOG) of
        undefined -> ets:new(?LOG, [named_table, public, ordered_set]);
        _ -> ets:delete_all_objects(?LOG)
    end,
    ok.

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
