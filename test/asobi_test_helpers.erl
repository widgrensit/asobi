-module(asobi_test_helpers).

-export([start/1, unique_username/1]).

-spec start(list()) -> list().
start(Config) ->
    nova_test:start(asobi) ++ Config.

-spec unique_username(binary()) -> binary().
unique_username(_Prefix) ->
    %% Use first 32 chars of a hex-encoded random value
    Bytes = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(Bytes, lowercase),
    binary:part(Hex, 0, 32).
