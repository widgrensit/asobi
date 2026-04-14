-module(asobi_spatial_grid).

%% Cell-based spatial index for fast entity queries within zones.
%% Pure functional — no process, no state.

-export([new/1]).
-export([insert/3, update/3, remove/2]).
-export([query_radius/3, query_rect/3]).
-export([entities_in_cell/2, size/1]).

-export_type([grid/0, cell_coords/0]).

-type cell_coords() :: {integer(), integer()}.
-type pos() :: {number(), number()}.
-type grid() :: #{
    cell_size := number(),
    cells := #{cell_coords() => #{binary() => pos()}},
    entity_cells := #{binary() => cell_coords()}
}.

%% -------------------------------------------------------------------
%% Construction
%% -------------------------------------------------------------------

-spec new(number()) -> grid().
new(CellSize) when CellSize > 0 ->
    #{
        cell_size => CellSize,
        cells => #{},
        entity_cells => #{}
    }.

%% -------------------------------------------------------------------
%% Mutations
%% -------------------------------------------------------------------

-spec insert(binary(), pos(), grid()) -> grid().
insert(EntityId, {X, Y} = Pos, #{cell_size := CS, cells := Cells, entity_cells := EC} = Grid) ->
    Cell = pos_to_cell(X, Y, CS),
    CellEntities = maps:get(Cell, Cells, #{}),
    Grid#{
        cells := Cells#{Cell => CellEntities#{EntityId => Pos}},
        entity_cells := EC#{EntityId => Cell}
    }.

-spec update(binary(), pos(), grid()) -> grid().
update(EntityId, {X, Y} = Pos, #{cell_size := CS, cells := Cells, entity_cells := EC} = Grid) ->
    NewCell = pos_to_cell(X, Y, CS),
    case maps:find(EntityId, EC) of
        {ok, NewCell} ->
            CellEntities = maps:get(NewCell, Cells, #{}),
            Grid#{cells := Cells#{NewCell => CellEntities#{EntityId => Pos}}};
        {ok, OldCell} ->
            OldCellEntities = maps:remove(EntityId, maps:get(OldCell, Cells, #{})),
            Cells1 =
                case map_size(OldCellEntities) of
                    0 -> maps:remove(OldCell, Cells);
                    _ -> Cells#{OldCell => OldCellEntities}
                end,
            NewCellEntities = maps:get(NewCell, Cells1, #{}),
            Grid#{
                cells := Cells1#{NewCell => NewCellEntities#{EntityId => Pos}},
                entity_cells := EC#{EntityId => NewCell}
            };
        error ->
            insert(EntityId, Pos, Grid)
    end.

-spec remove(binary(), grid()) -> grid().
remove(EntityId, #{cells := Cells, entity_cells := EC} = Grid) ->
    case maps:find(EntityId, EC) of
        {ok, Cell} ->
            CellEntities = maps:remove(EntityId, maps:get(Cell, Cells, #{})),
            Cells1 =
                case map_size(CellEntities) of
                    0 -> maps:remove(Cell, Cells);
                    _ -> Cells#{Cell => CellEntities}
                end,
            Grid#{
                cells := Cells1,
                entity_cells := maps:remove(EntityId, EC)
            };
        error ->
            Grid
    end.

%% -------------------------------------------------------------------
%% Queries
%% -------------------------------------------------------------------

-spec query_radius(pos(), number(), grid()) -> [{binary(), pos()}].
query_radius({CX, CY}, Radius, #{cell_size := CS, cells := Cells}) ->
    R2 = Radius * Radius,
    {MinCellX, MinCellY} = pos_to_cell(CX - Radius, CY - Radius, CS),
    {MaxCellX, MaxCellY} = pos_to_cell(CX + Radius, CY + Radius, CS),
    scan_cells(
        MinCellX,
        MinCellY,
        MaxCellX,
        MaxCellY,
        Cells,
        fun(_, {X, Y}) ->
            DX = X - CX,
            DY = Y - CY,
            DX * DX + DY * DY =< R2
        end
    ).

-spec query_rect(pos(), pos(), grid()) -> [{binary(), pos()}].
query_rect({X1, Y1}, {X2, Y2}, #{cell_size := CS, cells := Cells}) ->
    MinX = min(X1, X2),
    MinY = min(Y1, Y2),
    MaxX = max(X1, X2),
    MaxY = max(Y1, Y2),
    {MinCellX, MinCellY} = pos_to_cell(MinX, MinY, CS),
    {MaxCellX, MaxCellY} = pos_to_cell(MaxX, MaxY, CS),
    scan_cells(
        MinCellX,
        MinCellY,
        MaxCellX,
        MaxCellY,
        Cells,
        fun(_, {X, Y}) ->
            X >= MinX andalso X =< MaxX andalso Y >= MinY andalso Y =< MaxY
        end
    ).

-spec entities_in_cell(cell_coords(), grid()) -> [{binary(), pos()}].
entities_in_cell(Cell, #{cells := Cells}) ->
    maps:to_list(maps:get(Cell, Cells, #{})).

-spec size(grid()) -> non_neg_integer().
size(#{entity_cells := EC}) ->
    map_size(EC).

%% -------------------------------------------------------------------
%% Internal
%% -------------------------------------------------------------------

-spec pos_to_cell(number(), number(), number()) -> cell_coords().
pos_to_cell(X, Y, CS) ->
    {floor(X / CS), floor(Y / CS)}.

-spec scan_cells(
    integer(),
    integer(),
    integer(),
    integer(),
    #{cell_coords() => #{binary() => pos()}},
    fun((binary(), pos()) -> boolean())
) -> [{binary(), pos()}].
scan_cells(MinCX, MinCY, MaxCX, MaxCY, Cells, Filter) ->
    lists:foldl(
        fun(CellX, Acc1) ->
            lists:foldl(
                fun(CellY, Acc2) ->
                    case maps:find({CellX, CellY}, Cells) of
                        {ok, CellEntities} ->
                            maps:fold(
                                fun(Id, Pos, Acc3) ->
                                    case Filter(Id, Pos) of
                                        true -> [{Id, Pos} | Acc3];
                                        false -> Acc3
                                    end
                                end,
                                Acc2,
                                CellEntities
                            );
                        error ->
                            Acc2
                    end
                end,
                Acc1,
                lists:seq(MinCY, MaxCY)
            )
        end,
        [],
        lists:seq(MinCX, MaxCX)
    ).
