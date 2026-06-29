-module(asobi_terrain_provider).

-moduledoc """
Behaviour for terrain data providers.

A world server does not define what terrain *is*. It calls a provider you
implement to fetch the bytes of a chunk at a given `{X, Y}` coordinate,
caches them in `m:asobi_terrain_store`, and ships them to clients on zone
entry. Asobi never interprets those bytes: the chunk payload is whatever
your provider returns, and the client is responsible for decoding it.

Implement this to source terrain from disk, a database, or procedural
generation. The `m:asobi_terrain` helpers (`asobi_terrain:encode_chunk/1`,
`asobi_terrain:compress_chunk/1`) build a compact, compressed payload from a
tile map, but you are free to return any binary your client understands.

```erlang
-module(my_terrain).
-behaviour(asobi_terrain_provider).
-export([init/1, load_chunk/2, generate_chunk/3]).

init(Config) -> {ok, Config}.

%% Return a stored chunk, or {error, not_found} to fall back to
%% generate_chunk/3.
load_chunk(_Coords, State) -> {error, not_found}.

%% Procedurally build the chunk: produce a tile map, encode and compress it.
generate_chunk({CX, CY}, Seed, State) ->
    Tiles = #{{0, 0} => {tile_id(CX, CY, Seed), 0, 0}},
    Bin = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk(Tiles)),
    {ok, Bin, State}.
```

Wire it into a world by exporting `terrain_provider/1` from your
`m:asobi_world` game module, returning `{my_terrain, Args}`.
""".

-doc """
Called once when the terrain store starts. `Config` is the `Args` map from
the game module's `terrain_provider/1`. Return the provider state threaded
through every later call.
""".
-callback init(Config :: map()) -> {ok, State :: term()}.

-doc """
Fetch the chunk at `Coords`. Return `{ok, Payload, NewState}` with the
chunk bytes, or `{error, not_found}` to fall back to `generate_chunk/3`
(when exported). Any other `{error, Reason}` propagates to the caller. The
three-element error forms carry updated provider state.
""".
-callback load_chunk(Coords :: {integer(), integer()}, State :: term()) ->
    {ok, Payload :: binary(), NewState :: term()}
    | {error, not_found}
    | {error, not_found, NewState :: term()}
    | {error, Reason :: term()}
    | {error, Reason :: term(), NewState :: term()}.

-doc """
Procedurally produce the chunk at `Coords` from the world `Seed`. Optional:
the fallback for a `load_chunk/2` miss. Without it, a miss yields
`{error, not_found}` to the caller.
""".
-callback generate_chunk(Coords :: {integer(), integer()}, Seed :: integer(), State :: term()) ->
    {ok, Payload :: binary(), NewState :: term()} | {error, term()}.

-optional_callbacks([generate_chunk/3]).
