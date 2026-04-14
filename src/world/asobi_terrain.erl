-module(asobi_terrain).

%% Pure functional terrain chunk encoding/decoding.
%%
%% Encodes tile grids as compact binaries. Default format: 4 bytes per tile
%% (2B tile_id, 1B flags, 1B elevation). A 64x64 chunk = 16KB raw.

-export([encode_chunk/1, encode_chunk/2]).
-export([decode_chunk/1, decode_chunk/2]).
-export([compress_chunk/1, decompress_chunk/1]).
-export([default_format/0, chunk_byte_size/1]).

-export_type([tile/0, format/0]).

-type tile() :: {
    X :: non_neg_integer(),
    Y :: non_neg_integer(),
    TileId :: non_neg_integer(),
    Flags :: non_neg_integer(),
    Elevation :: non_neg_integer()
}.
-type format() :: #{
    tile_size := pos_integer(),
    chunk_width := pos_integer(),
    chunk_height := pos_integer()
}.

%% --- Public API ---

-spec default_format() -> format().
default_format() ->
    #{tile_size => 4, chunk_width => 64, chunk_height => 64}.

-spec chunk_byte_size(format()) -> pos_integer().
chunk_byte_size(#{tile_size := TS, chunk_width := W, chunk_height := H}) ->
    W * H * TS.

-spec encode_chunk([tile()]) -> binary().
encode_chunk(Tiles) ->
    encode_chunk(Tiles, default_format()).

-spec encode_chunk([tile()] | #{}, format()) -> binary().
encode_chunk(Tiles, Fmt) when is_list(Tiles) ->
    Map = lists:foldl(
        fun({X, Y, TileId, Flags, Elev}, Acc) ->
            Acc#{{X, Y} => {TileId, Flags, Elev}}
        end,
        #{},
        Tiles
    ),
    encode_chunk(Map, Fmt);
encode_chunk(TileMap, #{chunk_width := W, chunk_height := H} = _Fmt) when is_map(TileMap) ->
    iolist_to_binary([
        encode_tile(maps:get({X, Y}, TileMap, {0, 0, 0}))
     || Y <- lists:seq(0, H - 1), X <- lists:seq(0, W - 1)
    ]).

-spec decode_chunk(binary()) -> [tile()].
decode_chunk(Bin) ->
    decode_chunk(Bin, default_format()).

-spec decode_chunk(binary(), format()) -> [tile()].
decode_chunk(Bin, #{chunk_width := W} = _Fmt) ->
    decode_tiles(Bin, 0, W, []).

-spec compress_chunk(binary()) -> binary().
compress_chunk(Bin) ->
    zlib:compress(Bin).

-spec decompress_chunk(binary()) -> binary().
decompress_chunk(Bin) ->
    zlib:uncompress(Bin).

%% --- Internal ---

encode_tile({TileId, Flags, Elev}) ->
    <<TileId:16/big-unsigned, Flags:8/unsigned, Elev:8/unsigned>>.

decode_tiles(<<>>, _Idx, _W, Acc) ->
    lists:reverse(Acc);
decode_tiles(<<0:16, _Flags:8, _Elev:8, Rest/binary>>, Idx, W, Acc) ->
    decode_tiles(Rest, Idx + 1, W, Acc);
decode_tiles(
    <<TileId:16/big-unsigned, Flags:8/unsigned, Elev:8/unsigned, Rest/binary>>, Idx, W, Acc
) ->
    X = Idx rem W,
    Y = Idx div W,
    decode_tiles(Rest, Idx + 1, W, [{X, Y, TileId, Flags, Elev} | Acc]).
