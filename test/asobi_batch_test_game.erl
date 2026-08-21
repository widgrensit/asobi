-module(asobi_batch_test_game).
-moduledoc """
A world game module that exports `handle_input_batch/2`, so the zone takes the
batch path. It records every call in the process dictionary of the zone that
ran it, which is how the tests prove the batch was used *instead of* the
per-input path rather than as well as it.

`~"outcomes"` in an input lets a test force the returned outcome list, including
a list of the wrong length, so the contract-violation branch is reachable.
""".
-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, handle_input_batch/2, post_tick/2]).
-export([calls/1]).

-define(CALLS, {?MODULE, calls}).

-spec init(map()) -> {ok, map()}.
init(_Config) -> {ok, #{}}.

-spec join(binary(), map()) -> {ok, map()}.
join(_PlayerId, State) -> {ok, State}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(_PlayerId, State) -> {ok, State}.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(_PlayerId, _State) -> {ok, {0.0, 0.0}}.

-spec zone_tick(map(), term()) -> {map(), term()}.
zone_tick(Entities, ZoneState) -> {Entities, ZoneState}.

-doc "Never reached while handle_input_batch/2 is exported; records it if it is.".
-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(_PlayerId, _Input, Entities) ->
    record(single),
    {ok, Entities}.

-spec handle_input_batch([{binary(), map()}], map()) ->
    {ok, map(), [asobi_world:input_outcome()]}.
handle_input_batch(Inputs, Entities) ->
    record({batch, length(Inputs)}),
    {Entities1, Outcomes} = apply_each(Inputs, Entities, []),
    case forced_return(Inputs) of
        {return, Forced} -> Forced;
        {outcomes, Forced} -> {ok, Entities1, Forced};
        none -> {ok, Entities1, Outcomes}
    end.

%% `~"return"` replaces the whole return value, so the non-conforming arm is
%% reachable; `~"outcomes"` replaces only the outcome list, so the wrong-length
%% and improper-list arms are. Inputs are applied either way, which is what lets
%% a test tell "kept the module's entities" from "kept the zone's".
forced_return([]) ->
    none;
forced_return([{_PlayerId, #{~"return" := Forced}} | _]) ->
    {return, Forced};
forced_return([{_PlayerId, #{~"outcomes" := Forced}} | _]) ->
    {outcomes, Forced};
forced_return([_ | Rest]) ->
    forced_return(Rest).

apply_each([], Entities, Acc) ->
    {Entities, lists:reverse(Acc)};
apply_each([{PlayerId, Input} | Rest], Entities, Acc) ->
    case Input of
        #{~"action" := ~"move", ~"x" := X, ~"y" := Y} ->
            case maps:get(PlayerId, Entities, undefined) of
                undefined ->
                    apply_each(Rest, Entities, [{error, not_found} | Acc]);
                Entity ->
                    apply_each(Rest, Entities#{PlayerId => Entity#{x => X, y => Y}}, [ok | Acc])
            end;
        #{~"action" := ~"consume", ~"consumed" := Consumed} ->
            apply_each(Rest, Entities, [{consumed, Consumed} | Acc]);
        #{~"action" := ~"bad_outcome"} ->
            apply_each(Rest, Entities, [not_an_outcome | Acc]);
        #{~"action" := ~"reject"} ->
            apply_each(Rest, Entities, [{error, {out_of_range, 5}} | Acc]);
        _ ->
            apply_each(Rest, Entities, [ok | Acc])
    end.

-spec post_tick(non_neg_integer(), map()) -> {ok, map()}.
post_tick(_TickN, State) -> {ok, State}.

record(What) ->
    Prev =
        case erlang:get(?CALLS) of
            L when is_list(L) -> L;
            _ -> []
        end,
    erlang:put(?CALLS, [What | Prev]).

-doc "The calls this game module saw, oldest first, read from the zone process.".
-spec calls(pid()) -> [term()].
calls(Pid) ->
    case erlang:process_info(Pid, {dictionary, ?CALLS}) of
        {{dictionary, ?CALLS}, L} when is_list(L) -> lists:reverse(L);
        _ -> []
    end.
