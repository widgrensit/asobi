-module(prop_spatial_grid_consistency).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr: random sequences of insert/update/remove against asobi_spatial_grid
%% produce the same membership and the same query_radius/query_rect results
%% as a naive list-scan reference implementation.
%%
%% Catches indexing bugs (entity stuck in old cell after move, ghost entries
%% after remove, off-by-one cell edges) that are easy to introduce when the
%% grid layout changes.

-define(NUMTESTS, 50).

spatial_grid_consistency_test_() ->
    {timeout, 60,
        ?_assert(
            proper:quickcheck(prop_spatial_grid_consistency(), [
                {numtests, ?NUMTESTS}, {to_file, user}
            ])
        )}.

%% --- Property ---

prop_spatial_grid_consistency() ->
    ?FORALL(
        {CellSize, Cmds, Queries},
        {cell_size(), proper_types:list(cmd()), proper_types:list(query())},
        run_iteration(narrow_int(CellSize), narrow_list(Cmds), narrow_list(Queries))
    ).

cell_size() ->
    proper_types:elements([10, 25, 50, 100]).

cmd() ->
    proper_types:oneof([
        {insert, entity_id(), pos()},
        {update, entity_id(), pos()},
        {remove, entity_id()}
    ]).

query() ->
    proper_types:oneof([
        {radius, pos(), proper_types:integer(1, 200)},
        {rect, pos(), pos()}
    ]).

entity_id() ->
    proper_types:elements([
        ~"e1", ~"e2", ~"e3", ~"e4", ~"e5", ~"e6", ~"e7", ~"e8"
    ]).

pos() ->
    {proper_types:integer(-300, 300), proper_types:integer(-300, 300)}.

%% --- Runner ---

-spec run_iteration(pos_integer(), [term()], [term()]) -> boolean().
run_iteration(CellSize, Cmds, Queries) ->
    Grid0 = asobi_spatial_grid:new(CellSize),
    {Grid, Reference} = run_cmds(Cmds, Grid0, #{}),
    %% Membership invariant: grid entity count == reference size.
    case asobi_spatial_grid:size(Grid) =:= maps:size(Reference) of
        false ->
            io:format(
                user,
                "~nsize mismatch: grid=~p ref=~p~n",
                [asobi_spatial_grid:size(Grid), maps:size(Reference)]
            ),
            false;
        true ->
            lists:all(fun(Q) -> check_query(Q, Grid, Reference) end, Queries)
    end.

-spec run_cmds([term()], asobi_spatial_grid:grid(), #{binary() => {integer(), integer()}}) ->
    {asobi_spatial_grid:grid(), #{binary() => {integer(), integer()}}}.
run_cmds([], Grid, Ref) ->
    {Grid, Ref};
run_cmds([{insert, Id, {X, Y}} | Rest], Grid, Ref) when
    is_binary(Id), is_integer(X), is_integer(Y)
->
    Pos = {X, Y},
    case maps:is_key(Id, Ref) of
        true -> run_cmds(Rest, Grid, Ref);
        false -> run_cmds(Rest, asobi_spatial_grid:insert(Id, Pos, Grid), Ref#{Id => Pos})
    end;
run_cmds([{update, Id, {X, Y}} | Rest], Grid, Ref) when
    is_binary(Id), is_integer(X), is_integer(Y)
->
    Pos = {X, Y},
    case maps:is_key(Id, Ref) of
        true -> run_cmds(Rest, asobi_spatial_grid:update(Id, Pos, Grid), Ref#{Id => Pos});
        false -> run_cmds(Rest, Grid, Ref)
    end;
run_cmds([{remove, Id} | Rest], Grid, Ref) when is_binary(Id) ->
    case maps:is_key(Id, Ref) of
        true -> run_cmds(Rest, asobi_spatial_grid:remove(Id, Grid), maps:remove(Id, Ref));
        false -> run_cmds(Rest, Grid, Ref)
    end;
run_cmds([_ | Rest], Grid, Ref) ->
    run_cmds(Rest, Grid, Ref).

check_query({radius, Center, R}, Grid, Ref) ->
    Got = sort_results(asobi_spatial_grid:query_radius(Center, R, Grid)),
    Want = sort_results(naive_radius(Center, R, Ref)),
    case Got =:= Want of
        true ->
            true;
        false ->
            io:format(
                user,
                "~nradius mismatch ~p r=~p:~n  grid: ~p~n  ref:  ~p~n",
                [Center, R, Got, Want]
            ),
            false
    end;
check_query({rect, P1, P2}, Grid, Ref) ->
    Got = sort_results(asobi_spatial_grid:query_rect(P1, P2, Grid)),
    Want = sort_results(naive_rect(P1, P2, Ref)),
    case Got =:= Want of
        true ->
            true;
        false ->
            io:format(
                user,
                "~nrect mismatch ~p..~p:~n  grid: ~p~n  ref:  ~p~n",
                [P1, P2, Got, Want]
            ),
            false
    end.

sort_results(L) -> lists:sort(L).

naive_radius({CX, CY}, R, Ref) ->
    R2 = R * R,
    [
        {Id, Pos}
     || {Id, {X, Y} = Pos} <- maps:to_list(Ref),
        DX <- [X - CX],
        DY <- [Y - CY],
        DX * DX + DY * DY =< R2
    ].

naive_rect({X1, Y1}, {X2, Y2}, Ref) ->
    {Lx, Ux} = order(X1, X2),
    {Ly, Uy} = order(Y1, Y2),
    [
        {Id, Pos}
     || {Id, {X, Y} = Pos} <- maps:to_list(Ref),
        X >= Lx,
        X =< Ux,
        Y >= Ly,
        Y =< Uy
    ].

order(A, B) when A =< B -> {A, B};
order(A, B) -> {B, A}.

-spec narrow_int(term()) -> pos_integer().
narrow_int(N) when is_integer(N), N > 0 -> N.

-spec narrow_list(term()) -> [term()].
narrow_list(L) when is_list(L) -> L.
