-module(asobi_zone_border).
-moduledoc """
A read-only mirror of each zone's edge band, so a zone can see what its
neighbours own near their shared seam.

`asobi_spatial`'s zone-based queries search the calling zone's own entity map
and nothing else, which makes anything just past a boundary permanently
invisible rather than invisible for the tick it takes to cross
(`guides/world-server.md`). An NPC parked one unit before a seam never sees the
pilot two units past it, and a projectile resolved in the shooter's zone can
never hit a target the neighbour owns.

Every zone publishes the entities inside `border_band` of its own rectangle
here once per tick, keyed by its coords. Neighbouring zones read the eight
touching rows. What comes back is a **copy**: ownership never moves, and
writing to what you read changes nothing.

Writing to the *table*, however, changes `owner/4`'s answer, which is the
sender-side half of `game.zone.apply`'s authorisation. The half that cannot be
forged is the receiver's: `asobi_zone` applies an effect only to an entity it
currently owns, so a forged row buys the ability to *address* an entity, never
the ability to invent one. See `asobi_world_sup` for the trust model this sits
inside.

The band is bounded by the zone's perimeter rather than its area, which is what
keeps this from being "every zone holds every neighbour's entity map". Set
`border_band` to `0` to publish nothing.

**One table per world, owned by that world's `asobi_world_instance`
supervisor.** Nothing here has to be swept: no asobi process traps exits, so
`terminate/2` does not run on a supervisor shutdown, and any cleanup hung off
it would leak a whole grid of rows every time a world ended. Tying the table's
lifetime to the world's own supervisor makes teardown exact rather than
best-effort, and makes one world's rows unreachable from another by
construction rather than by a key convention.
""".

-export([new/0]).
-export([write_band/3, clear/2]).
-export([neighbours/2, band_entities/4]).
-export([query_radius/5, query_radius/6, query_rect/5, query_rect/6]).
-export([owner/4]).

-type coords() :: {integer(), integer()}.
-type tab() :: ets:table() | undefined.

-export_type([tab/0]).

-doc """
A world's mirror. Call from the process that should own it - the world's
instance supervisor - so it dies exactly when the world does.
""".
-spec new() -> ets:table().
new() ->
    %% Both concurrency options, deliberately: every zone writes its own row
    %% each tick while its neighbours read theirs, so the table is hot from both
    %% sides at once.
    ets:new(asobi_zone_border, [
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]).

-doc """
Write a band this zone has already computed.

`asobi_zone` computes the band itself rather than handing the whole entity map
over, so it can tell an empty band from an absent row and skip the write
entirely: on a grid where most zones are empty most of the time, re-deleting a
row that is not there is the whole per-tick cost of this feature.
""".
-spec write_band(tab(), coords(), map()) -> ok.
write_band(undefined, _Coords, _Entities) ->
    ok;
write_band(Tab, Coords, Entities) ->
    true = ets:insert(Tab, {Coords, Entities}),
    ok.

-doc "Drop this zone's row, if it has one.".
-spec clear(tab(), coords()) -> ok.
clear(undefined, _Coords) ->
    ok;
clear(Tab, Coords) ->
    true = ets:delete(Tab, Coords),
    ok.

-doc "The entities of `Entities` lying within `Band` of any edge of this zone.".
-spec band_entities(coords(), pos_integer(), number(), map()) -> map().
band_entities({ZX, ZY}, ZoneSize, Band, Entities) ->
    XLo = ZX * ZoneSize,
    YLo = ZY * ZoneSize,
    maps:filter(
        fun(Id, Entity) ->
            is_binary(Id) andalso is_map(Entity) andalso
                in_band(pos(Entity), XLo, YLo, ZoneSize, Band)
        end,
        Entities
    ).

-doc "The up-to-eight in-grid coords touching `Coords`.".
-spec neighbours(coords(), pos_integer()) -> [coords()].
neighbours({ZX, ZY}, GridSize) ->
    [
        {X, Y}
     || DX <- [-1, 0, 1],
        DY <- [-1, 0, 1],
        {DX, DY} =/= {0, 0},
        X <- [ZX + DX],
        Y <- [ZY + DY],
        X >= 0,
        Y >= 0,
        X < GridSize,
        Y < GridSize
    ].

-doc """
Radius query over the eight zones touching `Coords`, never over `Coords`
itself - the caller already holds its own entity map, and searching both here
would return every in-zone entity twice.
""".
-spec query_radius(tab(), coords(), pos_integer(), {number(), number()}, number()) ->
    [{binary(), map(), float()}].
query_radius(Tab, Coords, GridSize, Center, Radius) ->
    query_radius(Tab, Coords, GridSize, Center, Radius, #{}).

-spec query_radius(
    tab(), coords(), pos_integer(), {number(), number()}, number(), asobi_spatial:query_opts()
) -> [{binary(), map(), float()}].
query_radius(Tab, Coords, GridSize, Center, Radius, Opts) ->
    asobi_spatial:query_radius(neighbour_entities(Tab, Coords, GridSize), Center, Radius, Opts).

-spec query_rect(tab(), coords(), pos_integer(), {number(), number()}, {number(), number()}) ->
    [{binary(), map()}].
query_rect(Tab, Coords, GridSize, TopLeft, BottomRight) ->
    query_rect(Tab, Coords, GridSize, TopLeft, BottomRight, #{}).

-spec query_rect(
    tab(),
    coords(),
    pos_integer(),
    {number(), number()},
    {number(), number()},
    asobi_spatial:query_opts()
) -> [{binary(), map()}].
query_rect(Tab, Coords, GridSize, TopLeft, BottomRight, Opts) ->
    asobi_spatial:query_rect(
        neighbour_entities(Tab, Coords, GridSize), TopLeft, BottomRight, Opts
    ).

-doc """
Which neighbour of `Coords` currently publishes `EntityId`.

This is the sender-side authorisation gate for `game.zone.apply` as much as it
is a lookup: a zone can only address an entity it can already see, so "what may
I affect" and "what may I read" are the same set rather than two that can drift
apart.
""".
-spec owner(tab(), coords(), pos_integer(), binary()) -> {ok, coords()} | error.
owner(undefined, _Coords, _GridSize, _EntityId) ->
    error;
owner(Tab, Coords, GridSize, EntityId) when is_binary(EntityId) ->
    find_owner(neighbours(Coords, GridSize), Tab, EntityId);
owner(_Tab, _Coords, _GridSize, _EntityId) ->
    error.

%% --- Internal ---

find_owner([], _Tab, _EntityId) ->
    error;
find_owner([Coords | Rest], Tab, EntityId) ->
    case publishes(Tab, Coords, EntityId) of
        true -> {ok, Coords};
        false -> find_owner(Rest, Tab, EntityId)
    end.

%% A map pattern matches a map *containing* the key, so this answers membership
%% inside ETS. `ets:lookup/2` would copy the neighbour's whole band out to the
%% caller's heap to run one `maps:is_key/2` on it and throw the rest away -
%% measured 4.6x slower at a 60-entity band, and unlike this it gets worse as
%% the band grows.
publishes(Tab, Coords, EntityId) ->
    ets:select_count(Tab, [{{Coords, #{EntityId => '_'}}, [], [true]}]) > 0.

neighbour_entities(undefined, _Coords, _GridSize) ->
    #{};
neighbour_entities(Tab, Coords, GridSize) ->
    merge_rows(neighbours(Coords, GridSize), Tab, #{}).

merge_rows([], _Tab, Acc) ->
    Acc;
merge_rows([Coords | Rest], Tab, Acc) ->
    merge_rows(Rest, Tab, maps:merge(Acc, row(Tab, Coords))).

row(Tab, Coords) ->
    case ets:lookup(Tab, Coords) of
        [{_, Entities}] when is_map(Entities) -> Entities;
        _ -> #{}
    end.

in_band(undefined, _XLo, _YLo, _ZoneSize, _Band) ->
    false;
in_band({X, Y}, XLo, YLo, ZoneSize, Band) ->
    X - XLo < Band orelse
        XLo + ZoneSize - X < Band orelse
        Y - YLo < Band orelse
        YLo + ZoneSize - Y < Band.

%% Entity maps are game-supplied and reach the zone with either atom keys (an
%% Erlang game module) or binary ones (the Lua bridge), so both shapes have to
%% be read here for the same reason asobi_zone:entity_pos/1 reads both.
pos(#{x := X, y := Y}) when is_number(X), is_number(Y) -> {X, Y};
pos(#{~"x" := X, ~"y" := Y}) when is_number(X), is_number(Y) -> {X, Y};
pos(_) -> undefined.
