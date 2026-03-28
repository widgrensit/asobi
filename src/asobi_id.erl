-module(asobi_id).

-export([generate/0]).

-spec generate() -> binary().
generate() ->
    <<A:32, B:16, _:4, C:12, _:2, D:14, E:48>> = crypto:strong_rand_bytes(16),
    Bin = <<A:32, B:16, 4:4, C:12, 2:2, D:14, E:48>>,
    encode_hex(Bin).

-spec encode_hex(<<_:128>>) -> binary().
encode_hex(<<A:32, B:16, C:16, D:16, E:48>>) ->
    iolist_to_binary([
        hex(A, 8), $-, hex(B, 4), $-, hex(C, 4), $-, hex(D, 4), $-, hex(E, 12)
    ]).

-spec hex(non_neg_integer(), pos_integer()) -> binary().
hex(N, Len) ->
    Bin = integer_to_binary(N, 16),
    PadLen = Len - byte_size(Bin),
    case PadLen > 0 of
        true -> <<(binary:copy(<<"0">>, PadLen))/binary, Bin/binary>>;
        false -> Bin
    end.
