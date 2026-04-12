-module(asobi_spatial).

%% Spatial query primitives for zone entities.
%% Pure functional — no process, no state. Operates on entity maps.

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
        fun
            (Id, #{x := X, y := Y} = Entity, Acc) ->
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
            (_Id, _Entity, Acc) ->
                Acc
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
        fun
            (Id, #{x := X, y := Y} = Entity, Acc) ->
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
            (_Id, _Entity, Acc) ->
                Acc
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
    Sorted = lists:sort(fun({D1, _, _}, {D2, _, _}) -> D1 =< D2 end, All),
    format_nearest(lists:sublist(Sorted, N), []).

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
collect_with_distance([{Id, #{x := X, y := Y} = Entity} | Rest], CX, CY, TF, Excl, CF, Acc) ->
    case TF(Entity) andalso not maps:is_key(Id, Excl) andalso CF(Id, Entity) of
        true ->
            D2 = (X - CX) * (X - CX) + (Y - CY) * (Y - CY),
            collect_with_distance(Rest, CX, CY, TF, Excl, CF, [{D2, Id, Entity} | Acc]);
        false ->
            collect_with_distance(Rest, CX, CY, TF, Excl, CF, Acc)
    end;
collect_with_distance([_ | Rest], CX, CY, TF, Excl, CF, Acc) ->
    collect_with_distance(Rest, CX, CY, TF, Excl, CF, Acc).

-spec format_nearest([{float(), binary(), map()}], [{binary(), map(), float()}]) ->
    [{binary(), map(), float()}].
format_nearest([], Acc) ->
    lists:reverse(Acc);
format_nearest([{D2, Id, E} | Rest], Acc) ->
    format_nearest(Rest, [{Id, E, math:sqrt(D2)} | Acc]).

%% -------------------------------------------------------------------
%% Point utilities
%% -------------------------------------------------------------------

-spec in_range(map(), map(), number()) -> boolean().
in_range(#{x := X1, y := Y1}, #{x := X2, y := Y2}, Range) ->
    DX = X2 - X1,
    DY = Y2 - Y1,
    DX * DX + DY * DY =< Range * Range.

-spec distance(map(), map()) -> float().
distance(#{x := X1, y := Y1}, #{x := X2, y := Y2}) ->
    distance_pos({X1, Y1}, {X2, Y2}).

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
    fun
        (#{type := T}) -> maps:is_key(T, Set);
        (_) -> false
    end;
type_filter(#{type := Type}) ->
    fun
        (#{type := T}) -> T =:= Type;
        (_) -> false
    end;
type_filter(_) ->
    fun(_) -> true end.

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
