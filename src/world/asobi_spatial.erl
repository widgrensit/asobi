-module(asobi_spatial).
-moduledoc """
Spatial query primitives over zone entities: radius and rectangle queries,
nearest-neighbour, range and distance helpers. Pure functional - no
process, no state - operating on entity maps, so `asobi_zone` and game code
can call it directly.
""".

-export([query_radius/3, query_radius/4]).
-export([query_rect/3, query_rect/4]).
-export([nearest/3, nearest/4]).
-export([in_range/3, distance/2, distance_pos/2]).

-export_type([query_opts/0]).

-type query_opts() :: #{
    type => binary() | [binary()],
    exclude => binary() | [binary()],
    max_results => pos_integer(),
    sort => nearest | farthest | none,
    filter => fun((binary(), map()) -> boolean())
}.

%% -------------------------------------------------------------------
%% Radius queries
%% -------------------------------------------------------------------

-spec query_radius(map(), {number(), number()}, number()) ->
    [{binary(), map(), float()}].
query_radius(Entities, Center, Radius) ->
    query_radius(Entities, Center, Radius, #{}).

-spec query_radius(map(), {number(), number()}, number(), query_opts()) ->
    [{binary(), map(), float()}].
query_radius(Entities, {CX, CY}, Radius, Opts) ->
    R2 = Radius * Radius,
    TypeFilter = type_filter(Opts),
    Exclude = exclude_set(Opts),
    CustomFilter = maps:get(filter, Opts, fun(_, _) -> true end),
    Results = maps:fold(
        fun(Id, Entity, Acc) ->
            case pos(Entity) of
                {X, Y} ->
                    D2 = (X - CX) * (X - CX) + (Y - CY) * (Y - CY),
                    case
                        D2 =< R2 andalso
                            TypeFilter(Entity) andalso
                            not maps:is_key(Id, Exclude) andalso
                            CustomFilter(Id, Entity)
                    of
                        true -> [{Id, Entity, math:sqrt(D2)} | Acc];
                        false -> Acc
                    end;
                undefined ->
                    Acc
            end
        end,
        [],
        Entities
    ),
    sort_and_limit(Results, Opts).

%% -------------------------------------------------------------------
%% Rectangle queries
%% -------------------------------------------------------------------

-spec query_rect(map(), {number(), number()}, {number(), number()}) ->
    [{binary(), map()}].
query_rect(Entities, TopLeft, BottomRight) ->
    query_rect(Entities, TopLeft, BottomRight, #{}).

-spec query_rect(map(), {number(), number()}, {number(), number()}, query_opts()) ->
    [{binary(), map()}].
query_rect(Entities, {MinX, MinY}, {MaxX, MaxY}, Opts) ->
    TypeFilter = type_filter(Opts),
    Exclude = exclude_set(Opts),
    CustomFilter = maps:get(filter, Opts, fun(_, _) -> true end),
    Results = maps:fold(
        fun(Id, Entity, Acc) ->
            case pos(Entity) of
                {X, Y} ->
                    case
                        X >= MinX andalso X =< MaxX andalso
                            Y >= MinY andalso Y =< MaxY andalso
                            TypeFilter(Entity) andalso
                            not maps:is_key(Id, Exclude) andalso
                            CustomFilter(Id, Entity)
                    of
                        true -> [{Id, Entity} | Acc];
                        false -> Acc
                    end;
                undefined ->
                    Acc
            end
        end,
        [],
        Entities
    ),
    maybe_limit(Results, Opts).

%% -------------------------------------------------------------------
%% Nearest-N queries
%% -------------------------------------------------------------------

-spec nearest(map(), {number(), number()}, pos_integer()) ->
    [{binary(), map(), float()}].
nearest(Entities, Center, N) ->
    nearest(Entities, Center, N, #{}).

-spec nearest(map(), {number(), number()}, pos_integer(), query_opts()) ->
    [{binary(), map(), float()}].
nearest(Entities, {CX, CY}, N, Opts) ->
    TypeFilter = type_filter(Opts),
    Exclude = exclude_set(Opts),
    CustomFilter = maps:get(filter, Opts, fun(_, _) -> true end),
    All = collect_with_distance(
        maps:to_list(Entities), CX, CY, TypeFilter, Exclude, CustomFilter, []
    ),
    Sorted = keysort_by_distance(All),
    format_nearest(take(Sorted, N)).

-spec keysort_by_distance([T]) -> [T] when T :: {float(), binary(), map()}.
keysort_by_distance(L) -> lists:keysort(1, L).

-spec take([T], non_neg_integer()) -> [T].
take(_, 0) -> [];
take([], _) -> [];
take([H | T], N) -> [H | take(T, N - 1)].

-spec collect_with_distance(
    [{binary(), map()}],
    number(),
    number(),
    fun((map()) -> boolean()),
    map(),
    fun((binary(), map()) -> boolean()),
    [{float(), binary(), map()}]
) -> [{float(), binary(), map()}].
collect_with_distance([], _, _, _, _, _, Acc) ->
    Acc;
collect_with_distance([{Id, Entity} | Rest], CX, CY, TF, Excl, CF, Acc) when is_map(Entity) ->
    case pos(Entity) of
        {X, Y} ->
            case TF(Entity) andalso not maps:is_key(Id, Excl) andalso CF(Id, Entity) of
                true ->
                    D2 = (X - CX) * (X - CX) + (Y - CY) * (Y - CY),
                    collect_with_distance(Rest, CX, CY, TF, Excl, CF, [{D2, Id, Entity} | Acc]);
                false ->
                    collect_with_distance(Rest, CX, CY, TF, Excl, CF, Acc)
            end;
        undefined ->
            collect_with_distance(Rest, CX, CY, TF, Excl, CF, Acc)
    end;
collect_with_distance([_ | Rest], CX, CY, TF, Excl, CF, Acc) ->
    collect_with_distance(Rest, CX, CY, TF, Excl, CF, Acc).

-spec format_nearest([{float(), binary(), map()}]) -> [{binary(), map(), float()}].
format_nearest([]) ->
    [];
format_nearest([{D2, Id, E} | Rest]) ->
    [{Id, E, math:sqrt(D2)} | format_nearest(Rest)].

%% -------------------------------------------------------------------
%% Point utilities
%% -------------------------------------------------------------------

-spec in_range(map(), map(), number()) -> boolean().
in_range(A, B, Range) ->
    {X1, Y1} = pos(A),
    {X2, Y2} = pos(B),
    DX = X2 - X1,
    DY = Y2 - Y1,
    DX * DX + DY * DY =< Range * Range.

-spec distance(map(), map()) -> float().
distance(A, B) ->
    distance_pos(pos(A), pos(B)).

-spec distance_pos({number(), number()}, {number(), number()}) -> float().
distance_pos({X1, Y1}, {X2, Y2}) ->
    DX = X2 - X1,
    DY = Y2 - Y1,
    math:sqrt(DX * DX + DY * DY).

%% -------------------------------------------------------------------
%% Internal
%% -------------------------------------------------------------------

type_filter(#{type := Types}) when is_list(Types) ->
    Set = maps:from_keys(Types, true),
    fun(E) -> maps:is_key(entity_type(E), Set) end;
type_filter(#{type := Type}) ->
    fun(E) -> entity_type(E) =:= Type end;
type_filter(_) ->
    fun(_) -> true end.

%% Entity maps are game-supplied: an Erlang game module hands them over
%% atom-keyed, the Lua bridge hands them over binary-keyed. Read both, or
%% every query silently skips every entity a Lua world owns. See
%% widgrensit/asobi#269.
-spec pos(term()) -> {number(), number()} | undefined.
pos(#{x := X, y := Y}) when is_number(X), is_number(Y) -> {X, Y};
pos(#{~"x" := X, ~"y" := Y}) when is_number(X), is_number(Y) -> {X, Y};
pos(_Entity) -> undefined.

-spec entity_type(term()) -> term().
entity_type(#{type := T}) -> T;
entity_type(#{~"type" := T}) -> T;
entity_type(_Entity) -> undefined.

exclude_set(#{exclude := Ids}) when is_list(Ids) ->
    maps:from_keys(Ids, true);
exclude_set(#{exclude := Id}) when is_binary(Id) ->
    #{Id => true};
exclude_set(_) ->
    #{}.

sort_and_limit(Results, Opts) ->
    Sorted =
        case maps:get(sort, Opts, none) of
            nearest -> lists:sort(fun({_, _, D1}, {_, _, D2}) -> D1 =< D2 end, Results);
            farthest -> lists:sort(fun({_, _, D1}, {_, _, D2}) -> D1 >= D2 end, Results);
            none -> Results
        end,
    case maps:get(max_results, Opts, infinity) of
        infinity -> Sorted;
        Max -> lists:sublist(Sorted, Max)
    end.

maybe_limit(Results, #{max_results := Max}) ->
    lists:sublist(Results, Max);
maybe_limit(Results, _) ->
    Results.
