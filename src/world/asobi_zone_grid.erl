-module(asobi_zone_grid).
-moduledoc """
Shared square-ring helper for `asobi_world_server`'s interest zones and
`asobi_world_chat`'s proximity zones - both computed the exact same bounded
neighbourhood of grid coordinates around a centre, previously duplicated
verbatim in both modules. See widgrensit/asobi#248.
""".

-export([ring/3]).

-include_lib("kernel/include/logger.hrl").

-doc """
All grid coordinates within `Radius` of `{ZX, ZY}` on both axes, clamped to
`0 .. GridSize - 1`.

`{ZX, ZY}` is expected to already be a `pos_to_zone/3` result (always
integers by construction) - a non-integer centre, or a `GridSize` of 0,
degrades to an empty ring rather than crashing the caller. An oversized
`Radius` does not degrade - it simply clamps to the whole grid.
""".
-spec ring({integer(), integer()}, non_neg_integer(), non_neg_integer()) ->
    [{integer(), integer()}].
ring({ZX, ZY}, Radius, GridSize) when is_integer(ZX), is_integer(ZY) ->
    [
        {X, Y}
     || X <- safe_seq(clamp_lo(ZX - Radius), min(GridSize - 1, ZX + Radius)),
        Y <- safe_seq(clamp_lo(ZY - Radius), min(GridSize - 1, ZY + Radius))
    ];
ring(Coords, Radius, GridSize) ->
    %% Only reachable via a caller contract violation (every current caller
    %% feeds a pos_to_zone/3 result), but silently returning [] here reads
    %% upstream as "no zones in range" - a player would subscribe to nothing
    %% with no error anywhere. Rate is bounded by joins/zone-changes, not
    %% ticks, so an unconditional log is safe.
    ?LOG_WARNING(#{
        event => zone_ring_malformed_centre,
        coords => Coords,
        radius => Radius,
        grid_size => GridSize
    }),
    [].

-spec clamp_lo(integer()) -> non_neg_integer().
clamp_lo(N) when N < 0 -> 0;
clamp_lo(N) -> N.

%% lists:seq/2 requires Hi >= Lo - 1; a coordinate outside the grid (only
%% possible if a caller skips pos_to_zone/3's clamp) would otherwise crash
%% this function_clause deep instead of degrading to an empty ring.
-spec safe_seq(integer(), integer()) -> [integer()].
safe_seq(Lo, Hi) when Hi < Lo -> [];
safe_seq(Lo, Hi) -> lists:seq(Lo, Hi).
